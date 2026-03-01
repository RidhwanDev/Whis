import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var store = WorkoutStore()

    var body: some View {
        Group {
            if store.currentSession == nil {
                TabView {
                    HomeView(store: store)
                        .tabItem {
                            Label("Home", systemImage: "house")
                        }

                    SettingsView()
                        .tabItem {
                            Label("Settings", systemImage: "gearshape")
                        }
                }
            } else {
                WorkoutLiveView(store: store)
            }
        }
        .onAppear {
            store.configure(context: modelContext)
        }
    }
}

#Preview {
    ContentView()
}
