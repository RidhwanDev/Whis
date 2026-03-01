import SwiftData
import SwiftUI

@main
struct WhisApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [
            WorkoutSession.self,
            WorkoutExercise.self,
            WorkoutSet.self,
            ExerciseCatalogItem.self
        ])
    }
}
