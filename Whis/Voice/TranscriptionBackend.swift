import Foundation

enum TranscriptionBackend: String, CaseIterable, Identifiable {
    case apple
    case whisper

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .apple:
            return "Apple Speech"
        case .whisper:
            return "Whisper (On-Device)"
        }
    }
}

enum WhisperModelSize: String, CaseIterable, Identifiable {
    case base
    case small

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .base:
            return "Base"
        case .small:
            return "Small"
        }
    }

    var whisperKitModelName: String {
        switch self {
        case .base:
            return "base"
        case .small:
            return "small"
        }
    }
}
