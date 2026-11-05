import SwiftUI
import WidgetKit

private enum Config {
    static let group = "group.com.soum91.amazon.timbre"
    static let launch = URL(string: "timbre-amazon://open")!
    static func playerLink(_ action: String) -> URL {
        URL(string: "timbre-amazon://player/\(action)")!
    }
}

private struct Player {
    let title: String
    let artist: String
    let album: String
    let artwork: UIImage?
    let playing: Bool
    let controlsReady: Bool

    init?(_ dictionary: [String: Any]) {
        guard let name = dictionary["title"] as? String, !name.isEmpty else { return nil }
        title = name
        artist = dictionary["artist"] as? String ?? "Unknown artist"
        album = dictionary["album"] as? String ?? ""
        playing = dictionary["playing"] as? Bool ?? false
        controlsReady = dictionary["controlsReady"] as? Bool ?? false
        if let base64 = dictionary["artworkJPEG"] as? String,
           let bytes = Data(base64Encoded: base64) {
            artwork = UIImage(data: bytes)
        } else {
            artwork = nil
        }
    }
}

private struct Entry: TimelineEntry {
    let date: Date
    let player: Player?
    let hasEQ: Bool
    let enabled: Bool
    let bands: Int
    let effects: Int

    static func current() -> Self {
        let store = UserDefaults(suiteName: Config.group)
        let state = store?.dictionary(forKey: "TimbreWidget.status.v1")
        let playback = store?.dictionary(forKey: "TimbreWidget.nowPlaying.v1")
        return Self(date: .now, player: playback.flatMap(Player.init),
                    hasEQ: state?["enabled"] is Bool,
                    enabled: state?["enabled"] as? Bool ?? false,
                    bands: max(0, state?["bands"] as? Int ?? 0),
                    effects: max(0, state?["effects"] as? Int ?? 0))
    }
    static var preview: Self {
        Self(date: .now,
             player: Player(["title": "Now Playing", "artist": "Amazon Music", "playing": true]),
             hasEQ: true, enabled: true, bands: 19, effects: 2)
    }
}

private struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { .preview }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(context.isPreview ? .preview : .current())
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        // WidgetKit ultimately controls the refresh frequency.
        completion(Timeline(entries: [.current()], policy: .after(.now.addingTimeInterval(300))))
    }
}

private struct Artwork: View {
    let image: UIImage?
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.37, green: 0.16, blue: 0.48),
                                             Color(red: 0.09, green: 0.04, blue: 0.15)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            } else {
                Image(systemName: "music.note").font(.system(size: 31))
                    .foregroundStyle(.white.opacity(0.8))
            }
        }.clipped()
    }
}

private struct PlayerView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.16, green: 0.12, blue: 0.24), .black],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if family == .systemSmall { small } else { wide }
        }
        .widgetURL(Config.launch)
    }
    private var small: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("NOW PLAYING", systemImage: "waveform")
                .font(.system(size: 10, weight: .bold)).tracking(1)
                .foregroundStyle(.pink)
            Artwork(image: entry.player?.artwork)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(entry.player?.title ?? "Amazon Music")
                .font(.system(size: 14, weight: .bold)).lineLimit(1)
            Text(entry.player?.artist ?? "Open the player")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
        }.foregroundStyle(.white).padding(12)
    }
    private var wide: some View {
        HStack(spacing: 14) {
            Artwork(image: entry.player?.artwork)
                .frame(width: family == .systemLarge ? 140 : 110,
                       height: family == .systemLarge ? 140 : 110)
            VStack(alignment: .leading, spacing: 6) {
                Label("AMAZON MUSIC", systemImage: "waveform")
                    .font(.system(size: 10, weight: .bold)).tracking(1)
                    .foregroundStyle(.pink)
                Text(entry.player?.title ?? "Your music player")
                    .font(.system(size: 18, weight: .bold)).lineLimit(2)
                Text(entry.player?.artist ?? "Open Amazon Music to play")
                    .font(.system(size: 12)).lineLimit(1)
                    .foregroundStyle(.white.opacity(0.7))
                Spacer(minLength: 0)
                if let player = entry.player, player.controlsReady {
                    // Commands are deep links; the host app must implement them.
                    HStack(spacing: 24) {
                        Link(destination: Config.playerLink("previous")) {
                            Image(systemName: "backward.end.fill")
                        }
                        Link(destination: Config.playerLink("toggle")) {
                            Image(systemName: player.playing ? "pause.fill" : "play.fill")
                                .font(.system(size: 22))
                        }
                        Link(destination: Config.playerLink("next")) {
                            Image(systemName: "forward.end.fill")
                        }
                    }.font(.system(size: 17)).foregroundStyle(.white)
                } else {
                    Link(destination: Config.launch) {
                        Label("Open player", systemImage: "arrow.up.right")
                            .font(.system(size: 12, weight: .semibold))
                    }.foregroundStyle(.pink)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.foregroundStyle(.white).padding(14)
    }
}

private struct EQView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry
    private var status: String {
        entry.hasEQ ? (entry.enabled ? "EQ ON" : "EQ OFF") : "OPEN APP"
    }
    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                VStack(spacing: 2) {
                    Image(systemName: "waveform.path.ecg").font(.system(size: 18))
                    Text(entry.hasEQ ? (entry.enabled ? "ON" : "OFF") : "EQ")
                        .font(.system(size: 10, weight: .bold))
                }
            case .accessoryRectangular:
                HStack(spacing: 7) {
                    Image(systemName: "waveform.path.ecg")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Timbre EQ").font(.headline)
                        Text(entry.hasEQ ? "\(status) · \(entry.bands) bands" : "Tap to open")
                            .font(.caption2)
                    }
                }
            case .accessoryInline:
                Label("Timbre · \(status)", systemImage: "waveform.path.ecg")
            default:
                ZStack {
                    LinearGradient(colors: [Color(red: 0.16, green: 0.10, blue: 0.26),
                                            Color(red: 0.03, green: 0.02, blue: 0.08)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    VStack(alignment: .leading, spacing: 9) {
                        Image(systemName: "waveform.path.ecg")
                            .font(.system(size: 24)).foregroundStyle(.yellow)
                        Text("TIMBRE EQ").font(.system(size: 12, weight: .bold))
                            .tracking(1.3)
                        Spacer(minLength: 0)
                        Text(status).font(.system(size: 23, weight: .bold))
                        Text(entry.hasEQ ? "\(entry.bands) bands · \(entry.effects) effects" : "Open the EQ editor")
                            .font(.caption).foregroundStyle(.white.opacity(0.7))
                    }.foregroundStyle(.white).padding(16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
            }
        }.widgetURL(Config.launch)
    }
}

private struct PlayerWidget: Widget {
    let kind = "com.soum91.timbre.player"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { PlayerView(entry: $0) }
            .configurationDisplayName("Amazon Music Player")
            .description("Artwork, song and artist when the app provides live playback state.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private struct EQWidget: Widget {
    let kind = "com.soum91.timbre.eq"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { EQView(entry: $0) }
            .configurationDisplayName("Timbre EQ")
            .description("View the latest available Timbre EQ state and open its editor.")
            .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular,
                                .accessoryRectangular, .accessoryInline])
    }
}

@main
struct TimbreWidgets: WidgetBundle {
    var body: some Widget {
        PlayerWidget()
        EQWidget()
    }
}
