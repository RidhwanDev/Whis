#if os(watchOS)
import SwiftUI

struct WatchWorkoutView: View {
    @StateObject private var mirrorStore = WatchMirrorStore()
    @StateObject private var speechService = SpeechRecognizerService()
    @State private var micPressing = false

    var body: some View {
        VStack(spacing: 8) {
            if !mirrorStore.phoneReachable {
                Text("Phone not reachable-log on phone")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Text(mirrorStore.snapshot.exerciseName)
                .font(.headline)
                .multilineTextAlignment(.center)

            Text("Set \(mirrorStore.snapshot.setIndex + 1)/\(mirrorStore.snapshot.setCount)")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Text("\(formatWeight(mirrorStore.snapshot.weightKg))kg")
                    .font(.title3.bold())
                Text("\(mirrorStore.snapshot.reps ?? 0)r")
                    .font(.title3.bold())
            }

            if let rest = mirrorStore.snapshot.restRemaining {
                Text("Rest \(rest)s")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            micButton

            Button("Done") {
                mirrorStore.send(command: .done, phrase: "done")
            }
            .buttonStyle(.borderedProminent)

            HStack {
                Button("Prev") {
                    mirrorStore.send(command: .previous, phrase: "previous")
                }
                .buttonStyle(.bordered)

                Button("Next") {
                    mirrorStore.send(command: .next, phrase: "next")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(8)
        .commandToast(mirrorStore.toast)
        .task {
            await speechService.requestPermissionsIfNeeded()
            speechService.onFinalTranscription = { phrase in
                mirrorStore.applyVoicePhrase(phrase)
            }
            mirrorStore.updateReachability()
        }
    }

    private var micButton: some View {
        ZStack {
            Circle()
                .fill(micPressing ? Color.red : Color.accentColor)
                .frame(width: 70, height: 70)
            Image(systemName: speechService.isRecording ? "waveform" : "mic.fill")
                .font(.title2)
                .foregroundStyle(.white)
        }
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !micPressing else { return }
                    micPressing = true
                    speechService.startSingleUtterance()
                }
                .onEnded { _ in
                    micPressing = false
                    speechService.stopListening()
                }
        )
    }

    private func formatWeight(_ value: Double?) -> String {
        guard let value else { return "-" }
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(value))"
        }
        return String(format: "%.1f", value)
    }
}
#endif
