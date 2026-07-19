import SwiftUI

/// Takes over the top of the Agents tab while a hook connection is held open
/// waiting for a permission decision. Standard tool requests get
/// Deny / Allow / Allow-and-don't-ask-again (keys 1 / 2 / 3, Esc collapses);
/// `AskUserQuestion` renders the question, its options (keys 1…9) and a
/// free-text answer field.
struct AgentApprovalCardView: View {
    let session: AgentSession
    let payload: AgentPermissionRequestPayload
    /// Esc handler (integrator: close the notch). The held hook connection
    /// stays open — the CLI falls back to its own prompt after the timeout.
    var onDismiss: (() -> Void)?

    @ObservedObject private var store = AgentSessionStore.shared
    @FocusState private var cardFocused: Bool
    @FocusState private var textFieldFocused: Bool
    @State private var freeText = ""
    /// question → chosen answer (multi-question AskUserQuestion).
    @State private var chosenAnswers: [String: String] = [:]

    private var isQuestion: Bool { payload.toolName == "AskUserQuestion" }
    private var questions: [AgentQuestionSpec] {
        AgentQuestionSpec.parse(payload.toolInput)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if isQuestion, !questions.isEmpty {
                questionBody
            } else {
                toolBody
                buttonsRow
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(Color.red.opacity(0.35), lineWidth: 1)
                )
        )
        .focusable()
        .focused($cardFocused)
        .onKeyPress(phases: .down) { press in
            handleKey(press)
        }
        .onAppear {
            DispatchQueue.main.async { cardFocused = true }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: isQuestion ? "questionmark.bubble.fill" : "shield.lefthalf.filled")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isQuestion ? Color.cyan : Color.red)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill((isQuestion ? Color.cyan : Color.red).opacity(0.15))
                )
            VStack(alignment: .leading, spacing: 1) {
                Text(isQuestion ? "Question from agent" : "Permission request")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                HStack(spacing: 5) {
                    AgentProviderGlyph(provider: session.provider, size: 9)
                    Text(session.projectName)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color(white: 0.6))
                    Text("#\(AgentUIFormat.shortId(session.sessionId))")
                        .font(.system(size: 9.5).monospaced())
                        .foregroundStyle(Color(white: 0.42))
                }
            }
            Spacer()
            expiryCountdown
        }
    }

    /// Hooks are held open ~290 s; show what's left so a stale card explains itself.
    private var expiryCountdown: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, 290 - Int(context.date.timeIntervalSince(payload.receivedAt)))
            Text(remaining > 0 ? String(format: "%d:%02d", remaining / 60, remaining % 60) : "expired")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(remaining < 30 ? .red : Color(white: 0.5))
        }
    }

    // MARK: Standard tool request

    private var toolBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: AgentUIFormat.toolSymbol(payload.toolName))
                    .font(.system(size: 11))
                    .foregroundStyle(Color(white: 0.8))
                Text(payload.toolName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            }
            paramsBox
        }
    }

    @ViewBuilder
    private var paramsBox: some View {
        ScrollView(.vertical, showsIndicators: true) {
            Text(prettyParams)
                .font(.system(size: 11).monospaced())
                .foregroundStyle(Color(white: 0.82))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(maxHeight: 110)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.45))
        )
    }

    /// Pretty-print the key params: raw command for Bash, file path for edits,
    /// compact key/value lines otherwise.
    private var prettyParams: String {
        guard let input = payload.toolInput, !input.isEmpty else {
            return payload.inputSummary.isEmpty ? "(no arguments)" : payload.inputSummary
        }
        switch payload.toolName {
        case "Bash":
            if let cmd = (input["command"] as? String) ?? (input["cmd"] as? String) {
                var lines = ["$ \(cmd)"]
                if let desc = input["description"] as? String, !desc.isEmpty {
                    lines.append("# \(desc)")
                }
                return lines.joined(separator: "\n")
            }
        case "Edit", "Write", "MultiEdit", "NotebookEdit", "Read":
            if let path = (input["file_path"] as? String)
                ?? (input["path"] as? String)
                ?? (input["notebook_path"] as? String) {
                var lines = [path]
                if let newString = input["new_string"] as? String {
                    lines.append("→ \(Self.clip(newString, 200))")
                } else if let content = input["content"] as? String {
                    lines.append("(\(content.count) chars)")
                }
                return lines.joined(separator: "\n")
            }
        default:
            break
        }
        // Generic: sorted key: value lines.
        let lines = input.keys.sorted().compactMap { key -> String? in
            guard let value = input[key] else { return nil }
            let rendered: String
            if let s = value as? String {
                rendered = Self.clip(s, 300)
            } else if let data = try? JSONSerialization.data(
                withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]),
                let s = String(data: data, encoding: .utf8) {
                rendered = Self.clip(s, 300)
            } else {
                rendered = "\(value)"
            }
            return "\(key): \(rendered)"
        }
        return lines.isEmpty ? payload.inputSummary : lines.joined(separator: "\n")
    }

    private static func clip(_ s: String, _ limit: Int) -> String {
        s.count <= limit ? s : String(s.prefix(limit)) + "…"
    }

    // MARK: Decision buttons

    private var buttonsRow: some View {
        HStack(spacing: 8) {
            AgentDecisionButton(title: "Deny", keycap: "1", tint: .red) { deny() }
            AgentDecisionButton(title: "Allow", keycap: "2", tint: .green, prominent: true) {
                allow(remember: false)
            }
            AgentDecisionButton(title: "Don't ask again", keycap: "3", tint: .green) {
                allow(remember: true)
            }
            Spacer()
            Text("esc closes")
                .font(.system(size: 9.5))
                .foregroundStyle(Color(white: 0.4))
        }
    }

    private func allow(remember: Bool) {
        store.respondToPermission(sessionKey: session.id, allow: true, remember: remember)
    }

    private func deny() {
        store.respondToPermission(sessionKey: session.id, allow: false)
    }

    // MARK: AskUserQuestion

    private var questionBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(questions.enumerated()), id: \.offset) { _, spec in
                questionBlock(spec)
            }
            freeTextRow
            if questions.count > 1 {
                HStack {
                    Spacer()
                    AgentDecisionButton(
                        title: "Send answers", keycap: nil, tint: .green,
                        prominent: true, disabled: chosenAnswers.count < questions.count
                    ) {
                        submitAnswers(chosenAnswers)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func questionBlock(_ spec: AgentQuestionSpec) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let header = spec.header, !header.isEmpty {
                Text(header.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color(white: 0.5))
                    .kerning(0.5)
            }
            Text(AgentUIFormat.markdown(spec.question))
                .font(.system(size: 12.5))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !spec.options.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(spec.options.enumerated()), id: \.offset) { index, option in
                        optionButton(spec: spec, option: option, index: index)
                    }
                }
            }
        }
    }

    private func optionButton(spec: AgentQuestionSpec, option: String, index: Int) -> some View {
        let selected = chosenAnswers[spec.question] == option
        return Button {
            selectOption(spec: spec, option: option)
        } label: {
            HStack(spacing: 7) {
                if questions.count == 1, index < 9 {
                    Text("\(index + 1)")
                        .font(.system(size: 9, weight: .bold).monospaced())
                        .frame(width: 14, height: 14)
                        .background(RoundedRectangle(cornerRadius: 3.5).fill(Color.white.opacity(0.12)))
                        .foregroundStyle(Color(white: 0.7))
                }
                Text(option)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(selected ? 0.16 : 0.07))
            )
        }
        .buttonStyle(.plain)
    }

    private var freeTextRow: some View {
        HStack(spacing: 7) {
            TextField("Type your own answer…", text: $freeText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .focused($textFieldFocused)
                .onSubmit { submitFreeText() }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black.opacity(0.4))
                )
            Button {
                submitFreeText()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(freeText.isEmpty ? Color(white: 0.35) : .green)
            }
            .buttonStyle(.plain)
            .disabled(freeText.isEmpty)
        }
    }

    private func selectOption(spec: AgentQuestionSpec, option: String) {
        if questions.count == 1 {
            submitAnswers([spec.question: option])
        } else {
            chosenAnswers[spec.question] = option
        }
    }

    private func submitFreeText() {
        let answer = freeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return }
        // Free text answers the first unanswered question.
        if let spec = questions.first(where: { chosenAnswers[$0.question] == nil }) ?? questions.first {
            if questions.count == 1 {
                submitAnswers([spec.question: answer])
            } else {
                chosenAnswers[spec.question] = answer
                freeText = ""
                if chosenAnswers.count >= questions.count { submitAnswers(chosenAnswers) }
            }
        }
    }

    /// Allow with `updatedInput.answers[question] = answer` for every answer —
    /// the shape Claude Code expects for AskUserQuestion (research-notchi).
    private func submitAnswers(_ answers: [String: String]) {
        guard !answers.isEmpty else { return }
        var input = payload.toolInput ?? [:]
        var merged: [String: Any] = (input["answers"] as? [String: Any]) ?? [:]
        for (question, answer) in answers { merged[question] = answer }
        input["answers"] = merged
        let json = AgentPermissionDecision.allowJSON(event: payload.event, updatedInput: input)
        store.resolvePermission(sessionKey: session.id, responseJSON: json)
    }

    // MARK: Keyboard

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        if press.key == .escape {
            onDismiss?()
            return .handled
        }
        // Don't steal digits while the free-text field has focus.
        guard !textFieldFocused else { return .ignored }

        if isQuestion {
            guard questions.count == 1, let spec = questions.first,
                  let digit = Int(press.characters), digit >= 1, digit <= spec.options.count
            else { return .ignored }
            selectOption(spec: spec, option: spec.options[digit - 1])
            return .handled
        }

        switch press.characters {
        case "1": deny(); return .handled
        case "2": allow(remember: false); return .handled
        case "3": allow(remember: true); return .handled
        default: return .ignored
        }
    }
}

// MARK: - Question spec

/// One parsed AskUserQuestion entry (input carries either a `questions` array
/// or a single `question` + `options`).
struct AgentQuestionSpec: Equatable {
    let question: String
    let header: String?
    let options: [String]
    let multiSelect: Bool

    static func parse(_ input: [String: Any]?) -> [AgentQuestionSpec] {
        guard let input else { return [] }
        if let array = input["questions"] as? [[String: Any]] {
            return array.compactMap { parseOne($0) }
        }
        if let one = parseOne(input) { return [one] }
        return []
    }

    private static func parseOne(_ dict: [String: Any]) -> AgentQuestionSpec? {
        guard let question = dict["question"] as? String, !question.isEmpty else { return nil }
        let header = dict["header"] as? String
        let multiSelect = (dict["multiSelect"] as? Bool) ?? false
        var options: [String] = []
        if let raw = dict["options"] as? [Any] {
            for item in raw {
                if let s = item as? String {
                    options.append(s)
                } else if let obj = item as? [String: Any],
                          let label = (obj["label"] as? String) ?? (obj["value"] as? String) {
                    options.append(label)
                }
            }
        }
        return AgentQuestionSpec(question: question, header: header,
                                 options: options, multiSelect: multiSelect)
    }
}

// MARK: - Decision button

private struct AgentDecisionButton: View {
    let title: String
    let keycap: String?
    let tint: Color
    var prominent = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let keycap {
                    Text(keycap)
                        .font(.system(size: 9, weight: .bold).monospaced())
                        .frame(width: 14, height: 14)
                        .background(RoundedRectangle(cornerRadius: 3.5).fill(Color.white.opacity(0.15)))
                        .foregroundStyle(.white.opacity(0.8))
                }
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tint.opacity(prominent ? 0.4 : 0.18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(tint.opacity(prominent ? 0.8 : 0.4), lineWidth: 1)
                    )
            )
            .foregroundStyle(.white)
            .opacity(disabled ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}
