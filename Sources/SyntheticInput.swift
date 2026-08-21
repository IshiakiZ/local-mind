import AppKit
import ApplicationServices
import CoreGraphics
import Carbon.HIToolbox
import Foundation

enum InputPermission {
    static var canPostEvents: Bool { CGPreflightPostEventAccess() }
    static var canListenEvents: Bool { CGPreflightListenEventAccess() }
    @discardableResult
    static func requestPostEventAccess() -> Bool { CGRequestPostEventAccess() }
    static func isAXTrusted(prompt: Bool) -> Bool {
        let opts = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }
    static func openAccessibilitySettings() {
        let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(u)
    }
}

enum ScreenGeom {
    static var flipHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }
    static func cocoaToCG(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: flipHeight - p.y) }
    static func cgToCocoa(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: flipHeight - p.y) }
    static var cursor: CGPoint { cocoaToCG(NSEvent.mouseLocation) }
}

enum SynthInput {
    private static func source() -> CGEventSource? { CGEventSource(stateID: .privateState) }

    public enum Button {
        case left, right
        var cg: CGMouseButton { self == .left ? .left : .right }
        var downType: CGEventType { self == .left ? .leftMouseDown : .rightMouseDown }
        var upType: CGEventType { self == .left ? .leftMouseUp : .rightMouseUp }
    }

    static func move(to point: CGPoint) {
        guard let e = CGEvent(mouseEventSource: source(), mouseType: .mouseMoved,
                              mouseCursorPosition: point, mouseButton: .left) else { return }
        e.flags = []
        e.post(tap: .cghidEventTap)
    }

    static func click(at point: CGPoint, button: Button = .left, clickCount: Int = 1) {
        let src = source()
        move(to: point)
        for n in 1...max(1, clickCount) {
            guard let d = CGEvent(mouseEventSource: src, mouseType: button.downType,
                                  mouseCursorPosition: point, mouseButton: button.cg),
                  let u = CGEvent(mouseEventSource: src, mouseType: button.upType,
                                  mouseCursorPosition: point, mouseButton: button.cg)
            else { return }
            d.flags = []; u.flags = []
            d.setIntegerValueField(.mouseEventClickState, value: Int64(n))
            u.setIntegerValueField(.mouseEventClickState, value: Int64(n))
            d.post(tap: .cghidEventTap)
            u.post(tap: .cghidEventTap)
        }
    }

    static func scroll(dy: Int32, dx: Int32 = 0) {
        guard let e = CGEvent(scrollWheelEvent2Source: source(), units: .pixel,
                              wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else { return }
        e.flags = []
        e.post(tap: .cghidEventTap)
    }

    static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43,
        "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
        "return": 36, "enter": 36, "tab": 48, "space": 49,
        "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121, "forwarddelete": 117,
        "command": 55, "shift": 56, "option": 58, "control": 59,
    ]

    static func key(_ code: CGKeyCode, flags: CGEventFlags = []) {
        let src = source()
        guard let d = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true),
              let u = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
        else { return }
        d.flags = flags; u.flags = flags
        d.post(tap: .cghidEventTap)
        u.post(tap: .cghidEventTap)
    }

    @discardableResult
    static func combo(_ spec: String) -> Bool {
        let parts = spec.lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "+" || $0 == " " })
            .map(String.init)
        guard let last = parts.last else { return false }
        var flags: CGEventFlags = []
        for m in parts.dropLast() {
            switch m {
            case "cmd", "command": flags.insert(.maskCommand)
            case "shift":          flags.insert(.maskShift)
            case "opt", "option", "alt": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            case "fn", "function":  flags.insert(.maskSecondaryFn)
            default: return false
            }
        }
        guard let code = keyCodes[last] else { return false }
        key(code, flags: flags)
        return true
    }

    static func type(_ text: String, perCharDelay: TimeInterval = 0.004) {
        let src = source()
        for ch in text {
            var u16 = Array(String(ch).utf16)
            guard let d = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
                  let u = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
            else { continue }
            d.flags = []; u.flags = []
            d.keyboardSetUnicodeString(stringLength: u16.count, unicodeString: &u16)
            u.keyboardSetUnicodeString(stringLength: u16.count, unicodeString: &u16)
            d.post(tap: .cghidEventTap)
            u.post(tap: .cghidEventTap)
            if perCharDelay > 0 { Thread.sleep(forTimeInterval: perCharDelay) }
        }
    }

    /// True when a password field anywhere on the system is swallowing key events.
    static var secureInputActive: Bool { IsSecureEventInputEnabled() }
}

enum AppControl {
    static func appURL(bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }
    static func appURL(named name: String) -> URL? {
        let dirs = ["/System/Applications", "/Applications",
                    "/System/Applications/Utilities", "/Applications/Utilities",
                    NSHomeDirectory() + "/Applications"]
        for dir in dirs {
            let u = URL(fileURLWithPath: dir).appendingPathComponent(name + ".app")
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }
    static func running(bundleID: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }
    static func frontmostBundleID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
    @discardableResult
    static func launchOrFocus(bundleID: String,
                              activates: Bool = true,
                              newInstance: Bool = false,
                              hidesOthers: Bool = false) async -> pid_t? {
        if !newInstance, let app = running(bundleID: bundleID) {
            _ = app.activate(options: activates ? [.activateAllWindows] : [])
            return app.processIdentifier
        }
        guard let url = appURL(bundleID: bundleID) else { return nil }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = activates
        cfg.createsNewApplicationInstance = newInstance
        cfg.hidesOthers = hidesOthers
        cfg.addsToRecentItems = false
        return await withCheckedContinuation { (k: CheckedContinuation<pid_t?, Never>) in
            NSWorkspace.shared.openApplication(at: url, configuration: cfg) { app, _ in
                k.resume(returning: app?.processIdentifier)
            }
        }
    }
    /// Bring an app to the front, launching it only if it isn't running.
    ///
    /// `NSWorkspace.OpenConfiguration.activates` is NOT sufficient on macOS 14+:
    /// the window server refuses activation requests from a process it doesn't
    /// consider to hold user attention, and it fails silently. The reliable path
    /// is to explicitly yield our own activation to the target first.
    @MainActor
    @discardableResult
    static func launchOrFocus(appURL url: URL, activates: Bool = true) async -> pid_t? {
        let bid = Bundle(url: url)?.bundleIdentifier
        if activates, let bid, let app = running(bundleID: bid), !app.isTerminated {
            NSApplication.shared.yieldActivation(to: app)
            // Give the window server a moment to register the yield.
            try? await Task.sleep(for: .milliseconds(40))
            var ok = app.activate(from: .current, options: [.activateAllWindows])
            if !ok { ok = app.activate(options: [.activateAllWindows]) }
            if ok { return app.processIdentifier }
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = activates
        cfg.addsToRecentItems = false
        return await withCheckedContinuation { (k: CheckedContinuation<pid_t?, Never>) in
            NSWorkspace.shared.openApplication(at: url, configuration: cfg) { app, _ in
                k.resume(returning: app?.processIdentifier)
            }
        }
    }
    static func revealInFinder(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}
