import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Reduce Motion helpers
//
// Every animation that carries positional travel collapses to a plain
// crossfade of the SAME duration when Reduce Motion is on, so timing-dependent
// feedback survives while the movement does not.

func calmed(_ a: Animation, _ reduce: Bool, _ seconds: Double) -> Animation {
    reduce ? .easeOut(duration: seconds) : a
}

// MARK: - ContentView

struct ContentView: View {
    @StateObject private var brain = Brain()
    @StateObject private var accentWatch = AccentWatch()

    @State private var draft = ""
    @State private var isTargeted = false
    @State private var scrolled = false
    @State private var atBottom = true
    @State private var spin = 0.0
    @FocusState private var inputFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let suggestions: [Suggestion] = [
        Suggestion(text: "Summarize this: the council voted 7-2 to rezone Fifth Street, allowing six-story buildings."),
        Suggestion(text: "I leave at 7:45 AM, drive 1h40m, and stop 20 minutes. What time do I arrive?"),
        Suggestion(text: "Write a Python function that returns the second largest number in a list.")
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Both chrome bars sit ABOVE the page in z, so their cast shadows
            // and their glass land ON the transcript instead of under it.
            header.zIndex(2)
            transcript.zIndex(0)
            attachmentChip
            inputBar.zIndex(2)
        }
        .background(Backdrop())
        .background(WindowBackground())
        .background(WindowConfigurator().frame(width: 0, height: 0))
        .dropDestination(for: URL.self) { urls, _ in
            guard let u = urls.first else { return false }
            brain.ingest(u)
            return true
        } isTargeted: { isTargeted = $0 }
        .overlay { if isTargeted { dropOverlay } }
        .animation(calmed(M.drop, reduceMotion, 0.30), value: isTargeted)
        // With `.hiddenTitleBar` the window still hands SwiftUI a ~34pt top
        // safe area. Left alone, the header lands BELOW the traffic lights and
        // the vibrancy stops short of the title bar, which shows as a tonal
        // band across the top of the window. Taking the top edge puts the
        // traffic lights inside the 52pt header, which is what the 78pt
        // leading inset exists to clear. VERIFIED on screen.
        .ignoresSafeArea(.container, edges: .top)
        .onAppear {
            inputFocused = true
            installPasteMonitor()
        }
        .onDisappear {
            if let m = pasteMonitor { NSEvent.removeMonitor(m); pasteMonitor = nil }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Local Mind")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(T.label)
                ModelStatusStrip(appleReady: brain.modelReady, qwenReady: brain.qwenReady)
            }

            Spacer()

            OfflinePill()

            HStack(spacing: 2) {
                Button {
                    brain.councilEnabled.toggle()
                } label: {
                    Image(systemName: brain.councilEnabled ? "person.3.fill" : "person.fill")
                }
                .buttonStyle(IconButtonStyle(active: brain.councilEnabled))
                .help(brain.councilEnabled
                      ? "Council on — the best model is chosen per question"
                      : "Council off — Apple's on-device model answers everything")

                Button {
                    brain.speakReplies.toggle()
                    if !brain.speakReplies { brain.stopSpeaking() }
                } label: {
                    Image(systemName: "speaker.wave.2.fill")
                }
                .buttonStyle(IconButtonStyle(active: brain.speakReplies))
                .help("Read replies aloud")

                // Reopen a conversation this app saved earlier.
                Button {
                    if let result = ChatArchive.presentOpenPanel() {
                        if !result.messages.isEmpty { brain.load(result.messages) }
                        brain.messages.append(Msg(role: .note, text: result.status))
                    }
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(IconButtonStyle(active: false))
                .help("Open a conversation you saved earlier")

                // Saving is OPT-IN. This button is the ONLY thing in the app
                // that writes to disk, and it writes only where the user
                // points it. Disabled rather than hidden, so an empty
                // transcript still teaches that the control exists.
                Button {
                    if let status = ChatArchive.presentSavePanel(for: brain.messages) {
                        brain.messages.append(Msg(role: .note, text: status))
                    }
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .buttonStyle(IconButtonStyle())
                .disabled(!canSave)
                .help(canSave
                      ? "Save this conversation as Markdown — only this conversation, and only where you choose. Nothing is ever saved automatically."
                      : "Nothing to save yet. Local Mind never saves a conversation on its own — this button is the only thing that writes to disk.")
            }

            Spacer().frame(width: 6)

            Button {
                if !reduceMotion { withAnimation(M.verdict) { spin -= 360 } }
                brain.stopSpeaking()
                brain.reset()
                draft = ""
                inputFocused = true
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .rotationEffect(.degrees(spin))
            }
            .buttonStyle(IconButtonStyle())
            .help("New conversation")
        }
        .padding(.leading, S.trafficInset)
        .padding(.trailing, 14)
        .frame(height: S.headerHeight)
        .frame(maxWidth: .infinity)
        // Native Liquid Glass, full-bleed so the traffic lights sit inside it.
        .glassEffect(.regular, in: Rectangle())
        .overlay(alignment: .top) {
            Rectangle().fill(T.lip).frame(height: 1)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(T.hair)
                .frame(height: 1)
                .opacity(scrolled ? 1 : 0.55)
        }
        .shadow(color: T.castHard, radius: scrolled ? 14 : 7, y: scrolled ? 5 : 2)
        .animation(M.hairline, value: scrolled)
    }

    @State private var pasteMonitor: Any? = nil

    /// SwiftUI's `.onPasteCommand` never fires while the text field holds focus —
    /// the field consumes ⌘V first. Intercepting the key event is the only
    /// reliable route. Text paste is left completely alone: the event is only
    /// swallowed when the clipboard genuinely contains a picture.
    private func installPasteMonitor() {
        guard pasteMonitor == nil else { return }
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard mods == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "v"
            else { return event }
            // Keep NSEvent out of the isolation boundary — it isn't Sendable.
            var handled = false
            MainActor.assumeIsolated { handled = pasteImageFromClipboard() }
            return handled ? nil : event
        }
    }

    /// ⌘V with a picture on the clipboard. Text paste is untouched: this only
    /// fires for image/file types, so the text field still handles plain text.
    @discardableResult
    private func pasteImageFromClipboard() -> Bool {
        let pb = NSPasteboard.general
        // Plain text on the clipboard must fall through to the text field.
        if pb.canReadObject(forClasses: [NSString.self], options: nil),
           !pb.canReadObject(forClasses: [NSImage.self], options: nil) { return false }
        if let imgs = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let img = imgs.first {
            brain.ingest(image: img, label: "pasted image")
            return true
        }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let u = urls.first {
            brain.ingest(u)
            return true
        }
        return false
    }

    private var canSave: Bool { ChatArchive.hasContent(brain.messages) }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: S.rowSpacing) {
                    ForEach(Array(brain.messages.enumerated()), id: \.element.id) { i, m in
                        MessageRow(msg: m,
                                   accentTick: accentWatch.tick,
                                   isStreaming: isStreaming(i),
                                   onRun: { brain.runConfirmed($0) },
                                   onCancel: { brain.cancelConfirmed($0) })
                            .id(m.id)
                            .padding(.top, pairsWithPrevious(i) ? S.pairSpacing - S.rowSpacing : 0)
                            .transition(reduceMotion
                                        ? .opacity
                                        : .asymmetric(insertion: .offset(y: 8).combined(with: .opacity),
                                                      removal: .opacity))
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .animation(calmed(M.rise, reduceMotion, 0.34), value: brain.messages.count)
                .frame(maxWidth: S.measure, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, S.transcriptH)
                .padding(.vertical, S.transcriptV)
            }
            // TOP anchor, not bottom. Bottom-anchoring pinned a two-line
            // conversation to the composer and left ~500pt of empty grey
            // hanging above it, which read as a broken layout. Anchored to
            // the top, a short conversation starts under the header where
            // reading starts, and the leftover room falls at the bottom
            // where it reads as breathing space above the composer.
            // Long conversations still end up at the bottom, because both
            // onChange handlers below scroll there whenever content arrives.
            .defaultScrollAnchor(.top)
            .scrollBounceBehavior(.basedOnSize)
            .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y > 4 } action: { _, v in
                withAnimation(M.hairline) { scrolled = v }
            }
            .onScrollGeometryChange(for: Bool.self) {
                $0.contentOffset.y >= $0.contentSize.height - $0.containerSize.height - 24
            } action: { _, v in
                atBottom = v
            }
            .onChange(of: brain.messages.last?.text) { _, _ in
                guard atBottom else { return }
                withAnimation(M.scroll) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: brain.messages.count) { _, _ in
                withAnimation(M.scroll) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .overlay {
                // Vertically centred rather than top-pinned: pinned to the top
                // it leaves a dead ~300pt gap above the composer.
                ZStack {
                    if brain.messages.isEmpty {
                        WelcomeCard(suggestions: suggestions) { brain.send($0) }
                            .frame(maxWidth: S.measure, alignment: .leading)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                            .padding(.horizontal, S.transcriptH)
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.20), value: brain.messages.isEmpty)
            }
            // The page. Recessed below the chrome so the window reads as
            // three planes — glass chrome, sunken page, raised content —
            // instead of one flat sheet of grey.
            .background {
                LinearGradient(colors: [T.canvasTop, T.canvasBot],
                               startPoint: .top, endPoint: .bottom)
            }
            // Inner shadow: the chrome above and below casts onto the page,
            // so content reads as sliding underneath it rather than stopping.
            .overlay(alignment: .top) {
                LinearGradient(colors: [T.inset, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: S.edgeFade)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.clear, T.inset], startPoint: .top, endPoint: .bottom)
                    .frame(height: S.edgeFade)
                    .allowsHitTesting(false)
            }
            // Applied last so it floats above the page and its inner shadows.
            .overlay(alignment: .bottom) {
                if !atBottom {
                    Button {
                        withAnimation(M.scroll) { proxy.scrollTo("bottom", anchor: .bottom) }
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 15, height: 15)
                    }
                    .buttonStyle(.glass)
                    .tint(Color.accentColor)
                    .shadow(color: T.castHard, radius: 12, y: 4)
                    .padding(.bottom, 18)
                    .help("Jump to the latest message")
                    .transition(reduceMotion
                                ? .opacity
                                : .scale(scale: 0.8).combined(with: .opacity))
                }
            }
            .animation(calmed(M.jump, reduceMotion, 0.30), value: atBottom)
        }
    }

    /// True when this row is an assistant reply directly caused by the user
    /// message above it — the pair then tightens from 18pt to 12pt.
    private func pairsWithPrevious(_ i: Int) -> Bool {
        guard i > 0 else { return false }
        return brain.messages[i - 1].role == .user && brain.messages[i].role == .assistant
    }

    private func isStreaming(_ i: Int) -> Bool {
        brain.isThinking
        && i == brain.messages.count - 1
        && brain.messages[i].role == .assistant
    }

    // MARK: Input

    private func attachmentSubtitle(_ att: Attachment) -> String {
        if att.hasText { return "text read — ask a question, or send to summarise" }
        if att.visionLabels.isEmpty { return "no text found" }
        let top = att.visionLabels.prefix(3).joined(separator: ", ")
        return "identified: " + top
    }

    @ViewBuilder
    private var attachmentChip: some View {
        if let att = brain.attachment {
            HStack(spacing: 9) {
                Image(decorative: att.image, scale: 1)
                    .resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(att.label)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(T.label)
                        .lineLimit(1)
                    Text(attachmentSubtitle(att))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(T.label2)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Button { brain.clearAttachment() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(T.label2)
                }
                .buttonStyle(.plain)
                .help("Remove this image")
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: R.chip, style: .continuous))
            .frame(maxWidth: S.measure)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, S.inputH)
            .padding(.bottom, 6)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var inputBar: some View {
        // One GlassEffectContainer so the three glass pieces sample the same
        // backdrop and MERGE at the edges instead of stacking translucency
        // on top of each other, which is what makes multiple glass elements
        // go milky.
        GlassEffectContainer(spacing: 12) {
            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    let p = NSOpenPanel()
                    p.allowedContentTypes = [.image]
                    p.allowsMultipleSelection = false
                    if p.runModal() == .OK, let u = p.url { brain.ingest(u) }
                } label: {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 17, height: 17)
                }
                .buttonStyle(.glass)
                .help("Read text from an image")

                TextField("Ask anything — it never leaves this Mac", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineSpacing(2.5)
                    .foregroundStyle(T.label)
                    .lineLimit(1...6)
                    .focused($inputFocused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .glassEffect(.regular.interactive(),
                                 in: RoundedRectangle(cornerRadius: R.field, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: R.field, style: .continuous)
                        .strokeBorder(inputFocused ? Color.accentColor.opacity(0.70) : Color.clear,
                                      lineWidth: 1.5))
                    .animation(M.focus, value: inputFocused)
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) { return .ignored }
                        submit()
                        return .handled
                    }

                // While a reply is being written this becomes a stop button —
                // otherwise a long answer holds the whole app hostage.
                Button(action: { brain.isThinking ? brain.stop() : submit() }) {
                    Image(systemName: brain.isThinking ? "stop.fill" : "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .contentTransition(.symbolEffect(.replace.downUp))
                        .frame(width: 17, height: 17)
                }
                .buttonStyle(.glassProminent)
                .tint(brain.isThinking ? Color.secondary : Color.accentColor)
                .disabled(!brain.isThinking && !canSend)
                .animation(M.send, value: canSend)
                .animation(M.send, value: brain.isThinking)
                .id(accentWatch.tick)
                .keyboardShortcut(brain.isThinking ? .escape : .end, modifiers: [])
                .help(brain.isThinking ? "Stop generating (Esc)" : "Send")
            }
            .frame(maxWidth: S.measure)
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, S.inputH)
        .padding(.vertical, S.inputV + 2)
        .frame(maxWidth: .infinity)
        .background {
            // Chrome plate, tonally ABOVE the page it sits on.
            Rectangle().fill(T.chrome)
        }
        .overlay(alignment: .top) {
            Rectangle().fill(T.lip).frame(height: 1)
        }
        .shadow(color: T.castHard, radius: 16, y: -5)
    }

    private var canSend: Bool {
        guard !brain.isThinking else { return false }
        if brain.attachment != nil { return true }   // send with no question = summarise
        return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        guard canSend else { return }
        brain.send(draft)
        draft = ""
        inputFocused = true
    }

    // MARK: Drop overlay

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: R.drop, style: .continuous)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
            .background(
                RoundedRectangle(cornerRadius: R.drop, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: R.drop, style: .continuous)
                        .fill(Color.accentColor.opacity(0.08)))
            )
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: "text.viewfinder").font(.system(size: 30))
                    Text("Drop an image to read its text")
                        .font(.system(size: 13, weight: .medium))
                    Text("Vision reads it on-device")
                        .font(.system(size: 11))
                        .foregroundStyle(T.label2)
                }
                .foregroundStyle(Color.accentColor)
            }
            .padding(10)
            .allowsHitTesting(false)
            .transition(reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .scale(scale: 0.98)))
    }
}

// MARK: - Window depth
//
// LUMINANCE ONLY. A single soft key light from the upper left, and the
// backdrop settling into shadow at the foot of the window. No hue is
// introduced here — colour still has exactly one job, and this isn't it.
// This is what stops the window reading as one flat sheet of grey.

struct Backdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(stops: [
                .init(color: T.washTop,  location: 0.00),
                .init(color: .clear,     location: 0.42),
                .init(color: T.washFoot, location: 1.00),
            ], startPoint: .top, endPoint: .bottom)

            RadialGradient(colors: [T.keyLight, .clear],
                           center: UnitPoint(x: 0.26, y: -0.06),
                           startRadius: 0, endRadius: 560)
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}

// MARK: - Header pieces

struct ModelStatusStrip: View {
    let appleReady: Bool
    let qwenReady: Bool

    var body: some View {
        HStack(spacing: 10) {
            item(name: "apple", ready: appleReady, tint: T.apple)
            item(name: Ollama.model, ready: qwenReady, tint: T.qwen)
        }
        .help("Green means the model is loaded and reachable")
    }

    // The two names carry their own model's hue. This is not decoration —
    // it is the same colour-names-the-model rule the routing badge uses,
    // taught once up front so the badge is already legible when it appears.
    private func item(name: String, ready: Bool, tint: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .frame(width: 5, height: 5)
                .foregroundStyle(ready ? T.ready : T.down)
                .animation(.easeOut(duration: 0.2), value: ready)
            Text(name)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(ready ? tint : T.label3)
                .animation(.easeOut(duration: 0.2), value: ready)
        }
    }
}

struct OfflinePill: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "lock.fill").font(.system(size: 8.5, weight: .semibold))
            Text("Offline").font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(T.ready)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(height: 20)
        .background(Capsule().fill(T.ready.opacity(0.12)))
        .overlay(Capsule().strokeBorder(T.ready.opacity(0.22), lineWidth: 0.5))
        .help("Everything runs locally — no network involved")
    }
}

/// The only chrome button style in the app. `@State` has to live in the nested
/// view — declared on the style itself it compiles but never updates — and the
/// nested view must NOT be called `Body`, which collides with ButtonStyle's
/// own associated type.
struct IconButtonStyle: ButtonStyle {
    var active: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        Content(configuration: configuration, active: active)
    }

    private struct Content: View {
        let configuration: Configuration
        let active: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(active ? AnyShapeStyle(Color.accentColor)
                                        : AnyShapeStyle(isEnabled ? T.label2 : T.label3))
                .frame(width: 26, height: 22)
                .background {
                    RoundedRectangle(cornerRadius: R.plate, style: .continuous)
                        .fill(active ? AnyShapeStyle(Color.accentColor.opacity(0.14))
                                     : (hovering ? AnyShapeStyle(.quaternary)
                                                 : AnyShapeStyle(Color.clear)))
                }
                .contentShape(Rectangle())
                .scaleEffect(configuration.isPressed ? 0.92 : 1)
                .animation(M.press, value: configuration.isPressed)
                .onHover { h in withAnimation(M.hover) { hovering = h } }
        }
    }
}

// MARK: - Empty state

struct Suggestion: Identifiable {
    let id = UUID()
    let text: String
    /// Resolved live from the real router, so a chip never promises a model
    /// that would not actually answer. No rule match means the on-device
    /// classifier decides, and the chip says so.
    var member: Member? { Router.rule(for: text)?.member }
}

struct WelcomeCard: View {
    let suggestions: [Suggestion]
    let send: (String) -> Void

    private let copy = "Local Mind runs entirely on this Mac — nothing leaves it. A council of two models picks who answers each question: Apple’s on-device model for fast text work, Qwen for reasoning, code and facts. Drop an image in to read text out of it."

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(copy)
                .font(.system(size: 12.5))
                .lineSpacing(3)
                .foregroundStyle(T.label2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 520, alignment: .leading)

            VStack(alignment: .leading, spacing: 7) {
                Text("EACH ROUTES SOMEWHERE DIFFERENT")
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(T.label3)
                // Three glass chips 7pt apart. Without a container each one
                // would blur the two behind it and the stack would go milky;
                // the container makes them sample once and share edges.
                // Spacing is deliberately below their gap so they stay three
                // chips rather than fusing into one lozenge.
                GlassEffectContainer(spacing: 4) {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(suggestions) { s in
                            SuggestionChip(suggestion: s) { send(s.text) }
                        }
                    }
                }
            }
        }
        .padding(.leading, S.gutter)
    }
}

struct SuggestionChip: View {
    let suggestion: Suggestion
    let action: () -> Void
    @State private var hovering = false

    private var member: Member? { suggestion.member }
    private var tint: Color {
        switch member {
        case .apple: return T.apple
        case .qwen:  return T.qwen
        case nil:    return T.label3
        }
    }
    private var glyph: String {
        switch member {
        case .apple: return "cpu"
        case .qwen:  return "server.rack"
        case nil:    return "person.2"
        }
    }
    private var destination: String {
        switch member {
        case .apple: return "apple"
        case .qwen:  return "qwen"
        case nil:    return "council decides"
        }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: R.chip, style: .continuous)
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Image(systemName: glyph)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(tint)
                Text(suggestion.text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(T.label)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(destination)
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(tint)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .frame(maxWidth: 520, alignment: .leading)
            // The chip is tinted glass in the hue of the model that would
            // actually answer it — so the chip both looks alive and tells
            // you where it goes, which is the one job colour has here.
            .glassEffect(.regular.tint(tint.opacity(hovering ? 0.34 : 0.20)).interactive(),
                         in: shape)
            .overlay(shape.strokeBorder(tint.opacity(hovering ? 0.45 : 0.22), lineWidth: 0.75))
            .shadow(color: T.castSoft, radius: hovering ? 10 : 5, y: hovering ? 4 : 2)
            // Hit area follows the drawn shape, so the corners are not live.
            .contentShape(shape)
        }
        .buttonStyle(ChipButtonStyle())
        .onHover { h in withAnimation(M.hover) { hovering = h } }
    }
}

private struct ChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(M.press, value: configuration.isPressed)
    }
}

// MARK: - Message row

struct MessageRow: View {
    let msg: Msg
    var accentTick: Int = 0
    var isStreaming: Bool = false
    let onRun: (UUID) -> Void
    let onCancel: (UUID) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tint: Color { msg.member == .qwen ? T.qwen : T.apple }

    var body: some View {
        switch msg.role {
        case .confirm:
            if let a = msg.action {
                if msg.resolved {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle").font(.system(size: 10.5))
                            .foregroundStyle(T.label3)
                        Text(a.verb).font(.system(size: 11)).foregroundStyle(T.label2)
                    }
                    .padding(.leading, S.gutter)
                } else {
                    ConfirmCard(action: a,
                                onRun: { onRun(a.id) },
                                onCancel: { onCancel(a.id) })
                }
            }

        case .note where msg.permission != nil:
            // The designed permission UI, which was previously defined but
            // never instantiated — a plain note row was shown instead.
            PermissionBanner(perms: msg.permission!, needsCapture: msg.needsCapture)
                .padding(.leading, S.gutter)

        case .note:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 10.5))
                    .foregroundStyle(T.label3)
                Text(msg.text)
                    .font(.system(size: 11))
                    .foregroundStyle(T.label2)
                    .fixedSize(horizontal: false, vertical: true)
                if let e = msg.elapsed {
                    Text(String(format: "%.2fs", e))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(T.label2)
                        .monospacedDigit()
                }
            }
            .padding(.leading, S.gutter)
            .frame(maxWidth: .infinity, alignment: .leading)

        case .user:
            HStack(alignment: .top) {
                Spacer(minLength: 60)
                VStack(alignment: .trailing, spacing: 7) {
                    // Thumbnail of a dropped or pasted picture, so the
                    // transcript shows what was actually handed over.
                    if let cg = msg.image {
                        Image(decorative: cg, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 260, maxHeight: 190)
                            .clipShape(RoundedRectangle(cornerRadius: R.code, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: R.code, style: .continuous)
                                .strokeBorder(T.hair, lineWidth: 0.75))
                            .shadow(color: T.castSoft, radius: 5, y: 2)
                    }
                    if !msg.text.isEmpty {
                        Text(msg.text)
                    // Text lifted out of a picture is shown only as a short
                    // proof-of-read; the thumbnail above already carries it,
                    // and the model still receives the full text.
                    .lineLimit(msg.image == nil ? nil : 4)
                    .truncationMode(.tail)
                    .font(.system(size: 13, weight: .medium))
                    .lineSpacing(2.5)
                    .foregroundStyle(AccentInk.onAccent)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, S.bubbleH)
                    .padding(.vertical, S.bubbleV)
                    .background(
                        bubbleShape
                            // NO glass here. The bubble sits on the accent
                            // colour, and glass over a saturated fill turns
                            // the white text on it to mush. It gets its
                            // depth from a shaded fill and a real shadow.
                            .fill(Color.accentColor.gradient)
                    )
                    .overlay(bubbleShape.strokeBorder(Color.white.opacity(0.18), lineWidth: 0.75))
                    .shadow(color: Color.accentColor.opacity(0.30), radius: 10, y: 4)
                    .shadow(color: T.castSoft, radius: 3, y: 1)
                    .frame(maxWidth: 480, alignment: .trailing)
                    .id(accentTick)
                    }
                }
            }

        case .assistant:
            HStack(alignment: .top, spacing: 11) {
                // Glyph plus a hue rail that runs the height of the answer.
                // This is the one place the model hue gets real estate
                // proportional to how much the model actually said — colour
                // still only ever names who is speaking.
                VStack(spacing: 5) {
                    ModelGlyph(member: msg.member, routing: msg.routing, tint: tint)
                    Capsule()
                        .fill(LinearGradient(
                            colors: [tint.opacity(msg.routing ? 0.0 : 0.42), tint.opacity(0.0)],
                            startPoint: .top, endPoint: .bottom))
                        .frame(width: S.spine)
                        .frame(maxHeight: .infinity)
                }
                .animation(calmed(M.verdict, reduceMotion, 0.26), value: msg.routing)

                VStack(alignment: .leading, spacing: 8) {
                    if msg.routing {
                        ThinkingIndicator()
                    } else if let m = msg.member, let c = msg.category {
                        RoutingBadge(name: m == .qwen ? Ollama.model : "apple on-device",
                                     blurb: c.blurb,
                                     viaRule: msg.viaRule,
                                     elapsed: msg.elapsed,
                                     tint: tint)
                            .transition(reduceMotion
                                        ? .opacity
                                        : .opacity.combined(with: .scale(scale: 0.94, anchor: .leading)))
                    }

                    if msg.text.isEmpty {
                        // `elapsed` is only set once the answer has finished, so
                        // an empty row WITH a time is a failure, not work in
                        // progress. Showing the spinner there made a dead answer
                        // look like it was still loading, forever.
                        if msg.elapsed != nil {
                            Text("No answer came back. See the note below.")
                                .font(.system(size: 12.5))
                                .foregroundStyle(T.label2)
                        } else if !msg.routing {
                            ThinkingIndicator()
                        }
                    } else {
                        // NO glass behind the answer body. Translucency under
                        // a paragraph destroys contrast; the answer is the one
                        // thing in this window that must stay perfectly legible.
                        MarkdownText(raw: msg.text, isStreaming: isStreaming, tint: tint)
                    }
                }
                .animation(calmed(M.verdict, reduceMotion, 0.26), value: msg.routing)

                Spacer(minLength: 0)
            }
        }
    }

    private var bubbleShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: R.bubble,
                               bottomLeadingRadius: R.bubble,
                               bottomTrailingRadius: 5,
                               topTrailingRadius: R.bubble,
                               style: .continuous)
    }
}

struct ModelGlyph: View {
    let member: Member?
    let routing: Bool
    let tint: Color

    var body: some View {
        Image(systemName: routing ? "ellipsis" : (member == .qwen ? "server.rack" : "cpu"))
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(routing ? AnyShapeStyle(T.label3) : AnyShapeStyle(tint))
            .frame(width: 24, height: 24)
            .background(
                Circle().fill(routing ? AnyShapeStyle(.quaternary)
                                      : AnyShapeStyle(tint.opacity(0.20).gradient))
            )
            .overlay(Circle().strokeBorder(routing ? Color.clear : tint.opacity(0.38),
                                           lineWidth: 0.75))
            // A real cast shadow lifts the glyph off the page — it is the
            // head of the answer, so it should read as the nearest thing.
            .shadow(color: routing ? .clear : T.castSoft, radius: 5, y: 2)
            .padding(.top, 1)
    }
}

/// The signature ornament: which mind answered, why, and how long it took.
struct RoutingBadge: View {
    let name: String
    let blurb: String
    let viaRule: Bool
    let elapsed: Double?
    let tint: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 5) {
            Text(name.uppercased())
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(0.4)
                .foregroundStyle(tint)

            rule

            Text(blurb)
                .font(.system(size: 10))
                .foregroundStyle(T.label2)

            if viaRule {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(T.label3)
                    .help("Matched by a keyword rule — no classifier call")
            }

            if let e = elapsed {
                rule
                Text(String(format: "%.2fs", e))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(T.label2)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
        }
        .padding(.horizontal, S.badgeH + 1)
        .padding(.vertical, S.badgeV + 1)
        .background(Capsule().fill(tint.opacity(0.16).gradient))
        .overlay(Capsule().strokeBorder(tint.opacity(0.30), lineWidth: 0.75))
        .shadow(color: T.castSoft, radius: 4, y: 1)
        .animation(calmed(M.numeric, reduceMotion, 0.20), value: elapsed)
    }

    private var rule: some View {
        Rectangle().fill(tint.opacity(0.40)).frame(width: 1, height: 9)
    }
}

/// The only repeating animation in the app — system-timed, and it stops on its
/// own when the row goes away.
struct ThinkingIndicator: View {
    var body: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 13))
            .foregroundStyle(T.label2)
            .symbolEffect(.variableColor.iterative, isActive: true)
            .frame(height: S.thinkingHeight, alignment: .leading)
    }
}

// MARK: - Window vibrancy

struct WindowBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .underWindowBackground
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}
