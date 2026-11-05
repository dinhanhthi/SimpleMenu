import Foundation

/// One app to classify: name, bundle ID and its items' AX text, all untrusted.
struct ClassifierInput: Sendable {
    let bundleID: String
    let name: String
    let axText: [String]
}

/// Builds the classifier prompt from untrusted app text. Pure Foundation, so the hostless tests compile it.
enum PromptSanitizer {
    /// Caps on the untrusted fields, so a hostile app cannot flood the prompt.
    static let maxFieldLength = 80
    static let maxAXTextLength = 200

    /// The untrusted fields as one JSON object: the encoder quotes and escapes every value, so the text cannot
    /// break out of its string or pose as the prompt around it.
    static func prompt(for app: ClassifierInput) -> String {
        let fields = [
            "name": clean(app.name, max: maxFieldLength),
            "bundleID": clean(app.bundleID, max: maxFieldLength),
            "itemText": clean(app.axText.joined(separator: " | "), max: maxAXTextLength),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(fields)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// Drops format characters (zero-width, bidi overrides), collapses control characters and whitespace runs to
    /// one space, then caps the length.
    static func clean(_ text: String, max: Int) -> String {
        let words = text.unicodeScalars
            .filter { $0.properties.generalCategory != .format }
            .map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }
            .joined()
            .split(whereSeparator: \.isWhitespace)
        return String(words.joined(separator: " ").prefix(max))
    }
}
