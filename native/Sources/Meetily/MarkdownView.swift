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
        case table([[String]])
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
        case .table(let rows):
            table(rows)
        }
    }

    private func table(_ rows: [[String]]) -> some View {
        let columns = rows.map(\.count).max() ?? 0
        return ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .topLeading, horizontalSpacing: 18, verticalSpacing: 8) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    GridRow {
                        ForEach(0..<columns, id: \.self) { c in
                            inline(c < row.count ? row[c] : "")
                                .fontWeight(i == 0 ? .semibold : .regular)
                                .foregroundStyle(i == 0 ? .secondary : .primary)
                                .frame(minWidth: 40, maxWidth: 320, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if i == 0 { Divider().gridCellUnsizedAxes(.horizontal) }
                }
            }
            .padding(12)
        }
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 10))
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
        var tableRows: [[String]] = []

        func flushTable() {
            if !tableRows.isEmpty { result.append(.table(tableRows)); tableRows = [] }
        }
        func flush() {
            // Each source line stays its own line (models put "**Heading**" and its text on
            // consecutive lines and expect them shown separately).
            if !paragraph.isEmpty { result.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
            flushTable()
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
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") || line.hasPrefix("• ") {
                var item = String(line.dropFirst(2))
                if item.hasPrefix("[ ] ") { item = "☐ " + item.dropFirst(4) }
                else if item.lowercased().hasPrefix("[x] ") { item = "☑ " + item.dropFirst(4) }
                flush(); result.append(.bullet(indent, item)); continue
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
                if !paragraph.isEmpty { let t = tableRows; tableRows = []; flush(); tableRows = t }
                // Separator row (| --- | :-: |) only marks the header.
                if line.replacingOccurrences(of: "|", with: "").allSatisfy({ "-: ".contains($0) }) { continue }
                var body = Substring(line).dropFirst()
                if body.hasSuffix("|") { body = body.dropLast() }
                tableRows.append(body.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) })
                continue
            }
            flushTable()
            paragraph.append(line)
        }
        if let c = code { result.append(.code(c.joined(separator: "\n"))) }
        flush()
        return result
    }
}
