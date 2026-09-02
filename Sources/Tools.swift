import Foundation

/// Deterministic helpers the model can call instead of guessing.
///
/// Scope is deliberately narrow and READ-ONLY. Nothing here can change the
/// machine, run arbitrary code, or reach the network. The benchmark showed the
/// models failing at exactly two things — arithmetic and knowing the date — so
/// those are what they get. Anything with side effects still goes through the
/// confirmation card, where the user can see it before it happens.
enum Tools {

    /// Built fresh each time: a `[[String: Any]]` constant isn't Sendable under
    /// Swift 6 strict concurrency.
    static var definitions: [[String: Any]] { [
        [
            "type": "function",
            "function": [
                "name": "calculate",
                "description": "Evaluate an arithmetic expression exactly. Use this for ANY sum, "
                             + "product, percentage or comparison of numbers rather than working "
                             + "it out yourself. Supports + - * / ( ) and decimals.",
                "parameters": [
                    "type": "object",
                    "properties": ["expression": [
                        "type": "string",
                        "description": "Arithmetic only, e.g. \"(7*60+45) + 100 + 20\"",
                    ]],
                    "required": ["expression"],
                ],
            ],
        ],
        [
            "type": "function",
            "function": [
                "name": "current_datetime",
                "description": "The current local date, time and timezone on this Mac. Use this "
                             + "whenever the answer depends on today's date or the time now.",
                "parameters": ["type": "object", "properties": [:]],
            ],
        ],
        [
            "type": "function",
            "function": [
                "name": "add_time",
                "description": "Add hours and minutes to a clock time and get the result. Use this "
                             + "for arrival times and durations instead of doing it in your head.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "start": ["type": "string", "description": "Start time, e.g. \"7:45 AM\" or \"19:30\""],
                        "hours": ["type": "number", "description": "Hours to add"],
                        "minutes": ["type": "number", "description": "Minutes to add"],
                    ],
                    "required": ["start"],
                ],
            ],
        ],
    ] }

    /// Run one tool call. Always returns text — an error string is more useful
    /// to the model than a silent failure.
    static func run(name: String, arguments: [String: Any]) -> String {
        switch name {
        case "calculate":
            guard let expr = arguments["expression"] as? String else { return "error: no expression" }
            return calculate(expr)
        case "current_datetime":
            return now()
        case "add_time":
            let start = arguments["start"] as? String ?? ""
            let h = numeric(arguments["hours"])
            let m = numeric(arguments["minutes"])
            return addTime(start: start, hours: h, minutes: m)
        default:
            return "error: unknown tool \(name)"
        }
    }

    private static func numeric(_ v: Any?) -> Int {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String { return Int(Double(s) ?? 0) }
        return 0
    }

    // MARK: - Implementations

    /// A small recursive-descent evaluator.
    ///
    /// NSExpression was the obvious choice and is the wrong one: it raises an
    /// Objective-C exception on malformed input, which Swift cannot catch, so a
    /// stray character from the model would crash the app. This parses the
    /// arithmetic itself and simply returns an error string instead.
    static func calculate(_ raw: String) -> String {
        let expr = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expr.isEmpty else { return "error: empty expression" }
        let allowed = CharacterSet(charactersIn: "0123456789.+-*/() %")
        guard expr.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return "error: only arithmetic is allowed (digits and + - * / ( ) . %)"
        }
        var p = Parser(Array(expr.replacingOccurrences(of: " ", with: "")))
        guard let v = p.parseExpression(), p.atEnd else {
            return "error: couldn't evaluate that expression"
        }
        guard v.isFinite else { return "error: result is not a finite number" }
        if abs(v.rounded() - v) < 1e-9 && abs(v) < 1e15 { return String(Int(v.rounded())) }
        return String(format: "%g", v)
    }

    private struct Parser {
        let c: [Character]
        var i = 0
        init(_ c: [Character]) { self.c = c }
        var atEnd: Bool { i >= c.count }
        private func peek() -> Character? { i < c.count ? c[i] : nil }

        mutating func parseExpression() -> Double? {          // + and -
            guard var lhs = parseTerm() else { return nil }
            while let op = peek(), op == "+" || op == "-" {
                i += 1
                guard let rhs = parseTerm() else { return nil }
                lhs = (op == "+") ? lhs + rhs : lhs - rhs
            }
            return lhs
        }

        mutating func parseTerm() -> Double? {                // * and /
            guard var lhs = parseUnary() else { return nil }
            while let op = peek(), op == "*" || op == "/" {
                i += 1
                guard let rhs = parseUnary() else { return nil }
                if op == "/" {
                    guard rhs != 0 else { return .infinity }   // reported as non-finite
                    lhs /= rhs
                } else { lhs *= rhs }
            }
            return lhs
        }

        mutating func parseUnary() -> Double? {
            if peek() == "-" { i += 1; return parseUnary().map { -$0 } }
            if peek() == "+" { i += 1; return parseUnary() }
            return parsePostfix()
        }

        mutating func parsePostfix() -> Double? {             // trailing %
            guard var v = parseAtom() else { return nil }
            while peek() == "%" { i += 1; v /= 100 }
            return v
        }

        mutating func parseAtom() -> Double? {
            if peek() == "(" {
                i += 1
                guard let v = parseExpression(), peek() == ")" else { return nil }
                i += 1
                return v
            }
            var s = ""
            var seenDot = false
            while let ch = peek(), ch.isNumber || (ch == "." && !seenDot) {
                if ch == "." { seenDot = true }
                s.append(ch); i += 1
            }
            return s.isEmpty ? nil : Double(s)
        }
    }

    static func now() -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE d MMMM yyyy 'at' HH:mm"
        let tz = TimeZone.current.localizedName(for: .standard, locale: .current) ?? TimeZone.current.identifier
        return "\(f.string(from: Date())) (\(tz))"
    }

    static func addTime(start: String, hours: Int, minutes: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        var base: Date?
        for fmt in ["h:mm a", "H:mm", "h a", "HH:mm"] {
            f.dateFormat = fmt
            if let d = f.date(from: start.trimmingCharacters(in: .whitespaces).uppercased()) { base = d; break }
        }
        guard let b = base else { return "error: couldn't read the time \"\(start)\"" }
        let out = b.addingTimeInterval(TimeInterval(hours * 3600 + minutes * 60))
        f.dateFormat = "h:mm a"
        let total = hours * 60 + minutes
        return "\(f.string(from: out))  (added \(total) minutes to \(start))"
    }
}
