import SwiftUI

struct SessionSummaryView: View {
    @ObservedObject var store: WorkoutStore

    var body: some View {
        NavigationStack {
            List {
                if let session = store.currentSession {
                    ForEach(session.exercises.sorted { $0.name < $1.name }, id: \.id) { exercise in
                        Section(exercise.name) {
                            ForEach(exercise.sets.sorted { $0.index < $1.index }, id: \.id) { set in
                                HStack {
                                    Text("Set \(set.index + 1)")
                                    Spacer()
                                    Text(summaryText(for: set))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Session Summary")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Discard", role: .destructive) {
                        store.discardWorkout()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.saveWorkout()
                    }
                }
            }
        }
    }

    private func summaryText(for set: WorkoutSet) -> String {
        let reps = set.reps.map(String.init) ?? "-"
        let weight: String
        if let value = set.weightKg {
            weight = value.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(value))" : String(format: "%.1f", value)
        } else {
            weight = "-"
        }
        return "\(reps) reps @ \(weight) kg"
    }
}
