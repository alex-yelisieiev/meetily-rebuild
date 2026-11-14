import SwiftUI
import MarkdownUI

/// Summary renderer backed by MarkdownUI (cmark-gfm): full CommonMark + GitHub tables,
/// task lists, strikethrough and autolinks. Native SwiftUI views, no web view.
struct MarkdownView: View {
    let markdown: String

    var body: some View {
        Markdown(markdown)
            .markdownTheme(.basic)
            // Models put "**Heading**" and its text on consecutive lines; show them as separate lines.
            .markdownSoftBreakMode(.lineBreak)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
