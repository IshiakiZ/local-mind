import SwiftUI

// Probe of the confirmation card + permission banner, to prove the shapes
// compile under strict concurrency next to the real sources.

struct ConfirmCard: View {
    let action: PendingAction
    let onRun: () -> Void
    let onCancel: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: action.glyph)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(action.verb)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(T.label)
                Spacer(minLength: 8)
                Text(action.risk.word)
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(T.label2)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(action.target)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(T.label2)
                    .textSelection(.enabled)
                Text(action.consequence)
                    .font(.system(size: 11.5))
                    .foregroundStyle(T.label2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Two glass buttons sitting side by side, so they share one
            // container rather than each blurring the other.
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Button("Cancel", action: onCancel)
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .keyboardShortcut(.escape, modifiers: [])
                    Button(action.verb, action: onRun)
                        .buttonStyle(.glassProminent)
                        .tint(Color.accentColor)
                        .controlSize(.small)
                    Spacer()
                }
            }
        }
        .padding(13)
        .frame(maxWidth: 520, alignment: .leading)
        // This card is asking permission to touch something outside the app.
        // It should read as the nearest, most present object on screen —
        // accent-tinted glass, lifted well off the page.
        .glassEffect(.regular.tint(Color.accentColor.opacity(0.22)),
                     in: RoundedRectangle(cornerRadius: R.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: R.card, style: .continuous)
            .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1))
        .shadow(color: T.castHard, radius: 18, y: 7)
        .padding(.leading, S.gutter)
    }
}

struct PermissionBanner: View {
    let perms: ScreenPermissions
    let needsCapture: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Local Mind needs permission to read your screen")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(T.label)
            if !perms.accessibility {
                row("Accessibility", granted: false, why: "to read window contents and press controls") {
                    AX.requestTrust(); AX.openAccessibilitySettings()
                }
            }
            if needsCapture && !perms.screenRecording {
                row("Screen Recording", granted: false, why: "to read text that apps don't expose") {
                    ScreenCapture.requestAccess(); ScreenCapture.openPrivacySettings()
                }
            }
            Text("After granting, quit and reopen Local Mind.")
                .font(.system(size: 11)).foregroundStyle(T.label2)
        }
        .padding(12)
        .frame(maxWidth: 520, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: R.card, style: .continuous).fill(T.sunken))
        .overlay(RoundedRectangle(cornerRadius: R.card, style: .continuous)
            .strokeBorder(T.hair, lineWidth: 0.5))
        .padding(.leading, S.gutter)
    }

    private func row(_ name: String, granted: Bool, why: String, open: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Circle().fill(granted ? T.ready : T.down).frame(width: 5, height: 5)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 12, weight: .medium)).foregroundStyle(T.label)
                Text(why).font(.system(size: 11)).foregroundStyle(T.label2)
            }
            Spacer(minLength: 8)
            Button("Grant…", action: open).buttonStyle(.bordered).controlSize(.small)
        }
    }
}
