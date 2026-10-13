import SwiftUI
import UIKit

/// Native rendering of a mirrored Cursor IDE chat: markdown replies, tool rows,
/// questionnaires answerable from the phone, and a message composer.
struct IDEChatView: View {
    @ObservedObject var workspace: TerminalWorkspace
    /// Read-only subagent composer (parent session stays attached).
    var subComposerId: String? = nil
    var readOnly: Bool = false
    /// True while a sheet (model search, and so on) is using the keyboard.
    var suspendComposerAutofocus: Bool = false

    @State private var draft = ""
    @State private var queueEditing = false
    @State private var queueEscapeTick = 0
    @FocusState private var composerFocused: Bool

    private var canSend: Bool { !readOnly && workspace.connectionState == .connected }

    private var messages: [IDEChatMessage] {
        if let subComposerId {
            return workspace.ideSubMessages[subComposerId] ?? []
        }
        return workspace.ideMessages
    }

    private var isGenerating: Bool {
        if workspace.ideState?.generating == true { return true }
        // subChats is already filtered to agents that are still running.
        return !(workspace.ideState?.subChats?.isEmpty ?? true)
    }

    /// Pending sends that are not already listed in the follow-up queue (avoids a
    /// duplicate bubble + queue row for the same text while delivery confirms).
    private var visiblePendingSends: [String] {
        let queued = workspace.ideState?.queued ?? []
        guard !queued.isEmpty else { return workspace.idePendingSends }
        return workspace.idePendingSends.filter { pending in
            let p = pending.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return !queued.contains { item in
                let q = item.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                return !p.isEmpty && !q.isEmpty && (p == q || p.contains(q) || q.contains(p))
            }
        }
    }

    /// Cursor shows a shimmering “Planning next moves” while the turn is live but
    /// there is still no tool row / assistant prose to look at. Without it the phone
    /// looks frozen right after send.
    private var shouldShowPlanning: Bool {
        guard !readOnly else { return false }
        let trailing = Array(messages.reversed().prefix(while: { $0.role != .user }).reversed())
        if trailing.contains(where: { $0.tool?.isRunning == true }) { return false }
        if trailing.contains(where: { $0.question?.isOpen == true }) { return false }
        if trailing.contains(where: {
            $0.role == .assistant && !($0.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }) {
            return false
        }
        return isGenerating || !workspace.idePendingSends.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if messages.isEmpty {
                            placeholder
                        }
                        ForEach(groupIDEMessages(messages, showFooter: !readOnly, generating: isGenerating)) { item in
                            switch item.kind {
                            case .notices(let notices):
                                IDENoticeGroup(messages: notices)
                                    .id(item.id)
                            case .message(let message):
                                IDEChatRow(
                                    message: message,
                                    canAnswer: canSend
                                ) { id, answers in
                                    workspace.answerIDEQuestion(id, answers: answers)
                                } onToolAction: { op, bubbleId, toolCallId, name in
                                    workspace.sendIDEToolAction(op, bubbleId: bubbleId, toolCallId: toolCallId, name: name)
                                }
                                .id(item.id)
                            case .turnFooter(let footer):
                                IDEAssistantTurnFooter(text: footer.text, createdAt: footer.createdAt) {
                                    workspace.forkIDEMessage(bubbleId: footer.bubbleId)
                                }
                                .id(item.id)
                            }
                        }
                        // Hide "waiting" bubbles once Cursor has parked the same text in the queue.
                        ForEach(Array(visiblePendingSends.enumerated()), id: \.offset) { _, text in
                            IDEUserBubble(text: text, pending: true)
                        }
                        if shouldShowPlanning {
                            IDEShimmerText(text: String(localized: "Planning next moves"), font: .footnote)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityLabel(String(localized: "Planning next moves"))
                                .id("ide-planning")
                        }
                        Color.clear.frame(height: 28).id(Self.bottomID)
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                }
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.never)
                .onAppear { scrollToBottom(proxy) }
                .onChange(of: scrollToken) { _, _ in
                    scrollToBottom(proxy)
                }
                .onChange(of: composerFocused) { _, focused in
                    if focused { scrollToBottom(proxy) }
                }
            }
            if !readOnly {
                if let hint = workspace.ideState?.actionError, !hint.isEmpty {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                }
                if let queued = workspace.ideState?.queued, !queued.isEmpty {
                    IDEQueuedMessagesBar(
                        messages: queued,
                        escapeTick: queueEscapeTick,
                        onUpdate: { workspace.updateIDEQueuedMessage(id: $0, text: $1) },
                        onRemove: { workspace.removeIDEQueuedMessage(id: $0) },
                        onSubmit: { workspace.submitIDEQueuedMessage(id: $0) },
                        onEditingChange: { queueEditing = $0 }
                    )
                }
                Divider()
                composer
            }
        }
        .onAppear {
            if let subComposerId { workspace.watchIDESubChat(subComposerId) }
            reclaimComposerFocus()
        }
        .onDisappear {
            if let subComposerId { workspace.unwatchIDESubChat(subComposerId) }
        }
        .onChange(of: workspace.connectionState) { _, _ in
            reclaimComposerFocus()
        }
        .onChange(of: suspendComposerAutofocus) { _, suspended in
            if suspended { composerFocused = false }
        }
    }

    /// Keep the session keyboard up, except while another field (model search, queue edit) owns it.
    private func reclaimComposerFocus() {
        guard !readOnly, !suspendComposerAutofocus, !queueEditing else { return }
        if !composerFocused { composerFocused = true }
    }

    private func handleComposerEscape() -> KeyPress.Result {
        if queueEditing {
            queueEscapeTick += 1
            return .handled
        }
        if let queued = workspace.ideState?.queued, !queued.isEmpty {
            workspace.cancelIDEQueuedMessages()
            return .handled
        }
        return .ignored
    }

    private static let bottomID = "ide-chat-bottom"

    private var scrollToken: String {
        let rows = messages.map { message in
            [
                String(message.idx),
                message.role.rawValue,
                String(message.text?.count ?? 0),
                message.tool?.status ?? "",
                String(message.tool?.output?.count ?? 0),
                String(message.tool?.diff?.lines.count ?? 0),
                message.question?.status ?? "",
            ].joined(separator: ":")
        }.joined(separator: "|")
        return "\(rows)-\(workspace.idePendingSends.count)-\(isGenerating)-\(shouldShowPlanning)-\(workspace.isIDETurnBusy)"
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        proxy.scrollTo(Self.bottomID, anchor: .bottom)
        DispatchQueue.main.async {
            proxy.scrollTo(Self.bottomID, anchor: .bottom)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            proxy.scrollTo(Self.bottomID, anchor: .bottom)
        }
        // The keyboard's safe-area animation finishes after the first layout passes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            proxy.scrollTo(Self.bottomID, anchor: .bottom)
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        IDEShimmerText(text: String(localized: "Loading conversation…"), font: .subheadline)
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
                TextField(String(localized: "Message Cursor…"), text: $draft, axis: .vertical)
                    .lineLimit(1...3)
                    .focused($composerFocused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                    .onKeyPress(.escape, action: handleComposerEscape)
                    .onChange(of: composerFocused) { _, focused in
                        if !focused {
                            DispatchQueue.main.async { reclaimComposerFocus() }
                        }
                    }
                // Align with Cursor: typed text → Send (queues while busy); empty + busy → Stop.
                let hasDraft = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if workspace.isIDETurnBusy && !hasDraft {
                    Button {
                        workspace.stopIDEGeneration()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(.red)
                    }
                    .disabled(!canSend)
                    .accessibilityLabel(String(localized: "Stop"))
                } else {
                    Button {
                        workspace.sendIDEMessage(draft)
                        draft = ""
                        composerFocused = true
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30))
                    }
                    .disabled(!canSend || !hasDraft)
                    .accessibilityLabel(String(localized: "Send"))
                }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private enum IDEChatStyle {
    static let prose = Font.system(size: 15)
    static let heading1 = Font.system(size: 18, weight: .semibold)
    static let heading2 = Font.system(size: 16, weight: .semibold)
    static let heading3 = Font.system(size: 15, weight: .semibold)
}

private struct IDETurnFooter {
    var text: String
    var createdAt: String?
    var bubbleId: String
}

private struct IDEChatItem: Identifiable {
    enum Kind {
        case message(IDEChatMessage)
        case notices([IDEChatMessage])
        /// One copy/fork row for a finished question-and-answer, after every paragraph and tool.
        case turnFooter(IDETurnFooter)
    }
    let kind: Kind
    let id: String
}

/// Cursor draws Copy and Fork once, on a turn-actions row after the whole answer.
/// A turn is one user message plus everything until the next user message.
/// The row is omitted while that turn is still running: composer generating, a
/// tool still open, or a question waiting. Composer status alone is not enough —
/// a live tool is often `loading` while `status` stays `aborted`.
private func groupIDEMessages(_ messages: [IDEChatMessage], showFooter: Bool, generating: Bool) -> [IDEChatItem] {
    var items: [IDEChatItem] = []
    var notices: [IDEChatMessage] = []
    var prose: [IDEChatMessage] = []
    var turnWorking = false

    func flushNotices() {
        guard !notices.isEmpty else { return }
        items.append(IDEChatItem(
            kind: .notices(notices),
            id: "notice-\(notices.first!.idx)-\(notices.last!.idx)"
        ))
        notices = []
    }

    func flushFooter(trailing: Bool) {
        let working = turnWorking
        defer {
            prose = []
            turnWorking = false
        }
        guard showFooter, !prose.isEmpty, !(trailing && (generating || working)) else { return }
        let parts = prose.compactMap { message -> String? in
            let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? nil : text
        }
        guard let last = prose.last, !parts.isEmpty else { return }
        items.append(IDEChatItem(
            kind: .turnFooter(IDETurnFooter(
                text: parts.joined(separator: "\n\n"),
                createdAt: last.createdAt,
                bubbleId: last.bubbleId
            )),
            id: "turn-footer-\(prose.first!.idx)-\(last.idx)"
        ))
    }

    for message in messages {
        switch message.role {
        case .notice:
            notices.append(message)
        case .user:
            flushNotices()
            flushFooter(trailing: false)
            items.append(IDEChatItem(kind: .message(message), id: "msg-\(message.idx)"))
        default:
            flushNotices()
            if message.tool?.isRunning == true || message.question?.isOpen == true {
                turnWorking = true
            }
            items.append(IDEChatItem(kind: .message(message), id: "msg-\(message.idx)"))
            if message.role == .assistant {
                let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !text.isEmpty { prose.append(message) }
            }
        }
    }
    flushNotices()
    flushFooter(trailing: true)
    return items
}

/// Cursor collapses consecutive background-task notices into one “Finished N background tasks” row.
private struct IDENoticeGroup: View {
    let messages: [IDEChatMessage]
    @State private var expanded = false

    private var title: String {
        let count = messages.count
        return count == 1
            ? String(localized: "Finished 1 background task")
            : String(format: String(localized: "Finished %lld background tasks"), count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text(title)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                    Spacer(minLength: 0)
                }
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(messages) { message in
                        Text(message.text?.isEmpty == false ? message.text! : String(localized: "Background task"))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.leading, 14)
            }
        }
    }
}

private struct IDEChatRow: View {
    let message: IDEChatMessage
    let canAnswer: Bool
    let onAnswer: (String, [IDEChatMessage.Answer]) -> Void
    let onToolAction: (String, String, String?, String?) -> Void

    var body: some View {
        switch message.role {
        case .user:
            IDEUserBubble(text: message.text ?? "", pending: false)
        case .assistant:
            MarkdownBlocksView(text: message.text ?? "")
                .frame(maxWidth: .infinity, alignment: .leading)
        case .thought:
            IDEThoughtRow(text: message.text ?? "", durationMs: message.durationMs ?? 0)
        case .notice:
            IDENoticeGroup(messages: [message])
        case .tool:
            if let tool = message.tool {
                if tool.name.hasPrefix("run_terminal") {
                    IDEShellCard(bubbleId: message.bubbleId, tool: tool, onAction: onToolAction)
                } else if tool.diff != nil {
                    IDEFileDiffCard(bubbleId: message.bubbleId, tool: tool, onAction: onToolAction)
                } else {
                    IDEToolRow(tool: tool)
                }
            }
        case .question:
            if let question = message.question {
                IDEQuestionCard(question: question, canAnswer: canAnswer, onAnswer: onAnswer)
                    .id(question.toolCallId + question.status)
            }
        }
    }
}

private struct IDEAssistantTurnFooter: View {
    let text: String
    let createdAt: String?
    var onFork: (() -> Void)?
    @State private var copied = false

    var body: some View {
        HStack(spacing: 4) {
            Button {
                let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { return }
                UIPasteboard.general.string = value
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "square.on.square")
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(String(localized: "Copy"))

            Button {
                onFork?()
            } label: {
                Image(systemName: "arrow.triangle.branch")
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(String(localized: "Fork Chat"))

            if let stamp = IDERelativeTime.agoLabel(createdAt) {
                Text(stamp)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
}

enum IDERelativeTime {
    static func agoLabel(_ iso: String?) -> String? {
        guard let iso, !iso.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
        guard let date else { return nil }
        let seconds = max(1, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86_400)d ago"
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
                .font(IDEChatStyle.prose)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(pending ? 0.08 : 0.15), in: RoundedRectangle(cornerRadius: 14))
                .opacity(pending ? 0.6 : 1)
        }
    }
}

/// "Thought briefly / Thought for 7s", expandable to the reasoning text like the IDE.
private struct IDEThoughtRow: View {
    let text: String
    let durationMs: Int
    @State private var expanded = false

    private var title: String {
        let seconds = Int((Double(durationMs) / 1000).rounded())
        return seconds < 2
            ? String(localized: "Thought briefly")
            : String(format: String(localized: "Thought for %llds"), seconds)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                guard !text.isEmpty else { return }
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text(title)
                    if !text.isEmpty {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: 2)
                    }
                    .textSelection(.enabled)
            }
        }
    }
}

/// One-line tool call in the IDE's muted style: verb + target, no tick once done.
private struct IDEToolRow: View {
    let tool: IDEChatMessage.Tool

    private static let pathTools: Set<String> = ["read_file", "edit_file", "delete_file", "search_replace", "write"]

    private var verb: String {
        if tool.name == "await" {
            return tool.isRunning ? String(localized: "Waiting for shell") : String(localized: "Waited for shell")
        }
        return tool.label
    }

    private var target: String {
        guard tool.name != "await", let summary = tool.summary, !summary.isEmpty else { return "" }
        if Self.pathTools.contains(tool.name) {
            return (summary as NSString).lastPathComponent
        }
        return tool.title?.isEmpty == false ? tool.title! : summary
    }

    var body: some View {
        HStack(spacing: 5) {
            if !tool.isRunning {
                Text(verb)
                    .foregroundStyle(.secondary)
            }
            if !target.isEmpty {
                Text(verbatim: target)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if tool.isRunning {
                IDEShimmerText(text: verb, font: .footnote)
                    .frame(maxWidth: 120, alignment: .leading)
            } else if tool.isFailed {
                Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(.red)
            }
            Spacer(minLength: 0)
        }
        .font(.footnote)
    }
}

/// Shell call as an IDE-style card: collapsed by default, natural height capped for long logs.
private struct IDEShellCard: View {
    let bubbleId: String
    let tool: IDEChatMessage.Tool
    let onAction: (String, String, String?, String?) -> Void
    @State private var expanded = false
    @State private var followsBottom = false
    @State private var followArmed = false
    @State private var expandedContentHeight: CGFloat = 44
    @AppStorage("koko.ide.autoRunMode") private var autoRunMode = "runEverything"

    private var command: String { tool.summary ?? "" }
    private var header: String { tool.title?.isEmpty == false ? tool.title! : command }
    private var output: String { tool.output ?? "" }
    private var outputTail: String {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(6).joined(separator: "\n")
    }
    private static let collapsedLogMaxHeight: CGFloat = 84
    private static let expandedLogMaxHeight: CGFloat = 190
    private static let topID = "shell-output-top"
    private static let bottomID = "shell-output-bottom"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button(action: toggleExpanded) {
                    HStack(spacing: 6) {
                        Image(systemName: expanded ? "chevron.down" : "terminal")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 14)
                        Group {
                            if tool.isRunning {
                                IDEShimmerText(text: header, font: .footnote.weight(.medium))
                                    .lineLimit(1)
                            } else {
                                Text(verbatim: header)
                                    .font(.footnote.weight(.medium))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .foregroundStyle(.primary)
                            }
                        }
                        Spacer(minLength: 0)
                        if tool.isFailed {
                            Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(.red)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Menu {
                    Section(String(localized: "Auto-Run")) {
                        autoRunItem(
                            id: "allowlist",
                            title: String(localized: "Allowlist"),
                            subtitle: String(localized: "Automatically run operations after you approve them once")
                        )
                        autoRunItem(
                            id: "allowlistSandbox",
                            title: String(localized: "Allowlist (with Sandbox)"),
                            subtitle: String(localized: "Tools will auto-run in a sandbox if possible, otherwise respect the allowlist or ask for approval")
                        )
                        autoRunItem(
                            id: "autoReviewSandbox",
                            title: String(localized: "Auto-review (with Sandbox)"),
                            subtitle: String(localized: "Automatically run operations that Auto-review classifies as safe, using sandboxing when possible")
                        )
                        autoRunItem(
                            id: "runEverything",
                            title: String(localized: "Run Everything (Unsandboxed)"),
                            subtitle: String(localized: "Automatically run all operations without asking")
                        )
                    }
                    Button(String(localized: "Copy Command")) {
                        UIPasteboard.general.string = command.isEmpty ? header : command
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            if !output.isEmpty {
                Divider()
                Group {
                    if expanded {
                        ScrollViewReader { proxy in
                            ScrollView(.vertical) {
                                shellBody(text: output, showCommand: true)
                                    .id(Self.topID)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .background {
                                        GeometryReader { geometry in
                                            Color.clear.preference(
                                                key: IDEShellContentHeightKey.self,
                                                value: geometry.size.height
                                            )
                                        }
                                    }
                                Color.clear
                                    .frame(width: 1, height: 1)
                                    .id(Self.bottomID)
                                    .background {
                                        GeometryReader { geometry in
                                            Color.clear.preference(
                                                key: IDEShellBottomOffsetKey.self,
                                                value: geometry.frame(in: .named("ide-shell-scroll")).maxY
                                            )
                                        }
                                    }
                            }
                            .frame(height: min(expandedContentHeight, Self.expandedLogMaxHeight))
                            .coordinateSpace(name: "ide-shell-scroll")
                            .defaultScrollAnchor(.top)
                            .onAppear { scrollExpandedToCommand(proxy) }
                            .onChange(of: output) { _, _ in
                                guard followsBottom else { return }
                                proxy.scrollTo(Self.bottomID, anchor: .bottom)
                            }
                            .onPreferenceChange(IDEShellContentHeightKey.self) { height in
                                guard height > 0 else { return }
                                expandedContentHeight = height
                            }
                            .onPreferenceChange(IDEShellBottomOffsetKey.self) { bottomY in
                                guard followArmed, bottomY > 0 else { return }
                                followsBottom = bottomY <= min(expandedContentHeight, Self.expandedLogMaxHeight) + 12
                            }
                        }
                    } else {
                        shellBody(text: outputTail, showCommand: false)
                            .lineLimit(6)
                            .frame(maxWidth: .infinity, maxHeight: Self.collapsedLogMaxHeight, alignment: .bottom)
                            .clipped()
                    }
                }
                .background(Color(uiColor: .tertiarySystemFill))
                .contentShape(Rectangle())
                .onTapGesture { toggleExpanded() }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.25)))
    }

    private func autoRunItem(id: String, title: String, subtitle: String) -> some View {
        Button {
            autoRunMode = id
            onAction("toolAutoRun", bubbleId, nil, id)
        } label: {
            if autoRunMode == id {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
            Text(subtitle)
        }
    }

    private func shellBody(text: String, showCommand: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if showCommand, !command.isEmpty {
                Text(IDESyntaxHighlighter.highlight("$ " + command, language: "shell"))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !text.isEmpty {
                Text(verbatim: text)
                    .foregroundStyle(.secondary.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(.caption2, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
    }

    private func scrollExpandedToCommand(_ proxy: ScrollViewProxy) {
        followsBottom = false
        followArmed = false
        proxy.scrollTo(Self.topID, anchor: .top)
        DispatchQueue.main.async {
            followsBottom = false
            proxy.scrollTo(Self.topID, anchor: .top)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            followArmed = true
        }
    }

    private func toggleExpanded() {
        if !expanded {
            followsBottom = false
            followArmed = false
        }
        withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
        onAction(expanded ? "toolDetail" : "toolCollapse", bubbleId, tool.toolCallId, nil)
    }
}

/// IDE-style loading copy: dim text with a bright band sweeping left → right.
private struct IDEShimmerText: View {
    let text: String
    var font: Font = .footnote

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let phase = (t.truncatingRemainder(dividingBy: 1.6)) / 1.6
            Text(text)
                .font(font)
                .foregroundStyle(.secondary.opacity(0.55))
                .overlay {
                    GeometryReader { geo in
                        let w = max(geo.size.width, 1)
                        LinearGradient(
                            colors: [.clear, Color.primary.opacity(0.92), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: w * 0.45)
                        .offset(x: (w * 1.35) * phase - w * 0.45)
                    }
                    .mask(Text(text).font(font))
                }
        }
    }
}

/// Queued follow-ups, laid out like Cursor: collapsed to a short preview, tap to show
/// the whole message, with edit / send-now / delete on the trailing edge.
private struct IDEQueueHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct IDEQueuedMessagesBar: View {
    let messages: [IDEChatState.Queued]
    let escapeTick: Int
    let onUpdate: (String, String) -> Void
    let onRemove: (String) -> Void
    let onSubmit: (String) -> Void
    let onEditingChange: (Bool) -> Void

    @State private var expandedIDs: Set<String> = []
    @State private var editingID: String?
    @State private var editDraft = ""
    @State private var contentHeight: CGFloat = 36
    @FocusState private var editFocused: Bool

    /// Every queued item shares this strip. Extra items scroll inside it.
    private static let regionMaxHeight: CGFloat = 120

    private var overflows: Bool { contentHeight > Self.regionMaxHeight + 1 }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(messages.enumerated()), id: \.element.id) { index, item in
                    queuedRow(item)
                    if index < messages.count - 1 {
                        Divider().padding(.leading, 18)
                    }
                }
            }
            .background {
                GeometryReader { geo in
                    Color.clear.preference(key: IDEQueueHeightKey.self, value: geo.size.height)
                }
            }
        }
        .frame(height: min(max(contentHeight, 32), Self.regionMaxHeight))
        .onPreferenceChange(IDEQueueHeightKey.self) { contentHeight = $0 }
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            if overflows {
                VStack(spacing: 0) {
                    queueFade(top: true)
                    Spacer(minLength: 0)
                    queueFade(top: false)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .allowsHitTesting(false)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.22)))
        .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: -3)
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 2)
        .onChange(of: editingID) { _, id in
            onEditingChange(id != nil)
        }
        .onChange(of: escapeTick) { _, _ in
            editingID = nil
            editFocused = false
        }
        .onDisappear { onEditingChange(false) }
    }

    /// Soft edge so a capped list reads as “more below”, without taking taps from the rows.
    private func queueFade(top: Bool) -> some View {
        let veil = Color(uiColor: .secondarySystemBackground)
        return LinearGradient(
            colors: top ? [veil.opacity(0.92), veil.opacity(0)] : [veil.opacity(0), veil.opacity(0.92)],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 18)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func queuedRow(_ item: IDEChatState.Queued) -> some View {
        let expanded = expandedIDs.contains(item.id)
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(Color.secondary.opacity(0.7))
                .frame(width: 5, height: 5)
                .padding(.top, 5)
            if editingID == item.id {
                TextField(String(localized: "Message"), text: $editDraft, axis: .vertical)
                    .lineLimit(1...4)
                    .font(.caption)
                    .focused($editFocused)
                    .onKeyPress(.escape) {
                        editingID = nil
                        editFocused = false
                        return .handled
                    }
                VStack(spacing: 2) {
                    queueIconButton("checkmark", label: String(localized: "Save")) {
                        let text = editDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty { onUpdate(item.id, text) }
                        editingID = nil
                        editFocused = false
                    }
                    queueIconButton("xmark", label: String(localized: "Cancel")) {
                        editingID = nil
                        editFocused = false
                    }
                }
            } else {
                Button {
                    if expanded {
                        expandedIDs.remove(item.id)
                    } else {
                        expandedIDs.insert(item.id)
                    }
                } label: {
                    Text(item.text)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(expanded ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .buttonStyle(.plain)
                HStack(spacing: 0) {
                    queueIconButton("pencil", label: String(localized: "Edit")) {
                        editDraft = item.text
                        editingID = item.id
                        editFocused = true
                    }
                    queueIconButton("arrow.up", label: "Send now") {
                        onSubmit(item.id)
                    }
                    queueIconButton("trash", label: String(localized: "Delete"), destructive: true) {
                        onRemove(item.id)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private func queueIconButton(
        _ systemName: String,
        label: String,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.caption2.weight(.semibold))
                .frame(width: 24, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(destructive ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
        .accessibilityLabel(label)
    }
}

private struct IDEShellContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 44
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct IDEShellBottomOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct IDEFileDiffCard: View {
    let bubbleId: String
    let tool: IDEChatMessage.Tool
    let onAction: (String, String, String?, String?) -> Void
    @State private var showingFile = false

    private var diff: IDEChatMessage.Tool.Diff { tool.diff! }
    private var filename: String {
        let name = (diff.path as NSString).lastPathComponent
        return name.isEmpty ? (tool.summary ?? tool.label) : name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                showingFile = true
                onAction("toolDetail", bubbleId, tool.toolCallId, nil)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "doc.text")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(verbatim: filename)
                        .font(.footnote.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if diff.additions > 0 {
                        Text(verbatim: "+\(diff.additions)").foregroundStyle(.green)
                    }
                    if diff.deletions > 0 {
                        Text(verbatim: "−\(diff.deletions)").foregroundStyle(.red)
                    }
                    Image(systemName: "chevron.up")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .font(.caption2.monospacedDigit())
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(diff.lines.prefix(8).enumerated()), id: \.offset) { _, line in
                        IDEDiffLineRow(line: line, language: diff.language)
                    }
                }
            }
            .frame(height: 144, alignment: .top)
            .clipped()
            .background(Color(uiColor: .tertiarySystemFill))
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.25)))
        .sheet(isPresented: $showingFile, onDismiss: {
            onAction("toolCollapse", bubbleId, tool.toolCallId, nil)
        }) {
            IDEFileDiffSheet(filename: filename, diff: diff)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }
}

struct IDEFileDiffSheet: View {
    let filename: String
    let diff: IDEChatMessage.Tool.Diff
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(diff.lines.enumerated()), id: \.offset) { _, line in
                        IDEDiffLineRow(line: line, language: diff.language)
                    }
                    if diff.truncated == true {
                        Text(String(localized: "Diff is too large; showing the first portion."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(12)
                    }
                }
                .frame(minWidth: 720, alignment: .leading)
            }
            .scrollIndicators(.visible)
            .navigationTitle(filename)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
        }
    }
}

private struct IDEDiffLineRow: View {
    let line: IDEChatMessage.Tool.DiffLine
    let language: String?

    private var marker: String {
        switch line.kind {
        case "add": "+"
        case "delete": "−"
        default: " "
        }
    }
    private var background: Color {
        switch line.kind {
        case "add": Color.green.opacity(0.15)
        case "delete": Color.red.opacity(0.15)
        default: Color.clear
        }
    }
    private var foreground: Color {
        switch line.kind {
        case "add": .green
        case "delete": .red
        default: .secondary
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            Text(line.oldLine.map(String.init) ?? "")
                .frame(width: 34, alignment: .trailing)
            Text(line.newLine.map(String.init) ?? "")
                .frame(width: 34, alignment: .trailing)
            Text(verbatim: marker)
                .foregroundStyle(foreground)
                .frame(width: 22)
            IDECodeLine(text: line.text, language: language)
                .padding(.trailing, 10)
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .frame(minHeight: 18, alignment: .leading)
        .background(background)
    }
}

private struct IDECodeLine: View {
    let text: String
    let language: String?

    var body: some View {
        Text(IDESyntaxHighlighter.highlight(text.isEmpty ? " " : text, language: language))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }
}

/// Line-local token colouring: keywords, strings, numbers and comments per language
/// family. Multi-line constructs (block comments, heredocs) are coloured per line only.
enum IDESyntaxHighlighter {
    private struct Family {
        var keywords: Set<String>
        var lineComments: [String]
        var blockComment: Bool
        var quotes: Set<Character>
    }

    private static let cKeywords: Set<String> = [
        "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue",
        "return", "true", "false", "null", "nil", "const", "static", "struct", "enum", "class",
        "public", "private", "protected", "import", "new", "this", "self", "try", "catch",
        "throw", "throws", "void", "int", "float", "double", "bool", "char", "typedef",
        "extern", "inline", "sizeof", "goto", "unsigned", "signed", "long", "short",
        "interface", "extends", "implements", "package", "final", "abstract", "override",
        "super", "instanceof", "finally", "async", "await", "yield", "in", "is", "as",
    ]

    private static func family(_ language: String?) -> Family? {
        switch language ?? "" {
        case "swift":
            return Family(keywords: cKeywords.union([
                "func", "let", "var", "guard", "defer", "extension", "protocol", "init", "deinit",
                "where", "some", "any", "inout", "mutating", "fileprivate", "internal", "open",
                "weak", "unowned", "lazy", "repeat", "associatedtype", "typealias", "rethrows",
            ]), lineComments: ["//"], blockComment: true, quotes: ["\""])
        case "c":
            return Family(keywords: cKeywords.union([
                "auto", "register", "volatile", "union", "namespace", "template", "typename",
                "virtual", "nullptr", "delete", "using", "@interface", "@implementation", "@end",
                "@property", "#include", "#import", "#define", "#if", "#ifdef", "#endif",
            ]), lineComments: ["//"], blockComment: true, quotes: ["\"", "'"])
        case "go":
            return Family(keywords: [
                "break", "case", "chan", "const", "continue", "default", "defer", "else",
                "fallthrough", "for", "func", "go", "goto", "if", "import", "interface", "map",
                "package", "range", "return", "select", "struct", "switch", "type", "var",
                "true", "false", "nil", "error", "string", "int", "bool", "byte", "any",
            ], lineComments: ["//"], blockComment: true, quotes: ["\"", "'", "`"])
        case "rust":
            return Family(keywords: cKeywords.union([
                "fn", "let", "mut", "impl", "trait", "pub", "use", "mod", "crate", "match",
                "loop", "move", "ref", "where", "dyn", "unsafe", "Self", "Some", "None", "Ok", "Err",
            ]), lineComments: ["//"], blockComment: true, quotes: ["\""])
        case "javascript", "typescript":
            return Family(keywords: cKeywords.union([
                "function", "let", "var", "const", "export", "from", "of", "typeof", "undefined",
                "type", "readonly", "keyof", "declare", "module", "require",
            ]), lineComments: ["//"], blockComment: true, quotes: ["\"", "'", "`"])
        case "java":
            return Family(keywords: cKeywords.union([
                "fun", "val", "var", "when", "object", "companion", "data", "sealed", "open",
                "lateinit", "synchronized", "volatile", "transient", "native", "def",
            ]), lineComments: ["//"], blockComment: true, quotes: ["\"", "'"])
        case "python":
            return Family(keywords: [
                "def", "class", "if", "elif", "else", "for", "while", "return", "import", "from",
                "as", "with", "try", "except", "finally", "raise", "pass", "break", "continue",
                "lambda", "yield", "async", "await", "in", "is", "not", "and", "or", "None",
                "True", "False", "self", "global", "nonlocal",
            ], lineComments: ["#"], blockComment: false, quotes: ["\"", "'"])
        case "ruby":
            return Family(keywords: [
                "def", "class", "module", "if", "elsif", "else", "unless", "end", "do", "while",
                "until", "for", "in", "return", "require", "yield", "begin", "rescue", "ensure",
                "nil", "true", "false", "self", "attr_reader", "attr_accessor", "then", "case", "when",
            ], lineComments: ["#"], blockComment: false, quotes: ["\"", "'"])
        case "shell":
            return Family(keywords: [
                "if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac",
                "function", "return", "export", "local", "set", "unset", "echo", "exit", "in",
                "FROM", "RUN", "COPY", "CMD", "ENV", "WORKDIR", "ENTRYPOINT", "ARG",
            ], lineComments: ["#"], blockComment: false, quotes: ["\"", "'"])
        case "json":
            return Family(keywords: ["true", "false", "null"], lineComments: ["//"], blockComment: false, quotes: ["\""])
        case "yaml", "toml":
            return Family(keywords: ["true", "false", "null", "yes", "no", "on", "off"],
                          lineComments: ["#"], blockComment: false, quotes: ["\"", "'"])
        case "css":
            return Family(keywords: ["important", "media", "import", "root", "hover", "before", "after"],
                          lineComments: ["//"], blockComment: true, quotes: ["\"", "'"])
        case "sql":
            let words = ["select", "from", "where", "insert", "into", "update", "delete", "create",
                         "table", "join", "left", "right", "inner", "on", "and", "or", "not", "null",
                         "as", "group", "by", "order", "limit", "values", "set", "index", "primary", "key"]
            return Family(keywords: Set(words + words.map { $0.uppercased() }),
                          lineComments: ["--"], blockComment: true, quotes: ["'", "\""])
        default:
            return nil
        }
    }

    private static let keywordColor = Color(red: 0.78, green: 0.35, blue: 0.75)
    private static let stringColor = Color(red: 0.85, green: 0.45, blue: 0.25)
    private static let numberColor = Color(red: 0.35, green: 0.6, blue: 0.95)
    private static let tagColor = Color(red: 0.3, green: 0.65, blue: 0.85)
    private static let headingColor = Color(red: 0.35, green: 0.6, blue: 0.95)

    static func highlight(_ line: String, language: String?) -> AttributedString {
        var out = AttributedString(line)
        out.foregroundColor = Color.primary.opacity(0.82)
        guard line.count <= 2000 else { return out }
        switch language ?? "" {
        case "xml":
            colorMarkup(line, into: &out)
            return out
        case "markdown":
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                out.foregroundColor = headingColor
                out.inlinePresentationIntent = .stronglyEmphasized
            } else if trimmed.hasPrefix("```") || trimmed.hasPrefix(">") {
                out.foregroundColor = Color.secondary
            }
            return out
        default:
            break
        }
        guard let family = family(language) else { return out }
        let chars = Array(line)
        var i = 0
        func paint(_ from: Int, _ to: Int, _ color: Color) {
            guard from < to else { return }
            let lo = out.index(out.startIndex, offsetByCharacters: from)
            let hi = out.index(out.startIndex, offsetByCharacters: to)
            out[lo..<hi].foregroundColor = color
        }
        func hasPrefix(_ token: String, at index: Int) -> Bool {
            let t = Array(token)
            guard index + t.count <= chars.count else { return false }
            return Array(chars[index..<index + t.count]) == t
        }
        while i < chars.count {
            let c = chars[i]
            if family.lineComments.contains(where: { hasPrefix($0, at: i) }) {
                paint(i, chars.count, Color.secondary.opacity(0.7))
                break
            }
            if family.blockComment, hasPrefix("/*", at: i) {
                var j = i + 2
                while j < chars.count, !hasPrefix("*/", at: j) { j += 1 }
                j = min(chars.count, j + 2)
                paint(i, j, Color.secondary.opacity(0.7))
                i = j
                continue
            }
            if family.quotes.contains(c) {
                var j = i + 1
                while j < chars.count, chars[j] != c {
                    j += chars[j] == "\\" ? 2 : 1
                }
                j = min(chars.count, j + 1)
                paint(i, j, stringColor)
                i = j
                continue
            }
            if c.isNumber, i == 0 || !(chars[i - 1].isLetter || chars[i - 1] == "_") {
                var j = i
                while j < chars.count, chars[j].isHexDigit || chars[j] == "." || chars[j] == "x" || chars[j] == "_" { j += 1 }
                paint(i, j, numberColor)
                i = j
                continue
            }
            if c.isLetter || c == "_" || c == "@" || c == "#" {
                var j = i + 1
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
                if family.keywords.contains(String(chars[i..<j])) {
                    paint(i, j, keywordColor)
                }
                i = j
                continue
            }
            i += 1
        }
        return out
    }

    private static func colorMarkup(_ line: String, into out: inout AttributedString) {
        let chars = Array(line)
        var i = 0
        func paint(_ from: Int, _ to: Int, _ color: Color) {
            guard from < to else { return }
            let lo = out.index(out.startIndex, offsetByCharacters: from)
            let hi = out.index(out.startIndex, offsetByCharacters: to)
            out[lo..<hi].foregroundColor = color
        }
        while i < chars.count {
            if chars[i] == "<" {
                var j = i + 1
                while j < chars.count, chars[j] != ">" {
                    if chars[j] == "\"" {
                        var k = j + 1
                        while k < chars.count, chars[k] != "\"" { k += 1 }
                        paint(j, min(chars.count, k + 1), stringColor)
                        j = k
                    }
                    j += 1
                }
                let end = min(chars.count, j + 1)
                var nameEnd = i + 1
                while nameEnd < end, !chars[nameEnd].isWhitespace, chars[nameEnd] != ">" { nameEnd += 1 }
                paint(i, nameEnd, tagColor)
                if end > 0, chars[end - 1] == ">" { paint(end - 1, end, tagColor) }
                i = end
                continue
            }
            i += 1
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
                .font(level <= 1 ? IDEChatStyle.heading1 : level == 2 ? IDEChatStyle.heading2 : IDEChatStyle.heading3)
                .padding(.top, 4)
        case .paragraph(let content):
            Text(Self.inline(content))
                .font(IDEChatStyle.prose)
                .fixedSize(horizontal: false, vertical: true)
        case .list(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.marker)
                            .font(IDEChatStyle.prose.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(Self.inline(item.text))
                            .font(IDEChatStyle.prose)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.depth) * 16)
                }
            }
        case .quote(let content):
            Text(Self.inline(content))
                .font(IDEChatStyle.prose)
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
        return (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
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
                blocks.append(.paragraph(joinSoftLines(paragraph)))
                paragraph = []
            }
        }

        func joinSoftLines(_ lines: [String]) -> String {
            var parts: [String] = []
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }
                if parts.isEmpty {
                    parts.append(trimmed)
                } else if line.hasSuffix("  ") {
                    parts[parts.count - 1] += "\n" + trimmed
                } else {
                    parts[parts.count - 1] += " " + trimmed
                }
            }
            return parts.joined(separator: "\n")
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
            if rest.hasPrefix(". ") {
                let text = String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if !text.isEmpty {
                    return ListItem(marker: digits + ".", text: text, depth: depth)
                }
            } else if rest.hasPrefix(") ") {
                let text = String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if !text.isEmpty {
                    return ListItem(marker: digits + ")", text: text, depth: depth)
                }
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
