import SwiftUI
import MarkdownUI

/// Shared text size for meeting content, so the summary and transcript always match.
enum ContentTypography {
    static let fontSize: CGFloat = 16
}

/// Summary renderer backed by MarkdownUI (cmark-gfm): full CommonMark + GitHub tables,
/// task lists, strikethrough and autolinks. Native SwiftUI views, no web view.
struct MarkdownView: View {
    let markdown: String

    var body: some View {
        Markdown(markdown)
            .markdownTheme(.basic)
            .markdownTextStyle { FontSize(ContentTypography.fontSize) }
            // Models put "**Heading**" and its text on consecutive lines; show them as separate lines.
            .markdownSoftBreakMode(.lineBreak)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
