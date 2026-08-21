import Foundation
import ApplicationServices
import AppKit

struct AXNode: Sendable {
    var role: String
    var subrole: String?
    var title: String?
    var value: String?
    var label: String?
    var enabled: Bool
    var position: CGPoint?
    var size: CGSize?
    var actions: [String]
    var path: [Int]
    var depth: Int

    var frame: CGRect? {
        guard let p = position, let s = size else { return nil }
        return CGRect(origin: p, size: s)
    }
    /// Best human-readable name, per the recon's fallback order.
    var bestLabel: String {
        for c in [title, label, value] {
            if let c, !c.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return c }
        }
        return ""
    }
    var isSecure: Bool { subrole == "AXSecureTextField" }
}

@MainActor
enum AX {
    static let promptKey = "AXTrustedCheckOptionPrompt"
    static var isTrusted: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func requestTrust() -> Bool {
        AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    }
    static func checkTrustNoPrompt() -> Bool {
        AXIsProcessTrustedWithOptions([promptKey: false] as CFDictionary)
    }
    static func openAccessibilitySettings() {
        let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(u)
    }

    struct FrontApp: Sendable {
        var pid: pid_t
        var name: String
        var bundleID: String?
    }

    static func frontmostApp() -> FrontApp? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return FrontApp(pid: app.processIdentifier,
                        name: app.localizedName ?? "?",
                        bundleID: app.bundleIdentifier)
    }

    static func appElement(pid: pid_t) -> AXUIElement {
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(el, 2.0)
        return el
    }

    static var systemWide: AXUIElement { AXUIElementCreateSystemWide() }

    static func copyAttr(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var out: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(el, attr as CFString, &out)
        return err == .success ? out : nil
    }
    static func string(_ el: AXUIElement, _ attr: String) -> String? {
        guard let v = copyAttr(el, attr) else { return nil }
        if CFGetTypeID(v) == CFStringGetTypeID() { return (v as! CFString) as String }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }
    static func bool(_ el: AXUIElement, _ attr: String) -> Bool? {
        guard let v = copyAttr(el, attr) else { return nil }
        guard CFGetTypeID(v) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue((v as! CFBoolean))
    }
    static func point(_ el: AXUIElement, _ attr: String = kAXPositionAttribute) -> CGPoint? {
        guard let v = copyAttr(el, attr), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        let box = v as! AXValue
        guard AXValueGetType(box) == .cgPoint else { return nil }
        var p = CGPoint.zero
        guard AXValueGetValue(box, .cgPoint, &p) else { return nil }
        return p
    }
    static func size(_ el: AXUIElement, _ attr: String = kAXSizeAttribute) -> CGSize? {
        guard let v = copyAttr(el, attr), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        let box = v as! AXValue
        guard AXValueGetType(box) == .cgSize else { return nil }
        var s = CGSize.zero
        guard AXValueGetValue(box, .cgSize, &s) else { return nil }
        return s
    }
    static func children(_ el: AXUIElement) -> [AXUIElement] {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &out) == .success,
              let arr = out as? [AXUIElement] else { return [] }
        return arr
    }
    static func actionNames(_ el: AXUIElement) -> [String] {
        var out: CFArray?
        guard AXUIElementCopyActionNames(el, &out) == .success,
              let arr = out as? [String] else { return [] }
        return arr
    }
    static func focusedWindow(pid: pid_t) -> AXUIElement? {
        var out: CFTypeRef?
        let app = appElement(pid: pid)
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &out) == .success,
              let v = out, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }
    static func windowTitle(pid: pid_t) -> String? {
        guard let w = focusedWindow(pid: pid) else { return nil }
        return string(w, kAXTitleAttribute)
    }

    static func snapshot(_ el: AXUIElement, path: [Int], depth: Int) -> AXNode {
        AXNode(role: string(el, kAXRoleAttribute) ?? "AXUnknown",
               subrole: string(el, kAXSubroleAttribute),
               title: string(el, kAXTitleAttribute),
               value: string(el, kAXValueAttribute),
               label: string(el, kAXDescriptionAttribute),
               enabled: bool(el, kAXEnabledAttribute) ?? true,
               position: point(el),
               size: size(el),
               actions: actionNames(el),
               path: path,
               depth: depth)
    }

    static let interesting: Set<String> = [
        kAXButtonRole, kAXTextFieldRole, kAXTextAreaRole, kAXMenuItemRole,
        kAXMenuButtonRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXPopUpButtonRole,
        "AXLink", kAXComboBoxRole, kAXSliderRole, kAXTabGroupRole,
    ]
    /// Roles that carry readable prose — used for the "what does this say" path.
    static let textual: Set<String> = [
        kAXStaticTextRole, kAXTextAreaRole, kAXTextFieldRole, "AXHeading",
    ]

    static func walk(_ root: AXUIElement,
                     maxDepth: Int = 12,
                     maxNodes: Int = 4000,
                     onlyInteresting: Bool = false) -> [AXNode] {
        var found: [AXNode] = []
        var visited = 0
        func rec(_ el: AXUIElement, _ path: [Int], _ depth: Int) {
            if depth > maxDepth || visited >= maxNodes { return }
            visited += 1
            let node = snapshot(el, path: path, depth: depth)
            if !onlyInteresting || interesting.contains(node.role) { found.append(node) }
            for (i, kid) in children(el).enumerated() {
                if visited >= maxNodes { return }
                rec(kid, path + [i], depth + 1)
            }
        }
        rec(root, [], 0)
        return found
    }

    static func resolve(_ path: [Int], from root: AXUIElement) -> AXUIElement? {
        var cur = root
        for i in path {
            let kids = children(cur)
            guard i < kids.count else { return nil }
            cur = kids[i]
        }
        return cur
    }

    @discardableResult
    static func press(_ el: AXUIElement) -> AXError {
        AXUIElementPerformAction(el, kAXPressAction as CFString)
    }

    @discardableResult
    static func press(path: [Int], inWindowOf pid: pid_t) -> AXError {
        guard let win = focusedWindow(pid: pid),
              let el = resolve(path, from: win) else { return .invalidUIElement }
        guard actionNames(el).contains(kAXPressAction) else { return .actionUnsupported }
        return press(el)
    }

    static func setValue(_ el: AXUIElement, _ text: String) -> AXError {
        AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, text as CFString)
    }
    static func focus(_ el: AXUIElement) -> AXError {
        AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }
}
