import Foundation

/// Parses what people type into number fields: `20+5`, `50/2`, `(10+2)*3`, `1in`, `12,5`, `2 cm`.
/// Lengths come back in millimetres; a bare number uses `defaultUnit`.
/// Angles: `parseAngle` returns radians from degrees.
enum Expression {
    static func parseLength(_ text: String, defaultUnit: LengthUnit = .mm) -> Double? {
        var p = Parser(text: text, unitScale: defaultUnit.millimetres, angles: false)
        return p.parse()
    }

    static func parseAngle(_ text: String) -> Double? {
        var p = Parser(text: text, unitScale: 1, angles: true)
        guard let deg = p.parse() else { return nil }
        return deg * .pi / 180
    }

    static func parseNumber(_ text: String) -> Double? {
        var p = Parser(text: text, unitScale: 1, angles: true)
        return p.parse()
    }

    private struct Parser {
        let chars: [Character]
        var i = 0
        let unitScale: Double
        let angles: Bool

        init(text: String, unitScale: Double, angles: Bool) {
            // A comma is a decimal separator (German/French), never a list separator here.
            let cleaned = text.replacingOccurrences(of: ",", with: ".")
                .replacingOccurrences(of: "×", with: "*")
                .replacingOccurrences(of: "÷", with: "/")
                .replacingOccurrences(of: "−", with: "-")
                .replacingOccurrences(of: "°", with: "")
            chars = Array(cleaned.lowercased())
            self.unitScale = unitScale
            self.angles = angles
        }

        mutating func parse() -> Double? {
            guard let v = expression() else { return nil }
            skipSpaces()
            return i == chars.count && v.isFinite ? v : nil
        }

        mutating func skipSpaces() { while i < chars.count, chars[i] == " " { i += 1 } }

        mutating func expression() -> Double? {
            guard var v = term() else { return nil }
            while true {
                skipSpaces()
                guard i < chars.count, chars[i] == "+" || chars[i] == "-" else { return v }
                let op = chars[i]; i += 1
                guard let r = term() else { return nil }
                v = op == "+" ? v + r : v - r
            }
        }

        mutating func term() -> Double? {
            guard var v = factor() else { return nil }
            while true {
                skipSpaces()
                guard i < chars.count, chars[i] == "*" || chars[i] == "/" else { return v }
                let op = chars[i]; i += 1
                guard let r = factor(scaled: false) else { return nil }
                if op == "/" { if r == 0 { return nil }; v /= r } else { v *= r }
            }
        }

        /// A number with an optional unit. The right side of * and / is a plain factor (no unit scale),
        /// so `50/2` is 25 mm and not 25 / 1 mm.
        mutating func factor(scaled: Bool = true) -> Double? {
            skipSpaces()
            guard i < chars.count else { return nil }
            if chars[i] == "-" { i += 1; return factor(scaled: scaled).map { -$0 } }
            if chars[i] == "+" { i += 1; return factor(scaled: scaled) }
            if chars[i] == "(" {
                i += 1
                guard let v = expression() else { return nil }
                skipSpaces()
                guard i < chars.count, chars[i] == ")" else { return nil }
                i += 1
                return v
            }
            var s = ""
            while i < chars.count, chars[i].isNumber || chars[i] == "." { s.append(chars[i]); i += 1 }
            guard let n = Double(s) else { return nil }
            skipSpaces()
            if let scale = unit() { return n * scale }
            return scaled ? n * unitScale : n
        }

        mutating func unit() -> Double? {
            if angles { return nil }
            let rest = String(chars[i...])
            for (name, mm) in [("mm", 1.0), ("cm", 10.0), ("in", 25.4), ("\"", 25.4), ("m", 1000.0)] where rest.hasPrefix(name) {
                i += name.count
                return mm
            }
            return nil
        }
    }
}
