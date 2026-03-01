import AVFoundation
import Combine
import Foundation
import Speech

#if canImport(WhisperKit)
import WhisperKit
#endif

@MainActor
final class SpeechRecognizerService: NSObject, ObservableObject {
    enum ListeningMode {
        case singleUtterance
        case continuous
    }

    enum SessionEndReason {
        case finalResult
        case error
        case stopped
    }

    @Published private(set) var isRecording = false
    @Published private(set) var authorizationDenied = false
    @Published private(set) var mode: ListeningMode = .singleUtterance
    @Published private(set) var activeBackend: TranscriptionBackend = .apple
    @Published private(set) var backendNotice: String?

    var contextualStrings: [String] = []
    var onFinalTranscription: ((String) -> Void)?
    var onPartialTranscription: ((String) -> Void)?
    var onSessionEnded: ((SessionEndReason) -> Void)?

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en_US"))
    private let audioEngine = AVAudioEngine()
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var latestTranscript = ""

#if canImport(WhisperKit)
    private var whisperKit: WhisperKit?
    private var loadedWhisperModel: WhisperModelSize?
    private var audioStreamTranscriber: AudioStreamTranscriber?
    private var whisperTask: Task<Void, Never>?
#endif

    func requestPermissionsIfNeeded() async {
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }

        let micGranted = await AVAudioApplication.requestRecordPermission()
        authorizationDenied = speechStatus != .authorized || !micGranted
    }

    func startSingleUtterance() {
        mode = .singleUtterance
        startListeningSession()
    }

    func startContinuousListening() {
        mode = .continuous
        startListeningSession()
    }

    func stopListening() {
        stopCurrentSession(emitLatestTranscript: false, reason: .stopped)
    }

    func resetContinuousContext() {
        guard mode == .continuous else { return }
        stopCurrentSession(emitLatestTranscript: false, reason: .stopped)
    }

    private func startListeningSession() {
        guard !authorizationDenied else { return }
        guard !isRecording else { return }

        latestTranscript = ""

        switch selectedBackend {
        case .apple:
            activeBackend = .apple
            backendNotice = nil
            startAppleListeningSession()

        case .whisper:
            startWhisperListeningSessionOrFallback()
        }
    }

    private var selectedBackend: TranscriptionBackend {
        TranscriptionBackend(rawValue: UserDefaults.standard.string(forKey: "settings.transcriptionBackend") ?? "apple") ?? .apple
    }

    private var selectedWhisperModel: WhisperModelSize {
        WhisperModelSize(rawValue: UserDefaults.standard.string(forKey: "settings.whisperModel") ?? "base") ?? .base
    }

    private func startAppleListeningSession() {
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest?.shouldReportPartialResults = true
        recognitionRequest?.taskHint = .confirmation
        recognitionRequest?.contextualStrings = contextualStrings
        if #available(iOS 16.0, watchOS 9.0, *) {
            recognitionRequest?.addsPunctuation = false
        }

        guard let recognitionRequest else { return }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .allowBluetoothHFP])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
                recognitionRequest.append(buffer)
            }

            audioEngine.prepare()
            try audioEngine.start()

            recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
                guard let self else { return }

                if let result {
                    self.latestTranscript = result.bestTranscription.formattedString
                    self.onPartialTranscription?(self.latestTranscript)

                    if result.isFinal {
                        self.handleFinalResult(self.latestTranscript)
                        return
                    }
                }

                if error != nil {
                    self.handleRecognitionFailure()
                }
            }

            isRecording = true
        } catch {
            handleRecognitionFailure()
        }
    }

    private func startWhisperListeningSessionOrFallback() {
#if canImport(WhisperKit)
        guard mode == .continuous else {
            activeBackend = .apple
            backendNotice = "Whisper currently supports continuous mode; using Apple Speech for push-to-talk."
            startAppleListeningSession()
            return
        }

        activeBackend = .whisper
        backendNotice = "Loading Whisper \(selectedWhisperModel.displayName)..."
        isRecording = true

        whisperTask?.cancel()
        whisperTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let model = self.selectedWhisperModel
                let whisper = try await self.prepareWhisper(model: model)
                guard let tokenizer = whisper.tokenizer else {
                    throw NSError(domain: "Whis", code: 101, userInfo: [NSLocalizedDescriptionKey: "Whisper tokenizer unavailable."])
                }

                let options = DecodingOptions(
                    verbose: false,
                    task: .transcribe,
                    language: "en",
                    withoutTimestamps: true,
                    wordTimestamps: false,
                    compressionRatioThreshold: 2.4,
                    logProbThreshold: -1.0,
                    noSpeechThreshold: 0.6
                )

                self.audioStreamTranscriber = AudioStreamTranscriber(
                    audioEncoder: whisper.audioEncoder,
                    featureExtractor: whisper.featureExtractor,
                    segmentSeeker: whisper.segmentSeeker,
                    textDecoder: whisper.textDecoder,
                    tokenizer: tokenizer,
                    audioProcessor: whisper.audioProcessor,
                    decodingOptions: options
                ) { [weak self] oldState, newState in
                    guard let self else { return }
                    Task { @MainActor [weak self] in
                        self?.handleWhisperStateChange(oldState: oldState, newState: newState)
                    }
                }

                self.backendNotice = "Whisper \(model.displayName) active"

                guard let transcriber = self.audioStreamTranscriber else {
                    throw NSError(domain: "Whis", code: 102, userInfo: [NSLocalizedDescriptionKey: "Whisper stream unavailable."])
                }

                try await transcriber.startStreamTranscription()

                if !Task.isCancelled {
                    self.stopWhisperSession(emitLatestTranscript: false, reason: .stopped, cancelTask: false)
                }
            } catch is CancellationError {
                self.stopWhisperSession(emitLatestTranscript: false, reason: .stopped, cancelTask: false)
            } catch {
                self.backendNotice = "Whisper failed: \(error.localizedDescription). Falling back to Apple Speech."
                self.stopWhisperSession(emitLatestTranscript: false, reason: .error, cancelTask: false)
                self.activeBackend = .apple
                self.startAppleListeningSession()
            }
        }
#else
        activeBackend = .apple
        backendNotice = "Whisper runtime not linked in this build; using Apple Speech."
        startAppleListeningSession()
#endif
    }

    private func handleFinalResult(_ transcript: String) {
        let value = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty {
            onFinalTranscription?(value)
        }
        stopCurrentSession(emitLatestTranscript: false, reason: .finalResult)
    }

    private func handleRecognitionFailure() {
        stopCurrentSession(emitLatestTranscript: false, reason: .error)
    }

    private func stopCurrentSession(emitLatestTranscript: Bool, reason: SessionEndReason) {
        if activeBackend == .whisper {
            stopWhisperSession(emitLatestTranscript: emitLatestTranscript, reason: reason, cancelTask: true)
            return
        }

        let transcript = latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let hadActiveSession = isRecording || recognitionTask != nil || recognitionRequest != nil

        recognitionRequest?.endAudio()
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil

        if isRecording {
            isRecording = false
        }

        if emitLatestTranscript, !transcript.isEmpty {
            onFinalTranscription?(transcript)
        }

        if hadActiveSession {
            onSessionEnded?(reason)
        }
    }

#if canImport(WhisperKit)
    private func prepareWhisper(model: WhisperModelSize) async throws -> WhisperKit {
        if let whisperKit, loadedWhisperModel == model {
            return whisperKit
        }

        if let existing = whisperKit {
            await existing.unloadModels()
        }

        let config = WhisperKitConfig(
            model: model.whisperKitModelName,
            verbose: false,
            logLevel: .none,
            prewarm: false,
            load: true,
            download: true
        )

        let whisper = try await WhisperKit(config)
        whisperKit = whisper
        loadedWhisperModel = model
        return whisper
    }

    private func handleWhisperStateChange(oldState: AudioStreamTranscriber.State, newState: AudioStreamTranscriber.State) {
        let transcript = composeWhisperTranscript(from: newState)
        guard transcript != latestTranscript else { return }

        latestTranscript = transcript
        guard !transcript.isEmpty else { return }
        onPartialTranscription?(transcript)
    }

    private func composeWhisperTranscript(from state: AudioStreamTranscriber.State) -> String {
        let confirmed = state.confirmedSegments.map(\.text)
        let unconfirmed = state.unconfirmedSegments.map(\.text)
        let merged = (confirmed + unconfirmed)
            .joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return merged == "Waiting for speech..." ? "" : merged
    }

    private func stopWhisperSession(
        emitLatestTranscript: Bool,
        reason: SessionEndReason,
        cancelTask: Bool
    ) {
        let transcript = latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let hadActiveSession = isRecording || whisperTask != nil || audioStreamTranscriber != nil

        if cancelTask {
            whisperTask?.cancel()
        }
        whisperTask = nil

        if let transcriber = audioStreamTranscriber {
            Task {
                await transcriber.stopStreamTranscription()
            }
        }
        audioStreamTranscriber = nil

        if isRecording {
            isRecording = false
        }

        if emitLatestTranscript, !transcript.isEmpty {
            onFinalTranscription?(transcript)
        }

        if hadActiveSession {
            onSessionEnded?(reason)
        }
    }
#else
    private func stopWhisperSession(
        emitLatestTranscript _: Bool,
        reason _: SessionEndReason,
        cancelTask _: Bool
    ) {
        isRecording = false
    }
#endif
}
