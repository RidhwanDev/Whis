import AVFoundation
import Combine
import Foundation
import Speech

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

    var contextualStrings: [String] = []
    var onFinalTranscription: ((String) -> Void)?
    var onPartialTranscription: ((String) -> Void)?
    var onSessionEnded: ((SessionEndReason) -> Void)?

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en_US"))
    private let audioEngine = AVAudioEngine()
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var latestTranscript = ""

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
}
