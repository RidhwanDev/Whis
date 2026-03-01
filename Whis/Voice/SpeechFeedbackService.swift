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

    static let shared = SpeechFeedbackService()

    private let synthesizer = AVSpeechSynthesizer()
    private var cycleIndexByKey: [String: Int] = [:]

    private init() {}

    func availableVoices() -> [VoiceOption] {
        AVSpeechSynthesisVoice
            .speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .sorted { lhs, rhs in
                lhs.name == rhs.name ? lhs.language < rhs.language : lhs.name < rhs.name
            }
            .map { voice in
                VoiceOption(identifier: voice.identifier, displayName: "\(voice.name) (\(voice.language))")
            }
    }

    func speakConfirmation(action: String, isError: Bool) {
        let enabled = UserDefaults.standard.bool(forKey: "settings.voiceFeedbackEnabled")
        guard enabled else { return }

        let phrase = phraseForAction(action: action, isError: isError)
        speak(phrase)
    }

    private func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.48
        utterance.pitchMultiplier = 1.0
        utterance.preUtteranceDelay = 0.02

        if let selectedIdentifier = UserDefaults.standard.string(forKey: "settings.voiceIdentifier"),
           let selectedVoice = AVSpeechSynthesisVoice(identifier: selectedIdentifier) {
            utterance.voice = selectedVoice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        }

        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        synthesizer.speak(utterance)
    }

    private func phraseForAction(action: String, isError: Bool) -> String {
        if isError {
            let options = [
                "I didn’t catch that clearly.",
                "I couldn’t apply that command.",
                "Please try that command again."
            ]
            return cycle("error", options)
        }

        if action.contains("Set weight to") {
            let value = extractFirstMatch("Set weight to ([0-9]+(?:\\.[0-9]+)?)", from: action) ?? ""
            let options = [
                "Weight logged. \(value) kilograms.",
                "Got it. \(value) kilograms.",
                "Weight set to \(value) kilograms."
            ]
            return cycle("weight", options)
        }

        if action.contains("Set reps to") {
            let value = extractFirstMatch("Set reps to ([0-9]+)", from: action) ?? ""
            let options = [
                "Reps logged. \(value).",
                "You’re doing \(value) reps.",
                "Reps set to \(value)."
            ]
            return cycle("reps", options)
        }

        if action.contains("Ready for set") {
            let options = [
                "Set complete. Moving to the next set.",
                "Great. Next set is ready.",
                "Completed. You’re on the next set now."
            ]
            return cycle("doneNext", options)
        }

        if action.contains("Completed final set") {
            let options = [
                "Final set complete.",
                "Workout set complete.",
                "You finished the last set."
            ]
            return cycle("doneFinal", options)
        }

        if action.contains("Started rest") {
            let seconds = extractFirstMatch("Started rest for ([0-9]+)", from: action) ?? ""
            let options = [
                "Rest timer started for \(seconds) seconds.",
                "Rest started. \(seconds) seconds.",
                "Taking \(seconds) seconds of rest."
            ]
            return cycle("restStart", options)
        }

        if action.contains("Rest stopped") {
            return cycle("restStop", ["Rest stopped.", "Back to work."])
        }

        if action.contains("Undid last action") {
            return cycle("undo", ["Undid the last action.", "Last command reverted."])
        }

        if action.contains("Switched to") {
            let name = extractFirstMatch("Switched to (.+)$", from: action) ?? "that exercise"
            return cycle("switchExercise", ["Switched to \(name).", "Now on \(name)."])
        }

        return cycle("generic", ["Command applied.", "Done.", "Logged."])
    }

    private func cycle(_ key: String, _ options: [String]) -> String {
        guard !options.isEmpty else { return "Done." }
        let next = (cycleIndexByKey[key] ?? 0) % options.count
        cycleIndexByKey[key] = next + 1
        return options[next]
    }

    private func extractFirstMatch(_ pattern: String, from text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(location: 0, length: text.utf16.count)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        guard match.numberOfRanges > 1 else { return nil }
        guard let valueRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[valueRange])
    }
}
#endif
