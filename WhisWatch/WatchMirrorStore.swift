#if os(watchOS)
import Foundation
import SwiftUI
import WatchKit

@MainActor
final class WatchMirrorStore: ObservableObject {
    @Published var snapshot = WorkoutSnapshot(
        exerciseName: "No Active Workout",
        setIndex: 0,
        setCount: 0,
        weightKg: nil,
        reps: nil,
        restRemaining: nil,
        phrase: nil,
        action: nil,
        isError: false
    )

    @Published var toast: CommandToastData?
    @Published var phoneReachable = false

    private let parser = CommandParser()
    private let sync = WatchSyncManager.shared

    init() {
        sync.onSnapshotReceived = { [weak self] snapshot in
            guard let self else { return }
            self.phoneReachable = true
            self.snapshot = snapshot

            if let phrase = snapshot.phrase, let action = snapshot.action {
                self.toast = CommandToastData(phrase: phrase, action: action, isError: snapshot.isError)
                self.playHaptic(error: snapshot.isError)

                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if self.toast?.phrase == phrase {
                        self.toast = nil
                    }
                }
            }
        }
    }

    func updateReachability() {
        phoneReachable = sync.isReachable
    }

    func send(command: VoiceCommand, phrase: String? = nil) {
        guard sync.isReachable else {
            phoneReachable = false
            toast = CommandToastData(
                phrase: phrase ?? "watch",
                action: "Phone not reachable-log on phone",
                isError: true
            )
            playHaptic(error: true)
            return
        }

        sync.sendIntent(WatchIntent(payload: IntentPayload(command: command), phrase: phrase))
    }

    func applyVoicePhrase(_ phrase: String) {
        let parsed = parser.parse(phrase, lastEditedField: nil)

        switch parsed {
        case .recognized(let command):
            send(command: command, phrase: phrase)
        case .ambiguousNumber(let value):
            send(command: .setWeight(Double(value)), phrase: phrase)
            toast = CommandToastData(
                phrase: phrase,
                action: "Ambiguous number; treated as \(value) kg",
                isError: true
            )
            playHaptic(error: true)
        case .unrecognized:
            toast = CommandToastData(
                phrase: phrase,
                action: "Could not parse command",
                isError: true
            )
            playHaptic(error: true)
        }
    }

    private func playHaptic(error: Bool) {
        if error {
            WKInterfaceDevice.current().play(.failure)
            Task {
                try? await Task.sleep(nanoseconds: 250_000_000)
                WKInterfaceDevice.current().play(.failure)
            }
        } else {
            WKInterfaceDevice.current().play(.success)
        }
    }
}
#endif
