import ActivityKit
import SwiftUI
import WidgetKit

struct LiftLoggerActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var exerciseName: String
        var setLabel: String
        var weightText: String
        var repsText: String
        var restText: String
        var actionText: String
    }

    var sessionID: String
    var title: String
}

struct WhisLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LiftLoggerActivityAttributes.self) { context in
            LockScreenLiveActivityView(state: context.state)
                .activityBackgroundTint(Color.black)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2 ) {
                        Text(context.state.exerciseName)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        Text(context.state.setLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(context.state.weightText)
                            .font(.caption.weight(.semibold))
                        Text("\(context.state.repsText) reps")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 8) {
                        Label(context.state.restText == "-" ? "No Rest" : "Rest \(context.state.restText)", systemImage: "timer")
                            .font(.caption)
                        Spacer(minLength: 0)
                        Text(context.state.actionText)
                            .font(.caption)
                            .lineLimit(1)
                    }
                }
            } compactLeading: {
                Text(shortExercise(context.state.exerciseName))
                    .font(.caption2.weight(.semibold))
            } compactTrailing: {
                Text(context.state.repsText)
                    .font(.caption2.weight(.semibold))
            } minimal: {
                Image(systemName: "waveform.circle.fill")
            }
            .widgetURL(URL(string: "whis://live"))
            .keylineTint(.cyan)
        }
    }

    private func shortExercise(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 6 {
            return trimmed
        }
        return String(trimmed.prefix(6))
    }
}

private struct LockScreenLiveActivityView: View {
    let state: LiftLoggerActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(state.exerciseName)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(state.setLabel)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                statChip(title: "KG", value: state.weightText)
                statChip(title: "REPS", value: state.repsText)
                statChip(title: "REST", value: state.restText)
            }

            Text(state.actionText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func statChip(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.monospacedDigit())
                .lineLimit(1)
        }
    }
}
