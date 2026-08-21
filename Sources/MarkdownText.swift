import SwiftUI
import AppKit

enum MDBlock {
    case heading(Int, String)
    case bullet(String)
    case numbered(String, String)
    case paragraph(String)
    case code(String)
}


/// Apple's model emits LaTeX delimiters ( \( x \), \[ ... \], $$ ... $$ ).
/// Strip the delimiters so the math reads as plain text instead of raw markup.
func stripLatex(_ s: String) -> String {
    var out = s
    for (pat, rep) in [
        (#"\\\[|\\\]"#, ""),      // \[  \]
        (#"\\\(|\\\)"#, ""),      // \(  \)
        (#"\$\$"#, ""),               // $$
    ] {
        out = out.replacingOccurrences(of: pat, with: rep, options: .regularExpression)
    }
    return out.trimmingCharacters(in: .whitespaces)
}

func parseMarkdown(_ text: String) -> [MDBlock] {
    var blocks: [MDBlock] = []
    var inCode = false
    var codeBuf: [String] = []
    var paraBuf: [String] = []

    func flushPara() {
        if !paraBuf.isEmpty {
            blocks.append(.paragraph(paraBuf.joined(separator: " ")))
            paraBuf.removeAll()
        }
    }

    for line in text.components(separatedBy: .newlines) {
        let t = stripLatex(line.trimmingCharacters(in: .whitespaces))

        if t.hasPrefix("```") {
            if inCode {
                blocks.append(.code(codeBuf.joined(separator: "\n")))
                codeBuf.removeAll(); inCode = false
            } else {
                flushPara(); inCode = true
            }
            continue
        }
        if inCode { codeBuf.append(line); continue }
        if t.isEmpty { flushPara(); continue }

        if t.hasPrefix("#") {
            flushPara()
            let level = t.prefix(while: { $0 == "#" }).count
            blocks.append(.heading(level, String(t.dropFirst(level)).trimmingCharacters(in: .whitespaces)))
            continue
        }
        // bullets: -, *, • followed by a space
        if t.count > 2, ["- ", "* ", "• "].contains(String(t.prefix(2))) {
            flushPara()
            blocks.append(.bullet(String(t.dropFirst(2))))
            continue
        }
        // numbered: "1. " / "2) "
        if let r = t.range(of: #"^\d+[\.\)]\s+"#, options: .regularExpression) {
            flushPara()
            let marker = t[r].trimmingCharacters(in: .whitespaces)
            blocks.append(.numbered(marker, String(t[r.upperBound...])))
            continue
        }
        paraBuf.append(t)
    }
    if inCode && !codeBuf.isEmpty { blocks.append(.code(codeBuf.joined(separator: "\n"))) }
    flushPara()
    return blocks
}

// MARK: - Inline styling

/// Per-run inline markdown. The previous `inlineMD` handed the parsed string
/// straight to `Text`, which rendered `code` runs as literal backticks; the
/// inline presentation intents have to be turned into fonts by hand.
func inlineStyled(_ s: String,
                  size: CGFloat = 13,
                  weight: Font.Weight = .regular) -> AttributedString {
    var a = (try? AttributedString(markdown: s, options: .init(
        allowsExtendedAttributes: true,
        interpretedSyntax: .inlineOnlyPreservingWhitespace,
        failurePolicy: .returnPartiallyParsedIfPossible))) ?? AttributedString(s)
    a.font = .system(size: size, weight: weight)
    a.foregroundColor = T.label
    for run in a.runs {
        guard let i = run.inlinePresentationIntent else { continue }
        if i.contains(.code) {
            a[run.range].font = .system(size: size - 1, design: .monospaced)
            a[run.range].backgroundColor = T.sunken
        } else if i.contains(.stronglyEmphasized) {
            a[run.range].font = .system(size: size, weight: .semibold)
        } else if i.contains(.emphasized) {
            a[run.range].font = .system(size: size, weight: weight).italic()
        }
    }
    return a
}

/// The "wet edge": while a reply streams, its trailing characters fall off in
/// opacity, marking exactly how far the model has written. No timer, no CPU
/// wake, no blinking cursor.
///
/// `AttributedString.index(_:offsetByCharacters:)` TRAPS out of range — only
/// `index(_:offsetBy:limitedBy:)` is safe on a string that is one token long.
func wetEdge(_ src: AttributedString, base: Color) -> AttributedString {
    let tail = 24, steps = 6, floorAlpha = 0.28
    var a = src
    let n = min(tail, a.characters.count)
    guard n > 1 else { return a }
    let per = max(1, Int((Double(n) / Double(steps)).rounded(.up)))
    var upper = a.endIndex
    var step = 0
    while step < steps, upper > a.startIndex {
        guard let lower = a.characters.index(upper, offsetBy: -per, limitedBy: a.startIndex)
        else { break }
        a[lower..<upper].foregroundColor =
            base.opacity(floorAlpha + (1 - floorAlpha) * Double(step) / Double(steps - 1))
        upper = lower
        step += 1
    }
    return a
}

// MARK: - Renderer

struct MarkdownText: View {
    let raw: String
    var isStreaming: Bool = false
    /// The hue of the model that wrote this. List markers borrow it, which is
    /// the same colour-names-the-model rule the routing badge follows.
    var tint: Color = T.label2

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let blocks = parseMarkdown(raw)
        VStack(alignment: .leading, spacing: S.mdBlock) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { i, b in
                block(b, isLast: i == blocks.count - 1)
            }
        }
        .textSelection(.enabled)
        // Growing text must never animate: implicit animation at 20+ updates a
        // second produces ghosting and reflow shimmer.
        .transaction { $0.animation = nil }
    }

    @ViewBuilder
    private func block(_ b: MDBlock, isLast: Bool) -> some View {
        switch b {
        case .heading(let lvl, let s):
            Text(inlineStyled(s, size: lvl <= 1 ? 16 : 13.5, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, lvl <= 1 ? 6 : 4)

        case .bullet(let s):
            // The old marker was a 13pt "•" in T.label3 sitting in a 12pt
            // column 8pt from its text: too pale to register and floating
            // far enough out to look like it belonged to nothing. Now it is
            // a solid disc in the model's own hue, raised off the baseline
            // to the optical centre of the first line, in a tighter column —
            // so it reads as attached to the sentence it introduces.
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("\u{25CF}")                       // ● BLACK CIRCLE
                    .font(.system(size: 5.5))
                    .baselineOffset(3.5)
                    .foregroundStyle(tint)
                    .frame(width: S.bulletCol, alignment: .trailing)
                Text(inlineStyled(s))
                    .lineSpacing(2.5)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .numbered(let marker, let s):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(marker)
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .frame(width: S.bulletCol + 7, alignment: .trailing)
                Text(inlineStyled(s))
                    .lineSpacing(2.5)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .paragraph(let s):
            // NO .foregroundStyle anywhere on this Text or its ancestors —
            // a view-level foreground style silently overrides the per-run
            // colours the wet edge depends on.
            Text(paragraphString(s, isLast: isLast))
                .lineSpacing(2.5)
                .fixedSize(horizontal: false, vertical: true)

        case .code(let s):
            CodeBlock(source: s)
        }
    }

    private func paragraphString(_ s: String, isLast: Bool) -> AttributedString {
        let styled = inlineStyled(s)
        guard isStreaming, isLast, !reduceMotion, styled.characters.count > 60 else { return styled }
        return wetEdge(styled, base: T.label)
    }
}

// MARK: - Code block

struct CodeBlock: View {
    let source: String
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(source)
                .font(.system(size: 11.5, design: .monospaced))
                .lineSpacing(3)
                .foregroundStyle(T.label)
                .padding(10)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: R.code, style: .continuous).fill(T.sunken))
        .overlay(RoundedRectangle(cornerRadius: R.code, style: .continuous)
            .strokeBorder(T.hair, lineWidth: 0.5))
        .overlay(alignment: .topTrailing) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(source, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.4))
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(copied ? T.ready : T.label2)
                    .frame(width: 20, height: 20)
                    .background(RoundedRectangle(cornerRadius: R.plate, style: .continuous)
                        .fill(.regularMaterial))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .padding(6)
            .opacity(hovering ? 1 : 0)
            .help("Copy code")
        }
        .onHover { h in withAnimation(M.hover) { hovering = h } }
    }
}
