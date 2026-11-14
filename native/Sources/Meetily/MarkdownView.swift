import SwiftUI

/// Small block-level Markdown renderer (headings, lists, quotes, rules, paragraphs)
/// with inline formatting handled by AttributedString.
struct MarkdownView: View {
    let markdown: String

    private enum Block: Hashable {
        case heading(Int, String)
        case bullet(Int, String)
        case numbered(Int, String, String)
        case quote(String)
        case rule
        case code(String)
        case paragraph(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text)
                .font(level == 1 ? .title.weight(.semibold) : level == 2 ? .title2.weight(.semibold) : .headline)
                .padding(.top, level == 1 ? 4 : 10)
        case .bullet(let indent, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(indent > 0 ? "◦" : "•").foregroundStyle(.secondary)
                inline(text).lineSpacing(2)
            }
            .padding(.leading, CGFloat(indent) * 18 + 4)
        case .numbered(let indent, let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(number).monospacedDigit().foregroundStyle(.secondary)
                inline(text).lineSpacing(2)
            }
            .padding(.leading, CGFloat(indent) * 18 + 4)
        case .quote(let text):
            inline(text)
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Capsule().fill(.tertiary).frame(width: 3) }
        case .rule:
            Divider().padding(.vertical, 4)
        case .code(let text):
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
        case .paragraph(let text):
            inline(text).lineSpacing(3)
        }
    }

    private func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: text, options: options) {
            return Text(attributed)
        }
        return Text(text)
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        var code: [String]?

        func flush() {
            if !paragraph.isEmpty { result.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] }
        }

        for rawLine in markdown.components(separatedBy: "\n") {
            if rawLine.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if let c = code { result.append(.code(c.joined(separator: "\n"))); code = nil } else { flush(); code = [] }
                continue
            }
            if code != nil { code?.append(rawLine); continue }

            let indent = rawLine.prefix(while: { $0 == " " || $0 == "\t" }).count / 2
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }

            if line.hasPrefix("#") {
                let level = line.prefix(while: { $0 == "#" }).count
                let text = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
                flush(); result.append(.heading(min(level, 3), text)); continue
            }
            if line == "---" || line == "***" || line == "___" { flush(); result.append(.rule); continue }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                flush(); result.append(.bullet(indent, String(line.dropFirst(2)))); continue
            }
            if let dot = line.firstIndex(where: { $0 == "." || $0 == ")" }),
               line[line.startIndex..<dot].allSatisfy(\.isNumber), dot > line.startIndex,
               line.index(after: dot) < line.endIndex, line[line.index(after: dot)] == " " {
                flush()
                result.append(.numbered(indent, String(line[...dot]), String(line[line.index(dot, offsetBy: 2)...])))
                continue
            }
            if line.hasPrefix(">") {
                flush(); result.append(.quote(line.dropFirst().trimmingCharacters(in: .whitespaces))); continue
            }
            if line.hasPrefix("|") {
                // Tables: keep rows readable, skip separator rows.
                if line.replacingOccurrences(of: "|", with: "").allSatisfy({ "-: ".contains($0) }) { continue }
                let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                flush(); result.append(.bullet(0, cells.joined(separator: "  ·  "))); continue
            }
            paragraph.append(line)
        }
        if let c = code { result.append(.code(c.joined(separator: "\n"))) }
        flush()
        return result
    }
}
