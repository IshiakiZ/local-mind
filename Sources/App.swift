import SwiftUI
import AppKit

/// Menu commands live in the menu bar so their shortcuts are discoverable
/// rather than secret. They reach the view through notifications, because the
/// Brain instance belongs to ContentView.
extension Notification.Name {
    static let lmNewChat      = Notification.Name("lm.newChat")
    static let lmOpen         = Notification.Name("lm.open")
    static let lmSave         = Notification.Name("lm.save")
    static let lmFocusInput   = Notification.Name("lm.focusInput")
    static let lmCheckUpdates = Notification.Name("lm.checkUpdates")
    static let lmStop         = Notification.Name("lm.stop")
    static let lmAttach       = Notification.Name("lm.attach")
}

@main
struct LocalMindApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup("Local Mind") {
            ContentView()
                .frame(minWidth: 680, minHeight: 520)
        }
        .defaultSize(width: 880, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Conversation") { post(.lmNewChat) }
                    .keyboardShortcut("n", modifiers: .command)
                Divider()
                Button("Open Conversation…") { post(.lmOpen) }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Save Conversation…") { post(.lmSave) }
                    .keyboardShortcut("s", modifiers: .command)
                Divider()
                Button("Attach Image…") { post(.lmAttach) }
                    .keyboardShortcut("i", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button("Focus Message Box") { post(.lmFocusInput) }
                    .keyboardShortcut("l", modifiers: .command)
                Button("Stop Generating") { post(.lmStop) }
                    .keyboardShortcut(".", modifiers: .command)
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { post(.lmCheckUpdates) }
            }
        }
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
    }
}

/// Zero-size AppKit hook. With `.hiddenTitleBar` there is no title bar left to
/// drag, so the window is made movable by its background instead.
/// NOTE: never set `window.backgroundColor = .clear` here — combined with the
/// behind-window vibrancy the window renders black.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            w.isMovableByWindowBackground = true
            // Remember size and position between launches.
            w.setFrameAutosaveName("LocalMindMain")
        }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {}
}

@MainActor private func post(_ n: Notification.Name) {
    NotificationCenter.default.post(name: n, object: nil)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    /// Give the memory back on the way out. Ollama otherwise keeps the model
    /// resident for minutes after the app is gone, which matters a lot on a
    /// 16 GB machine.
    func applicationWillTerminate(_ note: Notification) {
        Ollama.unloadBlocking()
    }
}
