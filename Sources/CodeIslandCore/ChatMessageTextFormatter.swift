import Foundation

public enum ChatMessageTextFormatter {
    private static var markdownCache: [String: AttributedString] = [:]
    private static var blockMarkdownCache: [String: AttributedString] = [:]
    private static let markdownCacheLimit = 128

    public static func displayText(for message: ChatMessage) -> AttributedString {
        message.isUser ? literalText(message.text) : inlineMarkdown(message.text)
    }

    public static func literalText(_ text: String) -> AttributedString {
        AttributedString(text)
    }

    public static func inlineMarkdown(_ text: String) -> AttributedString {
        if let cached = markdownCache[text] { return cached }

        let result: AttributedString
        if let attr = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            result = attr
        } else {
            result = AttributedString(text)
        }

        if markdownCache.count >= markdownCacheLimit {
            markdownCache.removeAll(keepingCapacity: true)
        }
        markdownCache[text] = result
        return result
    }

    /// Full-syntax markdown (headings, lists, code blocks) for multi-line chat body rendering.
    /// Don't use in single-line previews — block elements expand vertically.
    public static func blockMarkdown(_ text: String) -> AttributedString {
        if let cached = blockMarkdownCache[text] { return cached }

        let result: AttributedString
        if let attr = try? AttributedString(
            markdown: text,
            options: .init(
                allowsExtendedAttributes: false,
                interpretedSyntax: .full,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        ) {
            result = attr
        } else {
            result = AttributedString(text)
        }

        if blockMarkdownCache.count >= markdownCacheLimit {
            blockMarkdownCache.removeAll(keepingCapacity: true)
        }
        blockMarkdownCache[text] = result
        return result
    }
}
