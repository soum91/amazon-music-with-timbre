import SwiftUI
import WidgetKit

private enum TimbreWidgetConfig {
    static let group = "group.com.soum91.amazon.timbre"
    static let key = "TimbreWidget.status.v1"
    static let launchURL = URL(string: "timbre-amazon://open")!
}

private struct TimbreEntry: TimelineEntry {
    let date: Date
    let hasStatus: Bool
    let isEnabled: Bool
    let bands: Int
    let effectCount: Int

    static func current(at date: Date = Date()) -> Self {
        // A missing App Group entitlement must not prevent the widget from loading.
        // In that case the widget is a working app launcher with honest status text.
        guard let store = UserDefaults(suiteName: TimbreWidgetConfig.group),
              let data = store.dictionary(forKey: TimbreWidgetConfig.key),
              let enabled = data["enabled"] as? Bool,
              let bands = data["bands"] as? Int else {
            return Self(date: date, hasStatus: false, isEnabled: false, bands: 0, effectCount: 0)
        }
        return Self(date: date, hasStatus: true, isEnabled: enabled,
                    bands: max(bands, 0), effectCount: max(data["effects"] as? Int ?? 0, 0))
    }
}

private struct TimbreProvider: TimelineProvider {
    func placeholder(in context: Context) -> TimbreEntry {
        TimbreEntry(date: .now, hasStatus: true, isEnabled: true, bands: 10, effectCount: 1)
    }

    func getSnapshot(in context: Context, completion: @escaping (TimbreEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : .current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TimbreEntry>) -> Void) {
        completion(Timeline(entries: [.current()], policy: .after(Date().addingTimeInterval(15 * 60))))
    }
}

private struct TimbreWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TimbreEntry

    private var stateLabel: String {
        entry.hasStatus ? (entry.isEnabled ? "EQ ON" : "EQ OFF") : "OPEN APP"
    }

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                VStack(spacing: 2) {
                    Image(systemName: "waveform.path.ecg").font(.system(size: 19, weight: .semibold))
                    Text(entry.hasStatus ? (entry.isEnabled ? "ON" : "OFF") : "Timbre")
                        .font(.system(size: entry.hasStatus ? 11 : 9, weight: .bold))
                }
            case .accessoryRectangular:
                HStack(spacing: 7) {
                    Image(systemName: "waveform.path.ecg")
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Timbre").font(.headline)
                        Text(entry.hasStatus ? "\(stateLabel) · \(entry.bands) bands" : "Tap to open Amazon Music")
                            .font(.caption2)
                    }
                }
            case .accessoryInline:
                Label("Timbre · \(stateLabel)", systemImage: "waveform.path.ecg")
            default:
                homeView
            }
        }
        .widgetURL(TimbreWidgetConfig.launchURL)
    }

    private var homeView: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.12, green: 0.08, blue: 0.23),
                                    Color(red: 0.04, green: 0.04, blue: 0.08)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Image(systemName: "waveform.path.ecg").font(.system(size: 23, weight: .medium))
                        .foregroundStyle(.yellow)
                    Text("TIMBRE").font(.system(size: 13, weight: .bold, design: .rounded))
                        .tracking(1.5).foregroundStyle(.white)
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
                Text(stateLabel).font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                if entry.hasStatus {
                    Text("\(entry.bands) bands · \(entry.effectCount) effects")
                        .font(.caption).foregroundStyle(.white.opacity(0.7))
                } else {
                    Text("Amazon Music + Timbre")
                        .font(.caption).foregroundStyle(.white.opacity(0.7))
                }
                if family == .systemMedium {
                    Text("Tap to return to the music player")
                        .font(.caption2).foregroundStyle(.yellow)
                }
            }
            .padding(17)
        }
    }
}

private struct TimbreStatusWidget: Widget {
    let kind = "com.soum91.timbre.status"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TimbreProvider()) { entry in
            TimbreWidgetView(entry: entry)
        }
        .configurationDisplayName("Amazon Music + Timbre")
        .description("Open your music and see the last known Timbre EQ status.")
        .supportedFamilies([.systemSmall, .systemMedium,
                            .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

@main
struct TimbreWidgetBundle: WidgetBundle {
    var body: some Widget {
        TimbreStatusWidget()
    }
}
