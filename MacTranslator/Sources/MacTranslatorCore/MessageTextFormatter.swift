import Foundation

public enum MessageTextFormatter {
    public static func format(_ source: String) -> AttributedString {
        let normalizedSource = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(normalizeHeading)
            .joined(separator: "\n")
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: normalizedSource, options: options))
            ?? AttributedString(source)
    }

    private static func normalizeHeading(_ line: Substring) -> String {
        let markerCount = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(markerCount) else { return String(line) }

        let contentStart = line.index(line.startIndex, offsetBy: markerCount)
        guard contentStart < line.endIndex, line[contentStart] == " " else {
            return String(line)
        }

        let heading = String(line[line.index(after: contentStart)...])
        if heading.hasPrefix("**"), heading.hasSuffix("**") {
            return heading
        }
        return "**\(heading)**"
    }
}
