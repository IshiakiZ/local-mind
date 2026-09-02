import SwiftUI
import AppKit

@main
struct LocalMindApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup("Local Mind") {
            ContentView()
                .frame(minWidth: 680, minHeight: 520)
        }
        .defaultSize(width: 880, height: 700)
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
