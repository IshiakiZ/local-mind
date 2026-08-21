import Foundation
import AppKit

/// Saving is deliberately OPT-IN. Nothing is written to disk unless the user
/// presses Save and chooses a destination — there is no autosave, no history
/// folder, and no background persistence anywhere in this app.
enum ChatArchive {

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
        return out
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
