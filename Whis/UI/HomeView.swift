import SwiftData
import SwiftUI

struct HomeView: View {
    @ObservedObject var store: WorkoutStore
    @Query(sort: [SortDescriptor(\WorkoutSession.startedAt, order: .reverse)]) private var sessions: [WorkoutSession]

    var recentSessions: [WorkoutSession] {
        sessions.filter { $0.endedAt != nil }.prefix(5).map { $0 }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        store.startWorkout()
                    } label: {
                        Label("Start Workout", systemImage: "figure.strengthtraining.traditional")
                            .font(.headline)
                    }
                    .buttonStyle(.borderedProminent)
                }

                Section("Recent Sessions") {
                    if recentSessions.isEmpty {
                        Text("No completed sessions yet")
                            .foregroundStyle(.secondary)
                    }

                    ForEach(recentSessions, id: \.id) { session in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.startedAt, style: .date)
                                .font(.headline)
                            Text("\(session.exercises.count) exercises")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Hands-Free Lift")
        }
    }
}
