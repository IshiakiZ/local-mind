import Foundation
import AppKit

/// Saving is deliberately OPT-IN. Nothing is written to disk unless the user
/// presses Save and chooses a destination — there is no autosave, no history
/// folder, and no background persistence anywhere in this app.
enum ChatArchive {

    /// What actually round-trips. Thumbnails are deliberately not stored: they
    /// would bloat the file enormously for something the transcript already
    /// describes in words.
    private struct Stored: Codable {
        var role: String
        var text: String
        var elapsed: Double?
        var member: String?
        var category: String?
        var viaRule: Bool
    }

    private static let marker = "localmind-transcript-v1"


    /// Render a transcript as Markdown, preserving who answered and how long it took.
    static func markdown(_ messages: [Msg], exported: Date = Date()) -> String {
        let stamp = DateFormatter()
        stamp.dateFormat = "EEEE d MMMM yyyy 'at' HH:mm"

        var out = "# Local Mind conversation\n\n"
        out += "_Saved \(stamp.string(from: exported)). Every answer below was generated "
        out += "entirely on this Mac — no network involved._\n\n---\n\n"

        for m in messages {
            switch m.role {
            case .user:
                out += "### You\n\n\(m.text)\n\n"

            case .assistant:
                guard !m.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let who = m.member == .qwen ? Ollama.model : "Apple on-device"
                var meta = who
                if let c = m.category { meta += " · \(c.blurb)" }
                if let e = m.elapsed { meta += String(format: " · %.2fs", e) }
                out += "### \(who)\n\n`\(meta)`\n\n\(m.text)\n\n"

            case .note:
                out += "> \(m.text)\n\n"

            case .confirm:
                if let a = m.action {
                    let state = m.resolved ? "ran" : "not run"
                    out += "> **Action proposed:** \(a.verb) — \(a.target) _(\(state))_\n\n"
                }
            }
        }
        // Machine-readable payload so the file can be reopened. It lives in an
        // HTML comment, so it is invisible in any Markdown renderer.
        let stored = messages.compactMap { m -> Stored? in
            switch m.role {
            case .user, .assistant, .note:
                return Stored(role: String(describing: m.role), text: m.text,
                              elapsed: m.elapsed,
                              member: m.member.map { String(describing: $0) },
                              category: m.category.map { $0.rawValue },
                              viaRule: m.viaRule)
            case .confirm:
                return nil
            }
        }
        if let data = try? JSONEncoder().encode(stored),
           let json = String(data: data, encoding: .utf8) {
            out += "\n<!-- \(marker) \(json) -->\n"
        }
        return out
    }

    /// Rebuild a transcript from a file this app wrote.
    static func parse(_ text: String) -> [Msg]? {
        guard let r = text.range(of: "<!-- \(marker) ") else { return nil }
        let rest = text[r.upperBound...]
        guard let end = rest.range(of: " -->") else { return nil }
        let json = String(rest[..<end.lowerBound])
        guard let data = json.data(using: .utf8),
              let stored = try? JSONDecoder().decode([Stored].self, from: data) else { return nil }
        return stored.map { st in
            let role: Role = st.role == "user" ? .user : (st.role == "assistant" ? .assistant : .note)
            return Msg(role: role, text: st.text, elapsed: st.elapsed,
                       member: st.member == "qwen" ? .qwen : (st.member == "apple" ? .apple : nil),
                       category: st.category.flatMap(Category.init(rawValue:)),
                       viaRule: st.viaRule)
        }
    }

    /// Ask for a saved conversation and hand back its messages.
    @MainActor
    static func presentOpenPanel() -> (messages: [Msg], status: String)? {
        let panel = NSOpenPanel()
        panel.title = "Open a saved conversation"
        panel.prompt = "Open"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.init(filenameExtension: "md")].compactMap { $0 }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return ([], "Couldn't read that file.")
        }
        guard let msgs = parse(text) else {
            return ([], "That file wasn't saved by Local Mind, so it can't be reopened.")
        }
        return (msgs, "Reopened \(url.lastPathComponent) — \(msgs.count) rows. Images aren't stored in saved files.")
    }

    /// Suggest a filename from the first thing the user actually asked.
    static func suggestedName(_ messages: [Msg]) -> String {
        let first = messages.first { $0.role == .user }?.text ?? "conversation"
        // Trim to a natural stopping point rather than cutting mid-phrase.
        let dangling: Set<String> = ["if", "a", "an", "the", "and", "to", "do", "i", "of",
                                     "in", "on", "for", "is", "at", "my", "that", "this"]
        var words = Array(first.split(separator: " ").prefix(8).map(String.init))
        while let last = words.last, dangling.contains(last.lowercased()), words.count > 2 {
            words.removeLast()
        }
        let joined = words.joined(separator: " ")
        let cleaned = joined.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let day = DateFormatter(); day.dateFormat = "yyyy-MM-dd"
        let base = cleaned.isEmpty ? "conversation" : cleaned
        return "Local Mind — \(base) \(day.string(from: Date())).md"
    }

    /// True when there is anything worth saving.
    static func hasContent(_ messages: [Msg]) -> Bool {
        messages.contains { $0.role == .user }
    }

    /// Ask the user where to put it. Returns a short status line for the transcript.
    @MainActor
    static func presentSavePanel(for messages: [Msg]) -> String? {
        guard hasContent(messages) else { return "Nothing to save yet." }

        let panel = NSSavePanel()
        panel.title = "Save conversation"
        panel.prompt = "Save"
        panel.nameFieldStringValue = suggestedName(messages)
        panel.allowedContentTypes = [.init(filenameExtension: "md")].compactMap { $0 }
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.message = "This conversation will be written to a Markdown file. Nothing else is saved automatically."

        guard panel.runModal() == .OK, let url = panel.url else { return nil }   // cancelled
        do {
            try markdown(messages).write(to: url, atomically: true, encoding: .utf8)
            return "Saved to \(url.path)"
        } catch {
            return "Couldn't save: \(error.localizedDescription)"
        }
    }
}
