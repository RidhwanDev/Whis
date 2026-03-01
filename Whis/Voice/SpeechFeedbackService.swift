#if os(iOS)
import AVFoundation
import Foundation

@MainActor
final class SpeechFeedbackService {
    struct VoiceOption: Identifiable, Hashable {
        let identifier: String
        let displayName: String

        var id: String { identifier }
    }

    private struct Prosody {
        let rate: Float
        let pitch: Float
        let preDelay: TimeInterval
        let postDelay: TimeInterval
    }

    private enum IntentKey: String {
        case errorGeneric
        case errorAmbiguous
        case errorLowConfidence
        case errorCannotParse
        case errorMissingValues
        case weight
        case reps
        case doneNext
        case doneFinal
        case restStart
        case restStop
        case undo
        case switchExercise
        case clear
        case generic
    }

    private enum ParsedIntent {
        case errorGeneric
        case errorAmbiguous(value: String)
        case errorLowConfidence
        case errorCannotParse
        case errorMissingValues
        case weight(value: String)
        case reps(value: String)
        case doneNext(nextSet: String?)
        case doneFinal
        case restStart(seconds: String)
        case restStop
        case undo
        case switchExercise(name: String)
        case clear
        case generic

        var key: IntentKey {
            switch self {
            case .errorGeneric: return .errorGeneric
            case .errorAmbiguous: return .errorAmbiguous
            case .errorLowConfidence: return .errorLowConfidence
            case .errorCannotParse: return .errorCannotParse
            case .errorMissingValues: return .errorMissingValues
            case .weight: return .weight
            case .reps: return .reps
            case .doneNext: return .doneNext
            case .doneFinal: return .doneFinal
            case .restStart: return .restStart
            case .restStop: return .restStop
            case .undo: return .undo
            case .switchExercise: return .switchExercise
            case .clear: return .clear
            case .generic: return .generic
            }
        }
    }

    static let shared = SpeechFeedbackService()

    private let synthesizer = AVSpeechSynthesizer()
    private var cycleIndexByKey: [IntentKey: Int] = [:]
    private var lastPhraseByKey: [IntentKey: String] = [:]
    private var lastSpokenPhrase = ""
    private var lastSpokenAt: Date = .distantPast

    private init() {}

    func availableVoices() -> [VoiceOption] {
        AVSpeechSynthesisVoice
            .speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .sorted { lhs, rhs in
                if voiceScore(lhs) == voiceScore(rhs) {
                    return lhs.name == rhs.name ? lhs.language < rhs.language : lhs.name < rhs.name
                }
                return voiceScore(lhs) > voiceScore(rhs)
            }
            .map { voice in
                VoiceOption(
                    identifier: voice.identifier,
                    displayName: "\(voice.name)\(qualityLabel(for: voice)) (\(voice.language))"
                )
            }
    }

    func speakConfirmation(action: String, isError: Bool) {
        let enabled = UserDefaults.standard.bool(forKey: "settings.voiceFeedbackEnabled")
        guard enabled else { return }

        let intent = parseIntent(action: action, isError: isError)
        let phrase = phrase(for: intent)

        guard shouldSpeak(phrase) else { return }
        speak(phrase, prosody: prosody(for: intent))
    }

    private func shouldSpeak(_ phrase: String) -> Bool {
        let elapsed = Date().timeIntervalSince(lastSpokenAt)
        if phrase == lastSpokenPhrase, elapsed < 0.9 {
            return false
        }
        lastSpokenPhrase = phrase
        lastSpokenAt = .now
        return true
    }

    private func speak(_ text: String, prosody: Prosody) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = prosody.rate
        utterance.pitchMultiplier = prosody.pitch
        utterance.preUtteranceDelay = prosody.preDelay
        utterance.postUtteranceDelay = prosody.postDelay

        if let selectedIdentifier = UserDefaults.standard.string(forKey: "settings.voiceIdentifier"),
           !selectedIdentifier.isEmpty,
           let selectedVoice = AVSpeechSynthesisVoice(identifier: selectedIdentifier) {
            utterance.voice = selectedVoice
        } else {
            utterance.voice = preferredDefaultVoice()
        }

        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .word)
        }
        synthesizer.speak(utterance)
    }

    private func preferredDefaultVoice() -> AVSpeechSynthesisVoice? {
        let englishVoices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        if let usPremium = englishVoices.first(where: { $0.language == "en-US" && qualityLabel(for: $0) == " [Premium]" }) {
            return usPremium
        }
        if let usEnhanced = englishVoices.first(where: { $0.language == "en-US" && qualityLabel(for: $0) == " [Enhanced]" }) {
            return usEnhanced
        }
        return AVSpeechSynthesisVoice(language: "en-US") ?? englishVoices.first
    }

    private func parseIntent(action: String, isError: Bool) -> ParsedIntent {
        if isError {
            if action.contains("Did you mean") {
                let value = extractFirstMatch("Did you mean ([0-9]+)", from: action) ?? ""
                return .errorAmbiguous(value: value)
            }
            if action.contains("Low confidence") {
                return .errorLowConfidence
            }
            if action.contains("Could not parse command") {
                return .errorCannotParse
            }
            if action.contains("Enter reps or weight") {
                return .errorMissingValues
            }
            return .errorGeneric
        }

        if action.contains("Set weight to") {
            let value = extractFirstMatch("Set weight to ([0-9]+(?:\\.[0-9]+)?)", from: action) ?? ""
            return .weight(value: value)
        }

        if action.contains("Set reps to") {
            let value = extractFirstMatch("Set reps to ([0-9]+)", from: action) ?? ""
            return .reps(value: value)
        }

        if action.contains("Ready for set") {
            let nextSet = extractFirstMatch("Ready for set ([0-9]+)", from: action)
            return .doneNext(nextSet: nextSet)
        }

        if action.contains("Completed final set") {
            return .doneFinal
        }

        if action.contains("Started rest") {
            let seconds = extractFirstMatch("Started rest for ([0-9]+)", from: action) ?? ""
            return .restStart(seconds: seconds)
        }

        if action.contains("Rest stopped") {
            return .restStop
        }

        if action.contains("Undid last action") {
            return .undo
        }

        if action.contains("Switched to") {
            let name = extractFirstMatch("Switched to (.+)$", from: action) ?? "that exercise"
            return .switchExercise(name: name)
        }

        if action.contains("Cleared current set values") {
            return .clear
        }

        return .generic
    }

    private func phrase(for intent: ParsedIntent) -> String {
        switch intent {
        case .errorGeneric:
            return rotate(.errorGeneric, [
                "I could not apply that. Try again.",
                "That one did not land. Say it again.",
                "I missed that command. Give it another go."
            ])

        case .errorAmbiguous(let value):
            return rotate(.errorAmbiguous, [
                "Quick check: did you mean \(value) kilos or \(value) reps?",
                "I heard \(value). Should I use kilos or reps?",
                "That number is ambiguous. \(value) kilos or \(value) reps?"
            ])

        case .errorLowConfidence:
            return rotate(.errorLowConfidence, [
                "I am not fully confident. Please repeat clearly.",
                "Low confidence on that command. Try once more.",
                "I did not catch that cleanly. Say it again."
            ])

        case .errorCannotParse:
            return rotate(.errorCannotParse, [
                "I could not parse that. Try saying weight 80 or 8 reps.",
                "Not sure what to do with that command. Try weight 80.",
                "I did not understand that format. Try 8 reps."
            ])

        case .errorMissingValues:
            return rotate(.errorMissingValues, [
                "Add weight or reps first, then say done.",
                "I need a weight or rep value before completing the set.",
                "No values yet. Say weight or reps, then done."
            ])

        case .weight(let value):
            return rotate(.weight, [
                "Logged. \(value) kilos.",
                "Weight set to \(value) kilograms.",
                "Got it, \(value) kilos for this set."
            ])

        case .reps(let value):
            return rotate(.reps, [
                "Reps set to \(value).",
                "Got it, \(value) reps.",
                "Logged \(value) reps for this set."
            ])

        case .doneNext(let nextSet):
            let nextLabel = nextSet ?? "next"
            return rotate(.doneNext, [
                "Set complete. Moving to set \(nextLabel).",
                "Nice, set logged. You are on set \(nextLabel).",
                "Done. Ready for set \(nextLabel)."
            ])

        case .doneFinal:
            return rotate(.doneFinal, [
                "Final set complete.",
                "Nice work, that was your last set.",
                "All planned sets complete."
            ])

        case .restStart(let seconds):
            return rotate(.restStart, [
                "Rest started for \(seconds) seconds.",
                "Timer on, \(seconds) seconds rest.",
                "Taking \(seconds) seconds. I will be ready when you are."
            ])

        case .restStop:
            return rotate(.restStop, [
                "Rest ended.",
                "Rest stopped. Back to work.",
                "Timer off. Ready for the next set."
            ])

        case .undo:
            return rotate(.undo, [
                "Undone. I rolled back the last action.",
                "Last action reverted.",
                "Done, I have undone that."
            ])

        case .switchExercise(let name):
            return rotate(.switchExercise, [
                "Switched to \(name).",
                "Now on \(name).",
                "Exercise changed to \(name)."
            ])

        case .clear:
            return rotate(.clear, [
                "Current set cleared.",
                "Values cleared for this set.",
                "Done, weight and reps are cleared."
            ])

        case .generic:
            return rotate(.generic, [
                "Command applied.",
                "Done.",
                "Logged."
            ])
        }
    }

    private func prosody(for intent: ParsedIntent) -> Prosody {
        switch intent {
        case .errorGeneric, .errorAmbiguous, .errorLowConfidence, .errorCannotParse, .errorMissingValues:
            return Prosody(rate: 0.46, pitch: 0.94, preDelay: 0.02, postDelay: 0.08)

        case .doneNext, .doneFinal:
            return Prosody(rate: 0.5, pitch: 1.02, preDelay: 0.01, postDelay: 0.06)

        case .weight, .reps, .restStart, .restStop, .undo, .switchExercise, .clear, .generic:
            return Prosody(rate: 0.49, pitch: 0.99, preDelay: 0.01, postDelay: 0.05)
        }
    }

    private func rotate(_ key: IntentKey, _ options: [String]) -> String {
        guard !options.isEmpty else { return "Done." }

        let nextIndex = (cycleIndexByKey[key] ?? 0) % options.count
        cycleIndexByKey[key] = nextIndex + 1

        var phrase = options[nextIndex]
        if lastPhraseByKey[key] == phrase, options.count > 1 {
            let fallbackIndex = (nextIndex + 1) % options.count
            phrase = options[fallbackIndex]
            cycleIndexByKey[key] = fallbackIndex + 1
        }

        lastPhraseByKey[key] = phrase
        return phrase
    }

    private func extractFirstMatch(_ pattern: String, from text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(location: 0, length: text.utf16.count)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        guard match.numberOfRanges > 1 else { return nil }
        guard let valueRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[valueRange])
    }

    private func voiceScore(_ voice: AVSpeechSynthesisVoice) -> Int {
        var score = 0
        if voice.language == "en-US" { score += 20 }
        if voice.language.hasPrefix("en") { score += 10 }

        let quality = qualityLabel(for: voice)
        if quality == " [Premium]" {
            score += 100
        } else if quality == " [Enhanced]" {
            score += 50
        }

        return score
    }

    private func qualityLabel(for voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium:
            return " [Premium]"
        case .enhanced:
            return " [Enhanced]"
        default:
            return ""
        }
    }
}
#endif
