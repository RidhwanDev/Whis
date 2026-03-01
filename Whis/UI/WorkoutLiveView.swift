import Combine
import SwiftUI

struct WorkoutLiveView: View {
    @ObservedObject var store: WorkoutStore
    @StateObject private var speechService = SpeechRecognizerService()

    @AppStorage("settings.alwaysListening") private var alwaysListening = true
    @AppStorage("settings.wakeWord") private var wakeWord = "Lift"

    @State private var wakeArmedUntil: Date?
    @State private var listeningStatus = "Say wake word then your command"
    @State private var liveTranscript = ""
    @State private var pulse = false
    @State private var lastExecutedCommand = ""
    @State private var lastExecutedAt: Date = .distantPast
    @State private var isManuallyPaused = false
    @State private var wakeSessionLastActivity: Date?
    @State private var ignoreFinalTranscriptsUntil: Date = .distantPast
    @State private var ignorePartialTranscriptsUntil: Date = .distantPast
    @State private var lastPartialHeardAt: Date?
    @State private var pendingCommandPhrase: String?
    @State private var pendingSourcePhrase: String?

    private let parser = CommandParser()
    private let wakeTimeoutSeconds: TimeInterval = 8
    private let contextAutoClearAfterSilenceSeconds: TimeInterval = 1.5
    private let finalTranscriptCooldownSeconds: TimeInterval = 1.0

    var body: some View {
        NavigationStack {
            ZStack {
                liveAuraBackground
                    .ignoresSafeArea()
                
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {
                        exercisePicker

                        if alwaysListening {
                            listeningBanner
                        }

                        if let restRemaining = store.restRemainingSeconds {
                            restBanner(seconds: restRemaining)
                        }

                        currentSetCard

                        if let pending = store.pendingAmbiguity {
                            ambiguityResolver(pending)
                        }

                        controls
                        history
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
            }
            .navigationTitle("Live Workout")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Finish") {
                        store.finishWorkout()
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $store.showingSummary) {
            SessionSummaryView(store: store)
        }
        .commandToast(store.toast)
        .task {
            await speechService.requestPermissionsIfNeeded()
            speechService.onFinalTranscription = { phrase in
                handleFinalTranscript(phrase)
            }
            speechService.onSessionEnded = { reason in
                handleSpeechSessionEnded(reason)
            }
            speechService.onPartialTranscription = { phrase in
                if alwaysListening {
                    guard Date() >= ignorePartialTranscriptsUntil else { return }
                    lastPartialHeardAt = .now
                    liveTranscript = phrase
                    handlePartialWakeDetection(phrase)
                }
            }
            speechService.contextualStrings = contextualHints
            configureListeningMode()
        }
        .onChange(of: alwaysListening) { _, _ in
            configureListeningMode()
        }
        .onDisappear {
            speechService.stopListening()
        }
        .onReceive(Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()) { _ in
            store.heartbeat()
            if let wakeArmedUntil, wakeArmedUntil <= .now {
                clearWakeSession(resetSpeechContext: true, status: "Say \"\(wakeWord)\" then your command")
            }
            
            if let lastPartialHeardAt,
               Date().timeIntervalSince(lastPartialHeardAt) >= contextAutoClearAfterSilenceSeconds,
               alwaysListening,
               !isManuallyPaused,
               isWakeArmed {
                if let pendingCommandPhrase,
                   !pendingCommandPhrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let pendingSourcePhrase {
                    executeCommandIfReady(pendingCommandPhrase, sourcePhrase: pendingSourcePhrase)
                } else {
                    clearWakeSession(resetSpeechContext: true, status: "Still listening. Say command again")
                }
            }
        }
    }

    private var listeningBanner: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    Circle()
                        .fill(indicatorColor.opacity(0.18))
                        .frame(width: 78, height: 78)
                        .scaleEffect(pulse ? 1.18 : 0.92)
                        .animation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true), value: pulse)
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [indicatorColor.opacity(0.9), indicatorColor.opacity(0.45)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 52, height: 52)
                        .shadow(color: indicatorColor.opacity(0.45), radius: 14, x: 0, y: 5)
                    Image(systemName: speechService.isRecording ? "waveform" : "mic.slash.fill")
                        .font(.title3.bold())
                        .foregroundStyle(.white.opacity(0.95))
                }
                
                VStack(alignment: .leading, spacing: 3) {
                    Text(indicatorTitle.uppercased())
                        .font(.system(.caption, design: .rounded, weight: .bold))
                        .kerning(1.2)
                        .foregroundStyle(indicatorColor.opacity(0.95))
                    Text(listeningStatus)
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                        .lineLimit(2)
                        .foregroundStyle(.white)
                }
                Spacer(minLength: 0)
            }
            
            if !liveTranscript.isEmpty {
                Text("Heard: \"\(liveTranscript)\"")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(2)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(16)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.12, green: 0.13, blue: 0.16),
                    Color(red: 0.08, green: 0.09, blue: 0.11)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(indicatorColor.opacity(0.4), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 20, x: 0, y: 9)
        .onAppear { pulse = true }
    }

    private var exercisePicker: some View {
        Picker("Exercise", selection: Binding(
            get: { store.selectedExercise?.name ?? "" },
            set: { store.selectExercise(named: $0) }
        )) {
            ForEach(store.catalog, id: \.id) { item in
                Text(item.name).tag(item.name)
            }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    private var currentSetCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(store.selectedExercise?.name ?? "No Exercise")
                    .font(.title3.bold())
                Spacer()
                Text("Set \((store.selectedExercise?.currentSetIndex ?? 0) + 1)/\(store.selectedExercise?.targetSetCount ?? 0)")
                    .foregroundStyle(.secondary)
            }

            HStack {
                metricCard(title: "Weight", value: weightLabel)
                metricCard(title: "Reps", value: repsLabel)
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        )
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                valueButton(label: "-\(weightStepLabel)kg") { store.updateCurrentWeight(by: -store.weightIncrement) }
                    .frame(maxWidth: .infinity)
                valueButton(label: "+\(weightStepLabel)kg") { store.updateCurrentWeight(by: store.weightIncrement) }
                    .frame(maxWidth: .infinity)
                valueButton(label: "-1 rep") { store.updateCurrentReps(by: -1) }
                    .frame(maxWidth: .infinity)
                valueButton(label: "+1 rep") { store.updateCurrentReps(by: 1) }
                    .frame(maxWidth: .infinity)
            }

            HStack(spacing: 10) {
                controlButton("Previous") {
                    store.applyTranscription("previous", source: .phone)
                }

                controlButton("Done", prominent: true) {
                    store.applyTranscription("done", source: .phone)
                }

                controlButton("Next") {
                    store.applyTranscription("next", source: .phone)
                }
            }

            micButton
        }
        .padding(14)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
    }

    private var micButton: some View {
        Button {
            if alwaysListening {
                isManuallyPaused.toggle()
                if isManuallyPaused {
                    speechService.stopListening()
                    listeningStatus = "Listening paused"
                } else {
                    speechService.startContinuousListening()
                    listeningStatus = "Say \"\(wakeWord)\" then your command"
                }
            } else {
                if speechService.isRecording {
                    speechService.stopListening()
                } else {
                    speechService.startSingleUtterance()
                }
            }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: speechService.isRecording ? "waveform" : "mic.fill")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text(buttonLabel)
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(.white)
            .frame(width: 106, height: 106)
            .background(
                RadialGradient(
                    colors: [
                        (speechService.isRecording ? Color.red : Color.accentColor).opacity(0.95),
                        (speechService.isRecording ? Color.red : Color.accentColor).opacity(0.65)
                    ],
                    center: .center,
                    startRadius: 6,
                    endRadius: 84
                ),
                in: Circle()
            )
            .shadow(color: (speechService.isRecording ? Color.red : Color.accentColor).opacity(0.5), radius: 20, x: 0, y: 10)
        }
        .buttonStyle(.plain)
        .padding(.top, 6)
    }

    private var buttonLabel: String {
        if alwaysListening {
            return isManuallyPaused ? "Resume" : "Pause"
        }
        return speechService.isRecording ? "Stop" : "Tap"
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent Sets")
                .font(.headline)
                .foregroundStyle(.white)

            if store.lastThreeCompletedSets().isEmpty {
                Text("No completed sets yet")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }

            ForEach(store.lastThreeCompletedSets(), id: \.id) { set in
                HStack {
                    Text("Set \(set.index + 1)")
                    Spacer()
                    Text("\(set.reps ?? 0) reps @ \(formatWeight(set.weightKg)) kg")
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
    }

    private func ambiguityResolver(_ pending: AmbiguousPrompt) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\"\(pending.phrase)\" is ambiguous")
                .font(.subheadline)

            HStack(spacing: 12) {
                Button("Use \(pending.value) kg") {
                    store.resolveAmbiguousNumber(asReps: false)
                }
                .buttonStyle(.bordered)

                Button("Use \(pending.value) reps") {
                    store.resolveAmbiguousNumber(asReps: true)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func metricCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func valueButton(label: String, action: @escaping () -> Void) -> some View {
        Button(label, action: action)
            .font(.system(.subheadline, design: .rounded, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.16), lineWidth: 1)
            )
    }

    private func restBanner(seconds: Int) -> some View {
        HStack {
            Label("Rest \(seconds)s", systemImage: "timer")
                .font(.headline)
            Spacer()
            Button("Stop") {
                store.applyTranscription("stop rest", source: .phone)
            }
            .buttonStyle(.bordered)
        }
        .padding(10)
        .background(.orange.opacity(0.18), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.orange.opacity(0.4), lineWidth: 1)
        )
    }

    private var weightLabel: String {
        formatWeight(store.currentSet?.weightKg)
    }

    private var repsLabel: String {
        guard let reps = store.currentSet?.reps else { return "-" }
        return "\(reps)"
    }

    private var weightStepLabel: String {
        formatWeight(store.weightIncrement)
    }

    private func formatWeight(_ value: Double?) -> String {
        guard let value else { return "-" }
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int(value))
        }
        return String(format: "%.1f", value)
    }

    private func configureListeningMode() {
        speechService.contextualStrings = contextualHints
        if alwaysListening {
            if isManuallyPaused {
                speechService.stopListening()
                listeningStatus = "Listening paused"
            } else {
                speechService.startContinuousListening()
                listeningStatus = "Say \"\(wakeWord)\" then your command"
            }
            liveTranscript = ""
        } else {
            speechService.stopListening()
            wakeArmedUntil = nil
            isManuallyPaused = false
            listeningStatus = "Tap mic and speak a command"
            liveTranscript = ""
        }
    }

    private func handleFinalTranscript(_ phrase: String) {
        guard Date() >= ignoreFinalTranscriptsUntil else { return }
        
        if alwaysListening {
            lastPartialHeardAt = .now
            handlePartialWakeDetection(phrase)
        } else {
            store.applyTranscription(phrase, source: .phone)
        }
    }

    private func handlePartialWakeDetection(_ phrase: String) {
        guard alwaysListening else { return }
        let tokens = tokenize(phrase)
        guard !tokens.isEmpty else { return }

        if let wakeIndex = tokens.firstIndex(where: { wakeAliases.contains($0) }) {
            let remaining = Array(tokens.suffix(from: wakeIndex + 1))
            wakeArmedUntil = .now.addingTimeInterval(wakeTimeoutSeconds)
            wakeSessionLastActivity = .now

            if remaining.isEmpty {
                listeningStatus = "Wake word heard. Say command now"
                liveTranscript = phrase
                pendingCommandPhrase = nil
                pendingSourcePhrase = nil
                return
            }

            pendingCommandPhrase = remaining.joined(separator: " ")
            pendingSourcePhrase = phrase
            listeningStatus = "Listening for command…"
            return
        }
        
        if let wakeArmedUntil, wakeArmedUntil > .now {
            pendingCommandPhrase = tokens.joined(separator: " ")
            pendingSourcePhrase = phrase
            wakeSessionLastActivity = .now
            listeningStatus = "Listening for command…"
        }
    }
    
    private var isWakeArmed: Bool {
        if let wakeArmedUntil {
            return wakeArmedUntil > .now
        }
        return false
    }
    
    private var indicatorColor: Color {
        if isManuallyPaused || !speechService.isRecording { return .orange }
        return isWakeArmed ? .yellow : .green
    }
    
    private var indicatorTitle: String {
        if isManuallyPaused || !speechService.isRecording { return "Listening paused" }
        return isWakeArmed ? "Wake heard" : "Always listening"
    }
    
    private var liveAuraBackground: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.02, green: 0.03, blue: 0.05),
                    Color(red: 0.05, green: 0.06, blue: 0.10),
                    Color(red: 0.03, green: 0.04, blue: 0.08)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            
            Circle()
                .fill(indicatorColor.opacity(0.2))
                .frame(width: 340, height: 340)
                .blur(radius: 44)
                .offset(x: pulse ? -110 : -50, y: pulse ? -230 : -180)
                .animation(.easeInOut(duration: 4.8).repeatForever(autoreverses: true), value: pulse)
            
            Circle()
                .fill(Color.blue.opacity(0.14))
                .frame(width: 300, height: 300)
                .blur(radius: 48)
                .offset(x: pulse ? 140 : 70, y: pulse ? 210 : 250)
                .animation(.easeInOut(duration: 5.6).repeatForever(autoreverses: true), value: pulse)
        }
    }

    private func controlButton(_ title: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.system(.subheadline, design: .rounded, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                (prominent ? Color.green.opacity(0.28) : Color.white.opacity(0.12)),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke((prominent ? Color.green.opacity(0.65) : Color.white.opacity(0.18)), lineWidth: 1)
            )
            .buttonStyle(.plain)
    }

    private func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "[^a-z0-9\\s.]", with: " ", options: .regularExpression)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
    }
    
    private var wakeAliases: Set<String> {
        let selected = wakeWord.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        var aliases: Set<String> = [selected]
        switch selected {
        case "whis":
            aliases.formUnion(["wis", "whiz", "whizz", "wiz", "wes", "quiz", "this"])
        case "lift":
            aliases.formUnion(["lifts", "left"])
        case "logger":
            aliases.formUnion(["log", "lagger"])
        case "ready":
            aliases.formUnion(["reddy"])
        default:
            break
        }
        return aliases
    }
    
    private var contextualHints: [String] {
        [wakeWord, "weight", "reps", "done", "next", "previous", "rest", "stop rest", "undo", "clear", "exercise"]
    }
    
    private func executeCommandIfReady(_ commandPhrase: String, sourcePhrase: String) {
        let normalizedCommand = commandPhrase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedCommand.isEmpty else { return }

        if normalizedCommand == lastExecutedCommand, Date().timeIntervalSince(lastExecutedAt) < 1.0 {
            return
        }

        lastExecutedCommand = normalizedCommand
        lastExecutedAt = .now
        lastPartialHeardAt = nil
        listeningStatus = "Executed: \(commandPhrase)"
        liveTranscript = sourcePhrase
        store.applyTranscription(commandPhrase, source: .phone)
        
        if alwaysListening {
            // Reset speech stream after accepted command so prior transcript does not pollute the next command.
            liveTranscript = ""
            clearWakeSession(resetSpeechContext: true, status: "Say \"\(wakeWord)\" then your command")
        }
    }

    private func handleSpeechSessionEnded(_ reason: SpeechRecognizerService.SessionEndReason) {
        guard alwaysListening else { return }
        guard !isManuallyPaused else { return }
        guard speechService.mode == .continuous else { return }
        guard !speechService.isRecording else { return }

        // Single owner of restart timing to avoid re-entrant restart loops.
        let delay: UInt64 = (reason == .error) ? 450_000_000 : 250_000_000
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: delay)
            guard alwaysListening, !isManuallyPaused else { return }
            guard speechService.mode == .continuous, !speechService.isRecording else { return }
            speechService.startContinuousListening()
        }
    }

    private func clearWakeSession(resetSpeechContext: Bool, status: String) {
        wakeArmedUntil = nil
        wakeSessionLastActivity = nil
        lastPartialHeardAt = nil
        pendingCommandPhrase = nil
        pendingSourcePhrase = nil
        listeningStatus = status
        ignoreFinalTranscriptsUntil = .now.addingTimeInterval(finalTranscriptCooldownSeconds)
        ignorePartialTranscriptsUntil = .now.addingTimeInterval(0.35)
        if resetSpeechContext, alwaysListening {
            speechService.resetContinuousContext()
        }
    }
}
