import AppIntents
import SwiftUI
import WidgetKit

// Three widgets for Amazon Music + Timbre:
//   Player      artwork, track, live progress, transport buttons
//   Spectrum    a snapshot of what is playing right now, after Timbre (widgets cannot animate)
//   Timbre EQ   the actual response curve, preset, on/off and preset buttons
// Data comes from the app's 127.0.0.1 endpoint (works without App Group provisioning), with the
// shared App Group defaults as a fallback. On iOS 17+ the buttons run without opening the app.

private enum Config {
    static let group = "group.com.soum91.amazon.timbre"
    #if TIMBRE_EXPERIMENTAL
    static let scheme = "timbre-amazon-lab"
    #else
    static let scheme = "timbre-amazon"
    #endif
    static let launch = URL(string: "\(scheme)://open")!
    static func playerLink(_ action: String) -> URL { URL(string: "\(scheme)://player/\(action)")! }
    static let endpoint = "http://127.0.0.1:43819"
    static var token: String? { Bundle.main.object(forInfoDictionaryKey: "TimbreLocalToken") as? String }
    static let playerKind = "com.soum91.timbre.player"
    static let eqKind = "com.soum91.timbre.eq"
    static let visualizerKind = "com.soum91.timbre.visualizer"
}

private enum Theme {
    static let accent = Color(red: 1.0, green: 0.76, blue: 0.24)      // Timbre amber
    static let pink = Color(red: 1.0, green: 0.42, blue: 0.62)
    static let violet = Color(red: 0.55, green: 0.42, blue: 1.0)
    static let teal = Color(red: 0.36, green: 0.82, blue: 0.86)        // Amazon Music teal
    static let background = LinearGradient(colors: [Color(red: 0.13, green: 0.09, blue: 0.21), .black],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
}

// MARK: - Model

private struct Player {
    var title: String
    var artist: String
    var album: String
    var artwork: UIImage?
    var playing: Bool
    var controlsReady: Bool
    var duration: Double
    var elapsed: Double
    var updatedAt: Double

    init?(_ d: [String: Any]) {
        guard let name = d["title"] as? String, !name.isEmpty else { return nil }
        title = name
        artist = (d["artist"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown artist"
        album = d["album"] as? String ?? ""
        playing = d["playing"] as? Bool ?? false
        controlsReady = d["controlsReady"] as? Bool ?? false
        duration = (d["duration"] as? NSNumber)?.doubleValue ?? 0
        elapsed = (d["elapsed"] as? NSNumber)?.doubleValue ?? 0
        updatedAt = (d["updatedAt"] as? NSNumber)?.doubleValue ?? 0
        if let b64 = d["artworkJPEG"] as? String, let bytes = Data(base64Encoded: b64) {
            artwork = UIImage(data: bytes)
        } else {
            artwork = nil
        }
    }

    /// Track start and end in wall-clock time, so ProgressView(timerInterval:) can advance by itself.
    var interval: ClosedRange<Date>? {
        guard playing, duration > 1, updatedAt > 0 else { return nil }
        let start = Date(timeIntervalSince1970: updatedAt - elapsed)
        let end = start.addingTimeInterval(duration)
        return end > Date() ? start...end : nil
    }
    var fraction: Double { duration > 0 ? min(1, max(0, elapsed / duration)) : 0 }
}

private struct EQBand {
    var enabled: Bool, type: Int, frequency: Double, gain: Double, q: Double
}

private struct EQState {
    var known = false
    var enabled = false
    var preamp = 0.0
    var bands: [EQBand] = []
    var preset = "Custom"
    var edited = false
    var spatial = false, headTracking = false, reverb = false, comp = false, crossfeed = false, width = false

    init() {}
    init(_ d: [String: Any]) {
        guard d["enabled"] != nil else { return }
        known = true
        enabled = d["enabled"] as? Bool ?? false
        preamp = (d["preamp"] as? NSNumber)?.doubleValue ?? 0
        preset = d["preset"] as? String ?? "Custom"
        edited = d["edited"] as? Bool ?? false
        spatial = d["spatial"] as? Bool ?? false
        headTracking = d["headTracking"] as? Bool ?? false
        reverb = d["reverb"] as? Bool ?? false
        comp = d["comp"] as? Bool ?? false
        crossfeed = d["crossfeed"] as? Bool ?? false
        width = d["width"] as? Bool ?? false
        bands = (d["bands"] as? [[String: Any]] ?? []).map {
            EQBand(enabled: $0["enabled"] as? Bool ?? true,
                   type: ($0["type"] as? NSNumber)?.intValue ?? 0,
                   frequency: ($0["frequency"] as? NSNumber)?.doubleValue ?? 1000,
                   gain: ($0["gain"] as? NSNumber)?.doubleValue ?? 0,
                   q: ($0["q"] as? NSNumber)?.doubleValue ?? 1)
        }
    }
    var presetLabel: String { edited ? "\(preset) (edited)" : preset }
    var activeEffects: [String] {
        var out: [String] = []
        if spatial { out.append(headTracking ? "Spatial + head" : "Spatial") }
        if reverb { out.append("Reverb") }
        if comp { out.append("Compressor") }
        if crossfeed { out.append("Crossfeed") }
        if width { out.append("Width") }
        return out
    }

    /// Combined response in dB at `points` log-spaced frequencies 20 Hz..20 kHz (same RBJ math as the DSP).
    func response(points: Int = 64, rate: Double = 48000) -> [Double] {
        let coeffs = bands.filter(\.enabled).compactMap { Self.coefficients($0, rate) }
        return (0..<points).map { i in
            let f = 20 * pow(1000, Double(i) / Double(points - 1))
            let w = 2 * Double.pi * f / rate
            let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
            var db = 0.0
            for k in coeffs {
                let nr = k.0 + k.1 * c1 + k.2 * c2, ni = -(k.1 * s1 + k.2 * s2)
                let dr = 1 + k.3 * c1 + k.4 * c2, di = -(k.3 * s1 + k.4 * s2)
                db += 10 * log10(max((nr * nr + ni * ni) / max(dr * dr + di * di, 1e-30), 1e-18))
            }
            return db
        }
    }

    private static func coefficients(_ b: EQBand, _ fs: Double) -> (Double, Double, Double, Double, Double)? {
        guard b.frequency.isFinite, b.q.isFinite, b.gain.isFinite else { return nil }
        let f = min(max(b.frequency, 2), fs * 0.49), q = min(max(b.q, 0.05), 40)
        let A = pow(10, min(max(b.gain, -120), 120) / 40)
        let w = 2 * Double.pi * f / fs, c = cos(w), s = sin(w), al = s / (2 * q), sA = 2 * sqrt(A) * al
        var (b0, b1, b2, a0, a1, a2) = (0.0, 0.0, 0.0, 1.0, 0.0, 0.0)
        switch b.type {
        case 0: (b0, b1, b2, a0, a1, a2) = (1 + al * A, -2 * c, 1 - al * A, 1 + al / A, -2 * c, 1 - al / A)
        case 1: (b0, b1, b2, a0, a1, a2) = (A * ((A + 1) - (A - 1) * c + sA), 2 * A * ((A - 1) - (A + 1) * c),
                                            A * ((A + 1) - (A - 1) * c - sA), (A + 1) + (A - 1) * c + sA,
                                            -2 * ((A - 1) + (A + 1) * c), (A + 1) + (A - 1) * c - sA)
        case 2: (b0, b1, b2, a0, a1, a2) = (A * ((A + 1) + (A - 1) * c + sA), -2 * A * ((A - 1) + (A + 1) * c),
                                            A * ((A + 1) + (A - 1) * c - sA), (A + 1) - (A - 1) * c + sA,
                                            2 * ((A - 1) - (A + 1) * c), (A + 1) - (A - 1) * c - sA)
        case 3: (b0, b1, b2, a0, a1, a2) = ((1 - c) / 2, 1 - c, (1 - c) / 2, 1 + al, -2 * c, 1 - al)
        case 4: (b0, b1, b2, a0, a1, a2) = ((1 + c) / 2, -(1 + c), (1 + c) / 2, 1 + al, -2 * c, 1 - al)
        case 5: (b0, b1, b2, a0, a1, a2) = (al, 0, -al, 1 + al, -2 * c, 1 - al)
        case 6: (b0, b1, b2, a0, a1, a2) = (1, -2 * c, 1, 1 + al, -2 * c, 1 - al)
        case 7: (b0, b1, b2, a0, a1, a2) = (1 - al, -2 * c, 1 + al, 1 + al, -2 * c, 1 - al)
        default: return nil
        }
        return (b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0)
    }
}

private struct Spectrum {
    var bands: [Double] = []
    var active = false
    init() {}
    init(_ d: [String: Any]) {
        bands = (d["bands"] as? [NSNumber] ?? []).map { min(1, max(0, $0.doubleValue)) }
        active = d["active"] as? Bool ?? false
    }
}

private struct Entry: TimelineEntry {
    let date: Date
    let player: Player?
    let eq: EQState
    let spectrum: Spectrum
    let live: Bool        // true when the app answered; false means cached data

    static var preview: Entry {
        var eq = EQState()
        eq.known = true; eq.enabled = true; eq.preset = "V-Shape"; eq.spatial = true; eq.headTracking = true
        eq.bands = [EQBand(enabled: true, type: 1, frequency: 120, gain: 5, q: 0.7),
                    EQBand(enabled: true, type: 0, frequency: 1500, gain: -2.5, q: 0.8),
                    EQBand(enabled: true, type: 2, frequency: 8000, gain: 4, q: 0.7)]
        var spectrum = Spectrum()
        spectrum.active = true
        spectrum.bands = (0..<24).map { (i: Int) -> Double in
            let x = Double(i)
            let wave: Double = 0.4 * sin(x * 0.45) * exp(-x / 30)
            let bass: Double = 0.2 * exp(-x / 4)
            return 0.35 + wave + bass
        }
        return Entry(date: .now,
                     player: Player(["title": "Now Playing", "artist": "Amazon Music", "playing": true,
                                     "controlsReady": true, "duration": 200, "elapsed": 60,
                                     "updatedAt": Date().timeIntervalSince1970]),
                     eq: eq, spectrum: spectrum, live: true)
    }

    /// Last state the app actually answered with, kept in the extension's own defaults (no App Group needed).
    static func lastGood() -> Entry? {
        guard let data = UserDefaults.standard.data(forKey: "TimbreWidget.lastState.v1"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let saved = (json["time"] as? NSNumber)?.doubleValue ?? 0
        let entry = Entry.from(json)
        return Entry(date: saved > 0 ? Date(timeIntervalSince1970: saved) : .now,
                     player: entry.player, eq: entry.eq, spectrum: entry.spectrum, live: false)
    }

    static func cached() -> Entry {
        if let last = lastGood() { return last }
        let store = UserDefaults(suiteName: Config.group)
        let playback = store?.dictionary(forKey: "TimbreWidget.nowPlaying.v1")
        var eq = EQState()
        if let status = store?.dictionary(forKey: "TimbreWidget.status.v1"), let on = status["enabled"] as? Bool {
            eq.known = true; eq.enabled = on
        }
        return Entry(date: .now, player: playback.flatMap(Player.init), eq: eq, spectrum: Spectrum(), live: false)
    }

    static func from(_ json: [String: Any]) -> Entry {
        Entry(date: .now,
              player: (json["player"] as? [String: Any]).flatMap(Player.init),
              eq: EQState(json["eq"] as? [String: Any] ?? [:]),
              spectrum: Spectrum(json["spectrum"] as? [String: Any] ?? [:]),
              live: true)
    }
}

private enum Endpoint {
    static func request(_ path: String, timeout: TimeInterval = 1.5) async -> [String: Any]? {
        guard let url = URL(string: Config.endpoint + path) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let token = Config.token { request.setValue(token, forHTTPHeaderField: "X-Timbre-Token") }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
    static func entry() async -> Entry {
        // The app answers from a cache, but it can be busy for a moment; try twice before falling back.
        for attempt in 0..<2 {
            if let json = await request("/state", timeout: attempt == 0 ? 2.5 : 4) {
                if let data = try? JSONSerialization.data(withJSONObject: json) {
                    UserDefaults.standard.set(data, forKey: "TimbreWidget.lastState.v1")
                }
                return .from(json)
            }
        }
        return .cached()
    }
}

private struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { .preview }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        if context.isPreview { completion(.preview); return }
        Task { completion(await Endpoint.entry()) }
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        Task {
            let entry = await Endpoint.entry()
            // The app asks for reloads on track, play/pause and EQ changes. Independently of that, wake up
            // right after the current track should end so the next song shows up even if those requests
            // are throttled, and otherwise every two minutes while music plays.
            var next = Date.now.addingTimeInterval(entry.player?.playing == true ? 120 : 900)
            if let end = entry.player?.interval?.upperBound, end.timeIntervalSinceNow < 600 {
                next = min(next, end.addingTimeInterval(2))
            }
            if !entry.live { next = min(next, .now.addingTimeInterval(60)) }
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }
}

// MARK: - Interactive buttons (iOS 17+)

@available(iOS 17.0, *)
struct TimbreCommandIntent: AppIntent {
    static var title: LocalizedStringResource = "Timbre widget command"
    static var isDiscoverable = false
    @Parameter(title: "Command") var command: String
    init() { command = "" }
    init(_ command: String) { self.command = command }
    func perform() async throws -> some IntentResult {
        _ = await Endpoint.request("/command/" + command, timeout: 3)
        return .result()
    }
}

/// A transport/EQ button: a real button on iOS 17+, a deep link into the app on iOS 16.
private struct CommandButton<Label: View>: View {
    let command: String
    let fallback: URL
    @ViewBuilder let label: () -> Label
    var body: some View {
        if #available(iOS 17.0, *) {
            Button(intent: TimbreCommandIntent(command)) { label() }.buttonStyle(.plain)
        } else {
            Link(destination: fallback) { label() }
        }
    }
}

private extension View {
    @ViewBuilder func widgetBackground<B: View>(_ background: B) -> some View {
        if #available(iOS 17.0, *) {
            containerBackground(for: .widget) { background }
        } else {
            self.background(background)
        }
    }
}

// MARK: - Shared pieces

private struct Artwork: View {
    let image: UIImage?
    var corner: CGFloat = 13
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.37, green: 0.16, blue: 0.48), Color(red: 0.09, green: 0.04, blue: 0.15)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "music.note").font(.system(size: 28)).foregroundStyle(.white.opacity(0.8))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

private struct TrackProgress: View {
    let player: Player
    var body: some View {
        if let interval = player.interval {
            ProgressView(timerInterval: interval, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                .progressViewStyle(.linear).tint(Theme.teal)
        } else {
            ProgressView(value: player.fraction).progressViewStyle(.linear).tint(Theme.teal.opacity(0.6))
        }
    }
}

private struct Transport: View {
    let player: Player?
    var size: CGFloat = 18
    var body: some View {
        HStack(spacing: size * 1.5) {
            CommandButton(command: "player/previous", fallback: Config.playerLink("previous")) {
                Image(systemName: "backward.fill").font(.system(size: size))
            }
            CommandButton(command: "player/toggle", fallback: Config.playerLink("toggle")) {
                Image(systemName: player?.playing == true ? "pause.fill" : "play.fill").font(.system(size: size * 1.35))
                    .frame(width: size * 2.2, height: size * 2.2)
                    .background(Circle().fill(.white.opacity(0.14)))
            }
            CommandButton(command: "player/next", fallback: Config.playerLink("next")) {
                Image(systemName: "forward.fill").font(.system(size: size))
            }
        }
        .foregroundStyle(.white)
    }
}

private struct Bars: View {
    let levels: [Double]
    var spacing: CGFloat = 3
    var body: some View {
        GeometryReader { geo in
            let count = max(levels.count, 1)
            let width = max(1, (geo.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                    let t = Double(index) / Double(max(count - 1, 1))
                    RoundedRectangle(cornerRadius: min(width / 2, 3), style: .continuous)
                        .fill(LinearGradient(colors: [Theme.violet, Theme.pink.mix(Theme.accent, t)],
                                             startPoint: .bottom, endPoint: .top))
                        .frame(width: width, height: max(3, geo.size.height * level))
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}

private extension Color {
    func mix(_ other: Color, _ t: Double) -> Color {
        let a = UIColor(self), b = UIColor(other)
        var (r1, g1, b1, a1, r2, g2, b2, a2): (CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0, 0, 0, 0, 0)
        a.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        b.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        let k = CGFloat(min(1, max(0, t)))
        return Color(red: r1 + (r2 - r1) * k, green: g1 + (g2 - g1) * k, blue: b1 + (b2 - b1) * k)
    }
}

private struct Curve: View {
    let eq: EQState
    var showGrid = true
    var body: some View {
        GeometryReader { geo in
            let values = eq.response(points: 72)
            let range = max(12, (values.map(abs).max() ?? 0) + 3)
            let w = geo.size.width, h = geo.size.height
            let point: (Int) -> CGPoint = { i in
                CGPoint(x: w * CGFloat(i) / CGFloat(values.count - 1),
                        y: h / 2 - h / 2 * CGFloat(values[i] / range))
            }
            ZStack {
                if showGrid {
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: h / 2)); p.addLine(to: CGPoint(x: w, y: h / 2))
                        for f in [100.0, 1000.0, 10000.0] {
                            let x = w * CGFloat(log10(f / 20) / 3)
                            p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: h))
                        }
                    }
                    .stroke(.white.opacity(0.12), lineWidth: 1)
                }
                Path { p in
                    p.move(to: CGPoint(x: 0, y: h / 2))
                    for i in values.indices { p.addLine(to: point(i)) }
                    p.addLine(to: CGPoint(x: w, y: h / 2))
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [Theme.accent.opacity(eq.enabled ? 0.35 : 0.1), .clear],
                                     startPoint: .top, endPoint: .bottom))
                Path { p in
                    for i in values.indices { i == 0 ? p.move(to: point(i)) : p.addLine(to: point(i)) }
                }
                .stroke(eq.enabled ? Theme.accent : Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

// MARK: - Player widget

private struct PlayerView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry
    var body: some View {
        content.widgetURL(Config.launch).widgetBackground(Theme.background)
    }
    @ViewBuilder private var content: some View {
        switch family {
        case .systemSmall: small
        case .systemLarge: large
        case .accessoryRectangular: lock
        case .accessoryInline:
            Label(entry.player.map { "\($0.title) · \($0.artist)" } ?? "Amazon Music", systemImage: "music.note")
        default: medium
        }
    }
    private var title: String { entry.player?.title ?? "Amazon Music" }
    private var artist: String { entry.player?.artist ?? "Nothing playing" }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Artwork(image: entry.player?.artwork, corner: 10).frame(width: 58, height: 58)
                Spacer(minLength: 0)
                if entry.player != nil {
                    CommandButton(command: "player/toggle", fallback: Config.playerLink("toggle")) {
                        Image(systemName: entry.player?.playing == true ? "pause.fill" : "play.fill")
                            .font(.system(size: 16, weight: .bold)).foregroundStyle(.black)
                            .frame(width: 36, height: 36).background(Circle().fill(Theme.teal))
                    }
                }
            }
            Spacer(minLength: 0)
            Text(title).font(.system(size: 14, weight: .bold)).lineLimit(1)
            Text(artist).font(.system(size: 11)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
            if let player = entry.player { TrackProgress(player: player).padding(.top, 2) }
        }
        .foregroundStyle(.white)
    }

    private var medium: some View {
        HStack(spacing: 14) {
            Artwork(image: entry.player?.artwork).aspectRatio(1, contentMode: .fit)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 16, weight: .bold)).lineLimit(1)
                Text(artist).font(.system(size: 12)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                if let player = entry.player { TrackProgress(player: player).padding(.vertical, 4) }
                if !entry.live && entry.player != nil {
                    Text("Last seen \(entry.date.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 9)).foregroundStyle(Color.white.opacity(0.45))
                }
                Spacer(minLength: 0)
                if entry.player != nil {
                    Transport(player: entry.player, size: 15).frame(maxWidth: .infinity)
                } else {
                    Label("Open Amazon Music", systemImage: "arrow.up.right").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.teal)
                }
            }
        }
        .foregroundStyle(.white)
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 10) {
            Artwork(image: entry.player?.artwork, corner: 16).frame(maxWidth: .infinity).aspectRatio(1.35, contentMode: .fit)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 19, weight: .bold)).lineLimit(1)
                Text(entry.player.map { $0.album.isEmpty ? $0.artist : "\($0.artist) · \($0.album)" } ?? artist)
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
            }
            if let player = entry.player { TrackProgress(player: player) }
            HStack {
                Transport(player: entry.player, size: 18)
                Spacer()
                if entry.eq.known {
                    CommandButton(command: "eq/toggle", fallback: Config.launch) {
                        Label(entry.eq.enabled ? entry.eq.presetLabel : "EQ off", systemImage: "slider.vertical.3")
                            .font(.system(size: 11, weight: .semibold)).lineLimit(1)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Capsule().fill(entry.eq.enabled ? Theme.accent.opacity(0.22) : Color.white.opacity(0.1)))
                            .foregroundStyle(entry.eq.enabled ? Theme.accent : Color.white.opacity(0.7))
                    }
                }
            }
        }
        .foregroundStyle(.white)
    }

    private var lock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline).lineLimit(1)
            Text(artist).font(.caption).lineLimit(1)
            if let player = entry.player { TrackProgress(player: player) }
        }
    }
}

// MARK: - Spectrum widget

private struct VisualizerView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry
    private var levels: [Double] {
        let raw = entry.spectrum.bands.isEmpty ? Array(repeating: 0.04, count: 24) : entry.spectrum.bands
        switch family {
        case .systemSmall, .accessoryRectangular:
            // 12 bars: average neighbouring bands.
            var pairs: [Double] = []
            var i = 0
            while i < raw.count {
                let next: Double = raw[min(i + 1, raw.count - 1)]
                pairs.append((raw[i] + next) / 2)
                i += 2
            }
            return pairs
        default: return raw
        }
    }
    var body: some View {
        content.widgetURL(Config.launch).widgetBackground(Color.black)
    }
    @ViewBuilder private var content: some View {
        if family == .accessoryRectangular { lockView } else { homeView }
    }
    private var lockView: some View {
        VStack(alignment: .leading, spacing: 2) {
            Bars(levels: levels, spacing: 2)
            Text(entry.player?.title ?? "Spectrum").font(.caption2).lineLimit(1)
        }
    }
    private var homeView: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            bars
            if family != .systemSmall { trackLine }
            if family == .systemLarge { axis }
        }
        .foregroundStyle(.white)
    }
    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform").foregroundStyle(Theme.pink)
            Text("SPECTRUM").font(.system(size: 10, weight: .bold)).tracking(1.2)
            Spacer(minLength: 0)
            if entry.spectrum.active {
                Text(entry.date, style: .time).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
            }
        }
    }
    private var bars: some View {
        ZStack {
            Bars(levels: levels, spacing: family == .systemSmall ? 3 : 4)
            if !entry.spectrum.active {
                Text(entry.live ? "Play something" : "Open Amazon Music")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
            }
        }
    }
    @ViewBuilder private var trackLine: some View {
        if let player = entry.player {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(player.title).font(.system(size: 13, weight: .bold)).lineLimit(1)
                    Text(player.artist).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
                Spacer(minLength: 8)
                if entry.eq.known { eqTag }
            }
        }
    }
    private var eqTag: some View {
        Text(entry.eq.enabled ? entry.eq.presetLabel : "EQ off")
            .font(.system(size: 10, weight: .semibold)).lineLimit(1)
            .foregroundStyle(entry.eq.enabled ? Theme.accent : Color.white.opacity(0.5))
    }
    private var axis: some View {
        HStack {
            Text("60"); Spacer(); Text("250"); Spacer(); Text("1k"); Spacer(); Text("4k"); Spacer(); Text("16k")
        }
        .font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.4))
    }
}

// MARK: - EQ widget

private struct EQView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry
    private var eq: EQState { entry.eq }
    var body: some View {
        content.widgetURL(Config.launch).widgetBackground(Theme.background)
    }
    @ViewBuilder private var content: some View {
        switch family {
        case .accessoryCircular:
            VStack(spacing: 2) {
                Image(systemName: "slider.vertical.3").font(.system(size: 16))
                Text(eq.known ? (eq.enabled ? "ON" : "OFF") : "EQ").font(.system(size: 10, weight: .bold))
            }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Text(eq.known ? (eq.enabled ? eq.presetLabel : "Timbre off") : "Timbre EQ").font(.headline).lineLimit(1)
                Curve(eq: eq, showGrid: false)
            }
        case .accessoryInline:
            Label("Timbre · \(eq.known ? (eq.enabled ? eq.presetLabel : "Off") : "Open app")", systemImage: "slider.vertical.3")
        case .systemSmall: small
        default: medium
        }
    }
    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "slider.vertical.3").foregroundStyle(Theme.accent)
            Text("TIMBRE").font(.system(size: 10, weight: .bold)).tracking(1.2)
            Spacer(minLength: 0)
            CommandButton(command: "eq/toggle", fallback: Config.launch) {
                Text(eq.enabled ? "ON" : "OFF").font(.system(size: 11, weight: .heavy))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(eq.enabled ? Theme.accent : Color.white.opacity(0.14)))
                    .foregroundStyle(eq.enabled ? Color.black : Color.white.opacity(0.75))
            }
        }
    }
    private var small: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Curve(eq: eq, showGrid: false)
            Text(eq.known ? eq.presetLabel : "Open the EQ").font(.system(size: 13, weight: .bold)).lineLimit(1)
        }
        .foregroundStyle(.white)
    }
    private var medium: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                header
                Curve(eq: eq)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(eq.known ? eq.presetLabel : "Open the EQ").font(.system(size: 14, weight: .bold)).lineLimit(2)
                Text(eq.known ? "\(eq.bands.filter(\.enabled).count) bands · preamp \(String(format: "%.1f", eq.preamp)) dB" : "")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                if !eq.activeEffects.isEmpty {
                    Text(eq.activeEffects.joined(separator: " · ")).font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.pink).lineLimit(2)
                }
                Spacer(minLength: 0)
                HStack(spacing: 16) {
                    CommandButton(command: "preset/previous", fallback: Config.launch) {
                        Image(systemName: "chevron.left.circle.fill").font(.system(size: 24))
                    }
                    CommandButton(command: "preset/next", fallback: Config.launch) {
                        Image(systemName: "chevron.right.circle.fill").font(.system(size: 24))
                    }
                }
                .foregroundStyle(Theme.accent)
            }
            .frame(width: 118, alignment: .leading)
        }
        .foregroundStyle(.white)
    }
}

// MARK: - Widgets

private struct PlayerWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Config.playerKind, provider: Provider()) { PlayerView(entry: $0) }
            .configurationDisplayName("Amazon Music Player")
            .description("Artwork, live progress and playback controls.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryInline])
    }
}

private struct VisualizerWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Config.visualizerKind, provider: Provider()) { VisualizerView(entry: $0) }
            .configurationDisplayName("Spectrum")
            .description("A snapshot of what's playing right now, after Timbre. Refreshes while music plays.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular])
    }
}

private struct EQWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Config.eqKind, provider: Provider()) { EQView(entry: $0) }
            .configurationDisplayName("Timbre EQ")
            .description("Your EQ curve and preset, with on/off and preset buttons.")
            .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

@main
struct TimbreWidgets: WidgetBundle {
    var body: some Widget {
        PlayerWidget()
        VisualizerWidget()
        EQWidget()
    }
}
