import SwiftUI

@main
struct ToDoApp: App {
    var body: some Scene {
        WindowGroup("To-Do") {
            ContentView()
        }
        .defaultSize(width: 460, height: 520)
        .windowResizability(.contentMinSize)
    }
}
