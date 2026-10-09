import SwiftUI
import UIKit

/// Native rendering of a mirrored Cursor IDE chat: markdown replies, tool rows,
/// questionnaires answerable from the phone, and a message composer.
struct IDEChatView: View {
    @ObservedObject var workspace: TerminalWorkspace
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    private var canSend: Bool { workspace.connectionState == .connected }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if workspace.ideMessages.isEmpty {
                            placeholder
                        }
                        ForEach(workspace.ideMessages) { message in
                            IDEChatRow(message: message, canAnswer: canSend) { id, answers in
                                workspace.answerIDEQuestion(id, answers: answers)
                            }
                            .id(message.idx)
                        }
                        ForEach(Array(workspace.idePendingSends.enumerated()), id: \.offset) { _, text in
                            IDEUserBubble(text: text, pending: true)
                        }
                        Color.clear.frame(height: 1).id(Self.bottomID)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: workspace.ideMessages.last) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                }
                .onChange(of: workspace.idePendingSends.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                }
            }
            Divider()
            composer
        }
    }

    private static let bottomID = "ide-chat-bottom"

    @ViewBuilder
    private var placeholder: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(String(localized: "Loading conversation…"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
                TextField(String(localized: "Message Cursor…"), text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($composerFocused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                Button {
                    workspace.sendIDEMessage(draft)
                    draft = ""
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                }
                .disabled(!canSend || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel(String(localized: "Send"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private struct IDEChatRow: View {
    let message: IDEChatMessage
    let canAnswer: Bool
    let onAnswer: (String, [IDEChatMessage.Answer]) -> Void

    var body: some View {
        switch message.role {
        case .user:
            IDEUserBubble(text: message.text ?? "", pending: false)
        case .assistant:
            MarkdownBlocksView(text: message.text ?? "")
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            if let tool = message.tool { IDEToolRow(tool: tool) }
        case .question:
            if let question = message.question {
                IDEQuestionCard(question: question, canAnswer: canAnswer, onAnswer: onAnswer)
                    .id(question.toolCallId + question.status)
            }
        }
    }
}

private struct IDEUserBubble: View {
    let text: String
    let pending: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            Spacer(minLength: 40)
            if pending {
                Image(systemName: "clock")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(text)
                .font(.body)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(pending ? 0.08 : 0.15), in: RoundedRectangle(cornerRadius: 14))
                .opacity(pending ? 0.6 : 1)
        }
    }
}

private struct IDEToolRow: View {
    let tool: IDEChatMessage.Tool

    var body: some View {
        HStack(spacing: 6) {
            statusIcon
                .frame(width: 14)
            Text(tool.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let summary = tool.summary, !summary.isEmpty {
                Text(verbatim: summary)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch tool.status ?? "" {
        case "completed", "success":
            Image(systemName: "checkmark").font(.caption2.weight(.bold)).foregroundStyle(.green)
        case "error", "failed":
            Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(.red)
        case "cancelled", "rejected", "aborted":
            Image(systemName: "minus").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
        default:
            ProgressView().controlSize(.mini)
        }
    }
}

private struct IDEQuestionCard: View {
    let question: IDEChatMessage.Question
    let canAnswer: Bool
    let onAnswer: (String, [IDEChatMessage.Answer]) -> Void

    @State private var selected: [String: Set<String>] = [:]
    @State private var freeform: [String: String] = [:]
    @State private var submitted = false

    private var editable: Bool { question.isOpen && !submitted }

    private var answers: [IDEChatMessage.Answer] {
        question.questions.compactMap { item in
            let ids = item.options.map(\.id).filter { selected[item.id]?.contains($0) == true }
            let text = freeform[item.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !ids.isEmpty || !text.isEmpty else { return nil }
            return IDEChatMessage.Answer(questionId: item.id, selectedOptionIds: ids, freeformText: text.isEmpty ? nil : text)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.bubble")
                    .foregroundStyle(Color.accentColor)
                Text(question.title?.isEmpty == false ? question.title! : String(localized: "Questions"))
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                statusLabel
            }
            ForEach(question.questions) { item in
                questionItem(item)
            }
            if editable {
                Button {
                    submitted = true
                    onAnswer(question.toolCallId, answers)
                } label: {
                    Text(String(localized: "Submit"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canAnswer || answers.isEmpty)
            }
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(editable ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch (question.status, submitted) {
        case ("pending", false):
            Text(String(localized: "Waiting for your answer")).font(.caption).foregroundStyle(Color.accentColor)
        case ("pending", true):
            Text(String(localized: "Sending…")).font(.caption).foregroundStyle(.secondary)
        case ("cancelled", _):
            Text(String(localized: "Skipped")).font(.caption).foregroundStyle(.secondary)
        default:
            Text(String(localized: "Answered")).font(.caption).foregroundStyle(.green)
        }
    }

    private func questionItem(_ item: IDEChatMessage.QuestionItem) -> some View {
        let multiple = item.allowMultiple == true
        let answered = question.answers?.first(where: { $0.questionId == item.id })
        return VStack(alignment: .leading, spacing: 6) {
            Text(item.prompt)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            if editable, multiple {
                Text(String(localized: "Choose any"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ForEach(item.options) { option in
                let isOn = editable
                    ? selected[item.id]?.contains(option.id) == true
                    : answered?.selectedOptionIds.contains(option.id) == true
                Button {
                    toggle(option.id, in: item.id, multiple: multiple)
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: multiple
                              ? (isOn ? "checkmark.square.fill" : "square")
                              : (isOn ? "largecircle.fill.circle" : "circle"))
                            .foregroundStyle(isOn ? Color.accentColor : .secondary)
                        Text(option.label)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!editable)
                .opacity(editable || isOn ? 1 : 0.5)
            }
            if editable {
                TextField(String(localized: "Other…"), text: Binding(
                    get: { freeform[item.id] ?? "" },
                    set: { freeform[item.id] = $0 }
                ), axis: .vertical)
                .font(.subheadline)
                .textFieldStyle(.roundedBorder)
            } else if let text = answered?.freeformText, !text.isEmpty {
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func toggle(_ optionID: String, in questionID: String, multiple: Bool) {
        var set = selected[questionID] ?? []
        if set.contains(optionID) {
            set.remove(optionID)
        } else {
            if !multiple { set.removeAll() }
            set.insert(optionID)
        }
        selected[questionID] = set
    }
}

// MARK: - Markdown

/// Block-level markdown (headings, lists, quotes, fenced code, tables) with inline styling
/// from `AttributedString(markdown:)`.
struct MarkdownBlocksView: View {
    let text: String

    var body: some View {
        let blocks = MarkdownBlock.parse(text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let content):
            Text(Self.inline(content))
                .font(level <= 1 ? .title3.weight(.bold) : level == 2 ? .headline : .subheadline.weight(.semibold))
                .padding(.top, 4)
        case .paragraph(let content):
            Text(Self.inline(content))
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        case .list(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.marker)
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(Self.inline(item.text))
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.depth) * 16)
                }
            }
        case .quote(let content):
            Text(Self.inline(content))
                .font(.body)
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 3)
                }
        case .code(let language, let code):
            VStack(alignment: .leading, spacing: 0) {
                if !language.isEmpty {
                    Text(verbatim: language)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.top, 6)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(verbatim: code)
                        .font(.system(.footnote, design: .monospaced))
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(10)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
        case .table(let header, let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                            tableCell(cell, bold: true)
                        }
                    }
                    .background(Color(uiColor: .tertiarySystemFill))
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        Divider()
                        GridRow {
                            ForEach(0..<header.count, id: \.self) { col in
                                tableCell(col < row.count ? row[col] : "", bold: false)
                            }
                        }
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
            }
        case .rule:
            Divider()
        }
    }

    private func tableCell(_ content: String, bold: Bool) -> some View {
        Text(Self.inline(content))
            .font(bold ? .footnote.weight(.semibold) : .footnote)
            .frame(maxWidth: 260, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
    }

    static func inline(_ source: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var result = (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
        for run in result.runs where run.inlinePresentationIntent?.contains(.code) == true {
            result[run.range].font = .system(.callout, design: .monospaced)
            result[run.range].backgroundColor = Color(uiColor: .tertiarySystemFill)
        }
        return result
    }
}

enum MarkdownBlock: Equatable {
    struct ListItem: Equatable {
        var marker: String
        var text: String
        var depth: Int
    }

    case heading(Int, String)
    case paragraph(String)
    case list([ListItem])
    case quote(String)
    case code(String, String)
    case table([String], [[String]])
    case rule

    static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var i = 0

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i])
                    i += 1
                }
                blocks.append(.code(language, code.joined(separator: "\n")))
                i += 1
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                i += 1
                continue
            }
            if let heading = headingLevel(trimmed) {
                flushParagraph()
                blocks.append(.heading(heading, trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
                i += 1
                continue
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                blocks.append(.rule)
                i += 1
                continue
            }
            if trimmed.hasPrefix("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flushParagraph()
                let header = tableCells(trimmed)
                var rows: [[String]] = []
                i += 2
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(tableCells(lines[i].trimmingCharacters(in: .whitespaces)))
                    i += 1
                }
                blocks.append(.table(header, rows))
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quote: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quote.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.quote(quote.joined(separator: "\n")))
                continue
            }
            if listItem(line) != nil {
                flushParagraph()
                var items: [ListItem] = []
                while i < lines.count {
                    if let item = listItem(lines[i]) {
                        items.append(item)
                    } else if !lines[i].trimmingCharacters(in: .whitespaces).isEmpty,
                              lines[i].hasPrefix("  "), !items.isEmpty {
                        items[items.count - 1].text += " " + lines[i].trimmingCharacters(in: .whitespaces)
                    } else {
                        break
                    }
                    i += 1
                }
                blocks.append(.list(items))
                continue
            }
            paragraph.append(line)
            i += 1
        }
        flushParagraph()
        return blocks
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private static func listItem(_ line: String) -> ListItem? {
        let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).count
        let body = line.dropFirst(indent)
        let depth = min(indent / 2, 4)
        for bullet in ["- [ ] ", "- [x] ", "- [X] "] where body.hasPrefix(bullet) {
            return ListItem(marker: bullet.contains("[ ]") ? "☐" : "☑", text: String(body.dropFirst(bullet.count)), depth: depth)
        }
        if body.hasPrefix("- ") || body.hasPrefix("* ") || body.hasPrefix("+ ") {
            return ListItem(marker: "•", text: String(body.dropFirst(2)), depth: depth)
        }
        let digits = body.prefix(while: \.isNumber)
        if !digits.isEmpty, digits.count <= 3 {
            let rest = body.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
                return ListItem(marker: digits + ".", text: String(rest.dropFirst(2)), depth: depth)
            }
        }
        return nil
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|"), trimmed.contains("-") else { return false }
        return trimmed.allSatisfy { "|-: ".contains($0) }
    }

    private static func tableCells(_ line: String) -> [String] {
        var body = Substring(line)
        if body.hasPrefix("|") { body = body.dropFirst() }
        if body.hasSuffix("|") { body = body.dropLast() }
        return body.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
