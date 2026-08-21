import Foundation
import AppKit
import CoreGraphics
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

struct DisplayInfo: Sendable, Identifiable {
    var id: CGDirectDisplayID { displayID }
    var displayID: CGDirectDisplayID
    var width: Int
    var height: Int
    var frame: CGRect
}

struct WindowInfo: Sendable, Identifiable {
    var id: CGWindowID { windowID }
    var windowID: CGWindowID
    var title: String
    var appName: String
    var bundleID: String
    var pid: pid_t
    var frame: CGRect
    var layer: Int
    var onScreen: Bool
}

enum CaptureError: Error, LocalizedError {
    case notAuthorized, noDisplay, noWindow, encodeFailed
    var errorDescription: String? {
        switch self {
        case .notAuthorized: return "Screen Recording permission has not been granted."
        case .noDisplay:     return "No shareable display was found."
        case .noWindow:      return "That window is no longer available."
        case .encodeFailed:  return "Could not encode the image as PNG."
        }
    }
}

enum ScreenCapture {
    static var isAuthorized: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func requestAccess() -> Bool { CGRequestScreenCaptureAccess() }

    static func openPrivacySettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(u)
        }
    }

    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == SCStreamErrorDomain {
            switch ns.code {
            case -3801: return "Screen Recording permission was declined. Enable Local Mind under Privacy & Security › Screen Recording."
            case -3802: return "Screen capture failed to start."
            case -3803: return "Screen capture is missing required entitlements."
            case -3813, -3814, -3815: return "There was nothing available to capture."
            default: return "Screen capture failed (\(ns.code))."
            }
        }
        return error.localizedDescription
    }

    nonisolated static func shareableContent(onScreenOnly: Bool = true)
        async throws -> (displays: [DisplayInfo], windows: [WindowInfo])
    {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: onScreenOnly)
        let displays = content.displays.map {
            DisplayInfo(displayID: $0.displayID, width: $0.width, height: $0.height, frame: $0.frame)
        }
        let windows = content.windows.map { w in
            WindowInfo(windowID: w.windowID,
                       title: w.title ?? "",
                       appName: w.owningApplication?.applicationName ?? "",
                       bundleID: w.owningApplication?.bundleIdentifier ?? "",
                       pid: w.owningApplication?.processID ?? 0,
                       frame: w.frame,
                       layer: w.windowLayer,
                       onScreen: w.isOnScreen)
        }
        return (displays, windows)
    }

    nonisolated static func appWindows() async throws -> [WindowInfo] {
        let (_, all) = try await shareableContent()
        return all.filter {
            $0.layer == 0 && $0.onScreen &&
            $0.frame.width > 120 && $0.frame.height > 120 && !$0.appName.isEmpty
        }
    }

    nonisolated static func windowListFallback() -> [WindowInfo] {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return raw.map { d in
            var rect = CGRect.zero
            if let b = d[kCGWindowBounds as String] {
                rect = CGRect(dictionaryRepresentation: b as! CFDictionary) ?? .zero
            }
            return WindowInfo(
                windowID: d[kCGWindowNumber as String] as? CGWindowID ?? 0,
                title: d[kCGWindowName as String] as? String ?? "",
                appName: d[kCGWindowOwnerName as String] as? String ?? "",
                bundleID: "",
                pid: d[kCGWindowOwnerPID as String] as? pid_t ?? 0,
                frame: rect,
                layer: d[kCGWindowLayer as String] as? Int ?? 0,
                onScreen: (d[kCGWindowIsOnscreen as String] as? Bool) ?? false)
        }
    }

    nonisolated static func activeDisplays() -> [DisplayInfo] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map {
            let b = CGDisplayBounds($0)
            return DisplayInfo(displayID: $0, width: Int(b.width), height: Int(b.height), frame: b)
        }
    }

    nonisolated static func captureDisplay(_ displayID: CGDirectDisplayID? = nil,
                                           scale: CGFloat = 1.0,
                                           showsCursor: Bool = false) async throws -> CGImage {
        guard isAuthorized else { throw CaptureError.notAuthorized }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let d = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
            throw CaptureError.noDisplay
        }
        let filter = SCContentFilter(display: d, excludingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.width  = Int((CGFloat(d.width)  * scale).rounded())
        cfg.height = Int((CGFloat(d.height) * scale).rounded())
        cfg.showsCursor = showsCursor
        cfg.captureResolution = .best
        cfg.scalesToFit = true
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    }

    nonisolated static func captureWindow(_ windowID: CGWindowID,
                                          scale: CGFloat = 2.0) async throws -> CGImage {
        guard isAuthorized else { throw CaptureError.notAuthorized }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let w = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.noWindow
        }
        let filter = SCContentFilter(desktopIndependentWindow: w)
        let cfg = SCStreamConfiguration()
        cfg.width  = Int((w.frame.width  * scale).rounded())
        cfg.height = Int((w.frame.height * scale).rounded())
        cfg.showsCursor = false
        cfg.captureResolution = .best
        cfg.scalesToFit = true
        cfg.ignoreShadowsSingleWindow = true
        cfg.includeChildWindows = true
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    }

    nonisolated static func captureRect(_ rect: CGRect) async throws -> CGImage {
        guard isAuthorized else { throw CaptureError.notAuthorized }
        return try await SCScreenshotManager.captureImage(in: rect)
    }

    nonisolated static func pngData(_ image: CGImage) throws -> Data {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            throw CaptureError.encodeFailed
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CaptureError.encodeFailed }
        return out as Data
    }

    nonisolated static func nsImage(_ image: CGImage, pointScale: CGFloat = 2.0) -> NSImage {
        NSImage(cgImage: image,
                size: NSSize(width: CGFloat(image.width) / pointScale,
                             height: CGFloat(image.height) / pointScale))
    }
}
