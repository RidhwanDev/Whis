import SwiftUI

struct SettingsView: View {
    @AppStorage("settings.weightIncrement") private var weightIncrement = 2.5
    @AppStorage("settings.defaultRest") private var defaultRest = 90
    @AppStorage("settings.healthKitExport") private var healthKitExport = false
    @AppStorage("settings.alwaysListening") private var alwaysListening = true
    @AppStorage("settings.wakeWord") private var wakeWord = "Lift"
    @AppStorage("settings.voiceFeedbackEnabled") private var voiceFeedbackEnabled = false
    @AppStorage("settings.voiceIdentifier") private var voiceIdentifier = ""

#if os(iOS)
    private var voiceOptions: [SpeechFeedbackService.VoiceOption] {
        SpeechFeedbackService.shared.availableVoices()
    }
#endif

    var body: some View {
        NavigationStack {
            Form {
                Section("Weight Increment") {
                    Picker("Increment", selection: $weightIncrement) {
                        Text("1.0 kg").tag(1.0)
                        Text("2.5 kg").tag(2.5)
                        Text("5.0 kg").tag(5.0)
                    }
                    .pickerStyle(.segmented)
                }

                Section("Default Rest") {
                    Stepper("\(defaultRest) seconds", value: $defaultRest, in: 15...300, step: 15)
                }
                
                Section("Voice Control") {
                    Toggle("Always Listen", isOn: $alwaysListening)
                    Text("When enabled, say your wake word before your command instead of holding to talk.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Picker("Wake Word", selection: $wakeWord) {
                        Text("Lift").tag("Lift")
                        Text("Whis").tag("Whis")
                        Text("Logger").tag("Logger")
                        Text("Ready").tag("Ready")
                    }
                }
                
                Section("Voice Feedback") {
                    Toggle("Speak Confirmations", isOn: $voiceFeedbackEnabled)
                    
#if os(iOS)
                    if voiceFeedbackEnabled {
                        Picker("Voice", selection: $voiceIdentifier) {
                            Text("System Default").tag("")
                            ForEach(voiceOptions) { option in
                                Text(option.displayName).tag(option.identifier)
                            }
                        }
                    }
#endif
                }

                Section("HealthKit Export") {
                    Toggle("Coming Soon", isOn: $healthKitExport)
                        .disabled(true)
                }
            }
            .navigationTitle("Settings")
        }
    }
}
