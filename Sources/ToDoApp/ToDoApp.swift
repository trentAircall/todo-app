import SwiftUI
import AppKit

/// Without this, SwiftUI's default lifecycle quits the whole app (menu bar
/// item included) as soon as the main window closes — which would defeat
/// the point of a menu bar glance you can leave running all day.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A menu-bar-only utility with no window open looks idle to macOS's
        // automatic-termination bookkeeping, which silently quits apps like
        // that after a few seconds — exactly the state this app sits in
        // most of the day. Opt out so the menu bar glance actually persists.
        ProcessInfo.processInfo.disableAutomaticTermination("Menu bar glance stays running with no main window open")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct ToDoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = TaskStore()

    var body: some Scene {
        // `Window`, not `WindowGroup` — exactly one main window. Otherwise
        // clicking "Open To-Do" from the menu bar while a window already
        // exists spawns a second one instead of refocusing the first.
        Window("To-Do", id: "main") {
            ContentView(store: store)
        }
        .defaultSize(width: 460, height: 520)
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MenuBarView(store: store)
        } label: {
            Image(systemName: "checklist")
        }
        .menuBarExtraStyle(.window)
    }
}
