import SwiftUI
import MarkdownUI

/// Summary renderer backed by MarkdownUI (cmark-gfm): full CommonMark + GitHub tables,
/// task lists, strikethrough and autolinks, styled to sit on the window background.
struct MarkdownView: View {
    let markdown: String

    var body: some View {
        Markdown(markdown)
            .markdownTheme(.gitHub)
            // Models put "**Heading**" and its text on consecutive lines; show them as separate lines.
            .markdownSoftBreakMode(.lineBreak)
            .markdownTextStyle {
                ForegroundColor(.primary)
                BackgroundColor(nil)
                FontSize(14)
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
