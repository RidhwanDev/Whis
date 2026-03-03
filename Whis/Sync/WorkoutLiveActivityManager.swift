#if os(iOS)
import Foundation

#if canImport(ActivityKit)
import ActivityKit

@available(iOS 16.2, *)
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

@MainActor
@available(iOS 16.2, *)
final class WorkoutLiveActivityManager {
    static let shared = WorkoutLiveActivityManager()

    private var activity: Activity<LiftLoggerActivityAttributes>?

    private init() {}

    func startOrUpdate(sessionID: UUID, snapshot: WorkoutSnapshot) {
        let content = LiftLoggerActivityAttributes.ContentState(
            exerciseName: snapshot.exerciseName,
            setLabel: "Set \(snapshot.setIndex + 1)/\(snapshot.setCount)",
            weightText: snapshot.weightKg.map { formatWeight($0) + " kg" } ?? "-",
            repsText: snapshot.reps.map(String.init) ?? "-",
            restText: snapshot.restRemaining.map { "\($0)s" } ?? "-",
            actionText: snapshot.action ?? "Listening for command"
        )

        if let activity {
            Task {
                await activity.update(ActivityContent(state: content, staleDate: nil))
            }
            return
        }

        let attributes = LiftLoggerActivityAttributes(
            sessionID: sessionID.uuidString,
            title: "Hands-Free Lift"
        )

        do {
            activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: content, staleDate: nil)
            )
        } catch {
            // Keep silent; workout should not fail if Live Activity is unavailable.
        }
    }

    func end() {
        guard let activity else { return }
        let finalState = LiftLoggerActivityAttributes.ContentState(
            exerciseName: "Workout",
            setLabel: "Completed",
            weightText: "-",
            repsText: "-",
            restText: "-",
            actionText: "Session ended"
        )

        Task {
            await activity.end(ActivityContent(state: finalState, staleDate: .now), dismissalPolicy: .immediate)
        }
        self.activity = nil
    }

    private func formatWeight(_ value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int(value))
        }
        return String(format: "%.1f", value)
    }
}
#else
@MainActor
final class WorkoutLiveActivityManager {
    static let shared = WorkoutLiveActivityManager()
    private init() {}
    func startOrUpdate(sessionID: UUID, snapshot: WorkoutSnapshot) {}
    func end() {}
}
#endif
#endif
