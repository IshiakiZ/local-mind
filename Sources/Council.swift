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

enum OllamaError: LocalizedError {
    case http(Int, String)
    case server(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .http(let code, let detail):
            return "Ollama replied HTTP \(code). \(detail)"
        case .server(let msg):
            return "Ollama reported: \(msg)"
        case .empty:
            return "Ollama accepted the request but sent no text back. The model may not be installed — try `ollama pull qwen3:8b` in Terminal."
        }
    }
}

enum Ollama {
    /// Turn a status code into something a person can act on.
    static func explain(_ code: Int, _ body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        switch code {
        case 404:
            return "The model “\(model)” isn't installed. Run `ollama pull \(model)` in Terminal."
        case 400:
            return "The request was rejected — this usually means Ollama is out of date. Run `brew upgrade ollama`. \(trimmed)"
        default:
            return trimmed
        }
    }

    static let base = URL(string: "http://127.0.0.1:11434")!
    nonisolated(unsafe) static var model = "qwen3:8b"

    /// Ask Ollama to drop the model from memory. `keep_alive: 0` unloads it
    /// immediately, giving back the ~6 GB it was holding. The server itself
    /// stays running — idle it costs almost nothing, and stopping it would
    /// break anything else on the Mac that uses Ollama.
    ///
    /// Deliberately NOT async: this is called from applicationWillTerminate,
    /// where the main thread must block until it completes. An `async` version
    /// deadlocks — the Task inherits the main actor, which is exactly what the
    /// blocking wait is holding.
    static func unloadBlocking(timeout: TimeInterval = 3) {
        var req = URLRequest(url: base.appendingPathComponent("api/generate"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = timeout
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model, "keep_alive": 0,
        ])
        let sem = DispatchSemaphore(value: 0)
        // The completion handler runs on a URLSession queue, not the main
        // thread, so signalling from here is safe.
        URLSession.shared.dataTask(with: req) { _, _, _ in sem.signal() }.resume()
        _ = sem.wait(timeout: .now() + timeout)
    }

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

    /// Let the model call tools before it answers.
    ///
    /// Runs a short non-streaming exchange: ask with the tool definitions, run
    /// whatever it asks for, feed the results back, repeat. Returns the message
    /// array to stream the final answer from. Tools are read-only and cannot
    /// change the machine, so no confirmation is needed — unlike screen actions.
    static func resolveTools(_ turns: [Turn], maxRounds: Int = 3) async -> [[String: Any]] {
        var msgs: [[String: Any]] = turns.map { ["role": $0.role, "content": $0.content] }

        for _ in 0..<maxRounds {
            var req = URLRequest(url: base.appendingPathComponent("api/chat"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 120
            guard let body = try? JSONSerialization.data(withJSONObject: [
                "model": model, "messages": msgs, "stream": false,
                "think": false, "tools": Tools.definitions,
            ]) else { return msgs }
            req.httpBody = body

            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = o["message"] as? [String: Any] else {
                return msgs      // tools unsupported or unreachable — answer without them
            }

            guard let calls = message["tool_calls"] as? [[String: Any]], !calls.isEmpty else {
                return msgs      // nothing to call; stream the answer normally
            }

            msgs.append(message)
            for call in calls {
                guard let fn = call["function"] as? [String: Any],
                      let name = fn["name"] as? String else { continue }
                let args = (fn["arguments"] as? [String: Any]) ?? [:]
                let result = Tools.run(name: name, arguments: args)
                msgs.append(["role": "tool", "name": name, "content": result])
            }
        }
        return msgs
    }

    /// Stream a reply from an already-built message array.
    static func chatStreamRaw(_ msgs: [[String: Any]]) -> AsyncThrowingStream<String, Error> {
        // Encode BEFORE the Task: [[String: Any]] is not Sendable, so capturing
        // it in the closure is a data race. Data is.
        let payload = try? JSONSerialization.data(withJSONObject: [
            "model": model, "messages": msgs, "stream": true, "think": false,
        ])
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let payload else { throw OllamaError.empty }
                    var req = URLRequest(url: base.appendingPathComponent("api/chat"))
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.timeoutInterval = 600
                    req.httpBody = payload
                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                        var body = ""
                        for try await l in bytes.lines { body += l; if body.count > 400 { break } }
                        throw OllamaError.http(http.statusCode, Self.explain(http.statusCode, body))
                    }
                    var got = 0
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard let d = line.data(using: .utf8),
                              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
                        else { continue }
                        if let e = o["error"] as? String { throw OllamaError.server(e) }
                        if let m = o["message"] as? [String: Any],
                           let piece = m["content"] as? String, !piece.isEmpty {
                            got += 1
                            continuation.yield(piece)
                        }
                        if (o["done"] as? Bool) == true { break }
                    }
                    if got == 0 && !Task.isCancelled { throw OllamaError.empty }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
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
                    var (bytes, response) = try await URLSession.shared.bytes(for: req)

                    // An error reply is NOT the stream we expect. Without this
                    // check the body parses to nothing, the stream finishes
                    // empty, and the UI spins forever on a "finished" answer.
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        var body = ""
                        for try await line in bytes.lines { body += line; if body.count > 400 { break } }

                        // Older Ollama builds reject the `think` parameter outright.
                        // Retry once without it rather than failing the user.
                        if http.statusCode == 400, body.contains("think"), !turns.isEmpty {
                            var retry = URLRequest(url: base.appendingPathComponent("api/chat"))
                            retry.httpMethod = "POST"
                            retry.setValue("application/json", forHTTPHeaderField: "Content-Type")
                            retry.timeoutInterval = 600
                            retry.httpBody = try JSONSerialization.data(withJSONObject: [
                                "model": model,
                                "messages": turns.map { ["role": $0.role, "content": $0.content] },
                                "stream": true,
                            ])
                            let (rb, rr) = try await URLSession.shared.bytes(for: retry)
                            if let rh = rr as? HTTPURLResponse, rh.statusCode != 200 {
                                throw OllamaError.http(rh.statusCode, body)
                            }
                            bytes = rb
                        } else {
                            throw OllamaError.http(http.statusCode, Self.explain(http.statusCode, body))
                        }
                    }

                    var got = 0
                    var sawThinkTag = false
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard let d = line.data(using: .utf8),
                              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
                        else { continue }
                        if let err = o["error"] as? String { throw OllamaError.server(err) }
                        if let m = o["message"] as? [String: Any],
                           let piece = m["content"] as? String, !piece.isEmpty {
                            // Older builds that ignore `think` inline the reasoning.
                            if piece.contains("<think>") { sawThinkTag = true }
                            got += 1
                            continuation.yield(piece)
                        }
                        if (o["done"] as? Bool) == true { break }
                    }
                    if got == 0 && !Task.isCancelled {
                        throw OllamaError.empty
                    }
                    _ = sawThinkTag
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
