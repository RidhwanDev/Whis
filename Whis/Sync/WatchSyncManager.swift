import Foundation
import SwiftUI
import WatchConnectivity
import Combine

struct WorkoutSnapshot: Codable, Equatable {
    var exerciseName: String
    var setIndex: Int
    var setCount: Int
    var weightKg: Double?
    var reps: Int?
    var restRemaining: Int?
    var phrase: String?
    var action: String?
    var isError: Bool
}

struct WatchIntent: Codable, Equatable {
    var payload: IntentPayload
    var phrase: String?
}

enum VoiceCommandDTO: String, Codable {
    case done
    case next
    case previous
    case undo
    case clear
    case stopRest
    case setWeight
    case setReps
    case doneWithReps
    case rest
    case switchExercise

    init(from command: VoiceCommand) {
        switch command {
        case .done: self = .done
        case .next: self = .next
        case .previous: self = .previous
        case .undo: self = .undo
        case .clear: self = .clear
        case .stopRest: self = .stopRest
        case .setWeight: self = .setWeight
        case .setReps: self = .setReps
        case .doneWithReps: self = .doneWithReps
        case .rest: self = .rest
        case .switchExercise: self = .switchExercise
        }
    }
}

struct IntentPayload: Codable, Equatable {
    var type: VoiceCommandDTO
    var doubleValue: Double?
    var intValue: Int?
    var stringValue: String?

    init(command: VoiceCommand) {
        type = VoiceCommandDTO(from: command)
        switch command {
        case .setWeight(let value):
            doubleValue = value
        case .setReps(let value), .doneWithReps(let value), .rest(let value):
            intValue = value
        case .switchExercise(let value):
            stringValue = value
        default:
            break
        }
    }

    func toVoiceCommand() -> VoiceCommand? {
        switch type {
        case .done: return .done
        case .next: return .next
        case .previous: return .previous
        case .undo: return .undo
        case .clear: return .clear
        case .stopRest: return .stopRest
        case .setWeight:
            guard let doubleValue else { return nil }
            return .setWeight(doubleValue)
        case .setReps:
            guard let intValue else { return nil }
            return .setReps(intValue)
        case .doneWithReps:
            guard let intValue else { return nil }
            return .doneWithReps(intValue)
        case .rest:
            guard let intValue else { return nil }
            return .rest(intValue)
        case .switchExercise:
            guard let stringValue else { return nil }
            return .switchExercise(stringValue)
        }
    }
}

@MainActor
final class WatchSyncManager: NSObject, ObservableObject {
    static let shared = WatchSyncManager()

    @Published private(set) var isReachable = false

    var onIntentReceived: ((WatchIntent) -> Void)?
    var onSnapshotReceived: ((WorkoutSnapshot) -> Void)?

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private override init() {
        super.init()
        activateSessionIfAvailable()
    }

    private func activateSessionIfAvailable() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        isReachable = session.isReachable
    }

    func sendIntent(_ intent: WatchIntent) {
        send(kind: "intent", payload: intent)
    }

    func sendSnapshot(_ snapshot: WorkoutSnapshot) {
        send(kind: "snapshot", payload: snapshot)
    }

    private func send<T: Encodable>(kind: String, payload: T) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        isReachable = session.isReachable

        guard session.isReachable, let data = try? encoder.encode(payload) else { return }

        session.sendMessage(["kind": kind, "data": data], replyHandler: nil) { [weak self] _ in
            Task { @MainActor in
                self?.isReachable = false
            }
        }
    }

    private func decodeIncoming(_ message: [String: Any]) {
        guard let kind = message["kind"] as? String,
              let data = message["data"] as? Data else {
            return
        }

        switch kind {
        case "intent":
            guard let intent = try? decoder.decode(WatchIntent.self, from: data) else { return }
            onIntentReceived?(intent)
        case "snapshot":
            guard let snapshot = try? decoder.decode(WorkoutSnapshot.self, from: data) else { return }
            onSnapshotReceived?(snapshot)
        default:
            break
        }
    }
}

extension WatchSyncManager: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            self.isReachable = session.isReachable
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.isReachable = session.isReachable
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in
            self.decodeIncoming(message)
        }
    }

#if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
#endif
}
