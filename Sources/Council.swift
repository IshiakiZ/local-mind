import Foundation
import FoundationModels

// MARK: - Council members

enum Member: String, Sendable {
    case apple = "Apple on-device"
    case qwen  = "Qwen"

    var short: String { self == .apple ? "apple" : "qwen" }
}

enum Category: String, CaseIterable, Sendable {
    case summarize, rewrite, reasoning, code, knowledge, chitchat, screen

    /// Which member handles this, based on the measured benchmark:
    /// Apple won summarizing and is instant for small talk; it lost
    /// rewriting (inverted meaning), reasoning, code and knowledge.
    var member: Member {
        switch self {
        case .summarize, .chitchat: return .apple
        case .rewrite, .reasoning, .code, .knowledge, .screen: return .qwen
        }
    }

    var blurb: String {
        switch self {
        case .summarize: return "condensing your text"
        case .rewrite:   return "rewriting your text"
        case .reasoning: return "step-by-step reasoning"
        case .code:      return "programming"
        case .knowledge: return "world knowledge"
        case .chitchat:  return "small talk"
        case .screen:    return "reading your screen"
        }
    }
}

struct Route: Sendable {
    let category: Category
    let member: Member
    let viaRule: Bool
}

// MARK: - Router

enum Router {
    /// Fast deterministic pass. Returns nil when it isn't confident.
    static func rule(for text: String) -> Category? {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Screen wins over everything: it is decided by a deterministic parse
        // of the user's own words, never by a model.
        if ScreenRouter.isScreenRequest(text) { return .screen }
        let words = t.split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)

        // small talk: short and greeting-ish
        let greetings: Set<String> = ["hi","hey","hello","yo","thanks","thank","cheers","bye","goodbye","sup","morning"]
        if words.count <= 6, words.contains(where: { greetings.contains($0) }) { return .chitchat }

        // code
        let codeWords = ["python","javascript","typescript","swift","java","rust","golang","sql",
                         "regex","function","def ","class ","compile","stacktrace","traceback",
                         "syntax error","npm","git ","bug in","refactor","json","api endpoint"]
        if codeWords.contains(where: { t.contains($0) }) { return .code }

        // explicit text operations
        if t.hasPrefix("summarize") || t.hasPrefix("tldr") || t.contains("in two sentences")
            || t.contains("summarise") || t.hasPrefix("shorten") { return .summarize }
        if t.hasPrefix("rewrite") || t.hasPrefix("rephrase") || t.hasPrefix("reword")
            || t.hasPrefix("proofread") || t.contains("sound polite") || t.contains("make this sound") { return .rewrite }

        return nil
    }

    private static func schema() throws -> GenerationSchema {
        let cat = DynamicGenerationSchema(
            name: "Category", description: "The single best category",
            anyOf: Category.allCases.map(\.rawValue))
        let root = DynamicGenerationSchema(name: "Routing", properties: [
            .init(name: "category", description: "One of the allowed categories", schema: cat)
        ])
        return try GenerationSchema(root: root, dependencies: [])
    }

    private static let instructions = """
    Classify the user's request into exactly one category.
    summarize = condense or extract from text the user pasted in.
    rewrite = reword, rephrase, change tone, proofread text the user pasted in.
    reasoning = arithmetic, times, dates, money, logic puzzles, multi-step deduction.
    code = programming, scripts, regex, debugging.
    knowledge = factual questions about how the world works.
    chitchat = greetings, thanks, small talk.
    screen = questions about what is currently on the user's Mac screen, or asking to open/click/type in an app.
    """

    /// Rules first; falls back to the on-device classifier.
    static func route(_ text: String) async -> Route {
        if let c = rule(for: text) {
            return Route(category: c, member: c.member, viaRule: true)
        }
        do {
            let s = LanguageModelSession(instructions: instructions)
            let r = try await s.respond(to: text, schema: try schema())
            let raw = try r.content.value(String.self, forProperty: "category")
            let c = Category(rawValue: raw) ?? .knowledge
            return Route(category: c, member: c.member, viaRule: false)
        } catch {
            return Route(category: .knowledge, member: .qwen, viaRule: false)
        }
    }
}

// MARK: - Ollama

enum Ollama {
    static let base = URL(string: "http://127.0.0.1:11434")!
    nonisolated(unsafe) static var model = "qwen3:8b"

    static func isUp() async -> Bool {
        var r = URLRequest(url: base.appendingPathComponent("api/version"))
        r.timeoutInterval = 2
        return ((try? await URLSession.shared.data(for: r)) != nil)
    }

    /// One turn of a conversation handed to Ollama.
    struct Turn: Sendable {
        let role: String        // "system" | "user" | "assistant"
        let content: String
    }

    /// Streaming chat WITH history. `/api/generate` is stateless — it only ever
    /// sees the latest prompt, which is why follow-up questions used to fail.
    /// `/api/chat` takes the whole exchange.
    static func chatStream(_ turns: [Turn]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = URLRequest(url: base.appendingPathComponent("api/chat"))
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.timeoutInterval = 600
                    req.httpBody = try JSONSerialization.data(withJSONObject: [
                        "model": model,
                        "messages": turns.map { ["role": $0.role, "content": $0.content] },
                        "stream": true,
                        "think": false,
                    ])
                    let (bytes, _) = try await URLSession.shared.bytes(for: req)
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard let d = line.data(using: .utf8),
                              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
                        else { continue }
                        if let m = o["message"] as? [String: Any],
                           let piece = m["content"] as? String, !piece.isEmpty {
                            continuation.yield(piece)
                        }
                        if (o["done"] as? Bool) == true { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Ordered async sequence of response chunks.
    static func streamSeq(prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    var req = URLRequest(url: base.appendingPathComponent("api/generate"))
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.timeoutInterval = 600
                    req.httpBody = try JSONSerialization.data(withJSONObject: [
                        "model": model, "prompt": prompt, "stream": true, "think": false
                    ])
                    let (bytes, _) = try await URLSession.shared.bytes(for: req)
                    for try await line in bytes.lines {
                        guard let d = line.data(using: .utf8),
                              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
                        else { continue }
                        if let piece = o["response"] as? String, !piece.isEmpty {
                            continuation.yield(piece)
                        }
                        if (o["done"] as? Bool) == true { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    static func stream(prompt: String, onDelta: @Sendable @escaping (String) -> Void) async throws {
        var req = URLRequest(url: base.appendingPathComponent("api/generate"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 300
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "prompt": prompt, "stream": true, "think": false
        ])
        let (bytes, _) = try await URLSession.shared.bytes(for: req)
        for try await line in bytes.lines {
            guard let d = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            if let piece = o["response"] as? String, !piece.isEmpty { onDelta(piece) }
            if (o["done"] as? Bool) == true { return }
        }
    }
}
