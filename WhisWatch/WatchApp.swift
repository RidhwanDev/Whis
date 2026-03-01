#if os(watchOS)
import SwiftUI

@main
struct WhisWatchApp: App {
    var body: some Scene {
        WindowGroup {
            WatchWorkoutView()
        }
    }
}
#endif
