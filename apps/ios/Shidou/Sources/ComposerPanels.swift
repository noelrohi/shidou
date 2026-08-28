import ShidouProtocol
import ShidouSession
import SwiftUI

// The panels that stack above the composer box: a permission the agent is
// blocked on, the multi-question form it asks instead, and the follow-ups
// queued behind a running turn.

/// A permission request, pinned directly above the composer.
///
/// It takes the keyboard down when it appears. The agent is blocked and the
/// options are the only useful thing on screen; leaving a keyboard over them
/// would hide the answer behind the question.
struct PermissionPanel: View {
    let permission: PendingPermission
    let respond: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(permission.title)
                .font(.subheadline.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            if !permission.detail.isEmpty {
                ScrollView {
                    Text(permission.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 120)
            }
            // The options wrap rather than scroll: an answer the user cannot
            // see is an answer they cannot give.
            VStack(spacing: 8) {
                ForEach(permission.options, id: \.id) { option in
                    Button {
                        respond(option.id)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: option.allow ? "checkmark" : "xmark")
                                .font(.caption)
                                .accessibilityHidden(true)
                            Text(option.label)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(option.allow ? .accentColor : .secondary)
                    .controlSize(.large)
                }
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14).strokeBorder(.orange.opacity(0.35))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Permission requested: \(permission.title)")
    }
}

/// The `userInputRequested` form: one question at a time, with a free-text
/// answer alongside the offered options.
struct UserInputPanel: View {
    let input: PendingUserInput
    let submit: ([UserInputAnswer]) -> Void

    @State private var index = 0
    @State private var selections: [String: [String]] = [:]
    @State private var custom: [String: String] = [:]
    @State private var submitting = false
    @FocusState private var customFocused: Bool

    private var question: UserInputQuestion? {
        index < input.questions.count ? input.questions[index] : nil
    }

    var body: some View {
        if let question {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(question.header)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if input.questions.count > 1 {
                        Text("\(index + 1) of \(input.questions.count)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(question.question)
                    .font(.subheadline.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(question.options, id: \.label) { option in
                    optionButton(question: question, option: option)
                }
                TextField("Type another answer", text: customBinding(for: question))
                    .textFieldStyle(.roundedBorder)
                    .focused($customFocused)
                    .submitLabel(index + 1 == input.questions.count ? .send : .next)
                    .onSubmit { advance() }
                HStack {
                    if index > 0 {
                        Button("Back") { index -= 1 }
                            .buttonStyle(.borderless)
                    }
                    Spacer()
                    Button(index + 1 == input.questions.count ? "Submit" : "Next") { advance() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canContinue(question) || submitting)
                }
            }
            .padding(14)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.separator) }
            .onChange(of: input.requestId) { _, _ in reset() }
            .accessibilityElement(children: .contain)
        }
    }

    private func optionButton(question: UserInputQuestion, option: UserInputOption) -> some View {
        let checked = (selections[question.id] ?? []).contains(option.label)
        return Button {
            select(question: question, label: option.label)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(
                    systemName: question.multiSelect
                        ? (checked ? "checkmark.square.fill" : "square")
                        : (checked ? "largecircle.fill.circle" : "circle")
                )
                .foregroundStyle(checked ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                    if let description = option.description, description != option.label {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                checked ? AnyShapeStyle(.tint.opacity(0.12)) : AnyShapeStyle(.quaternary.opacity(0.4)),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(checked ? [.isSelected] : [])
    }

    private func customBinding(for question: UserInputQuestion) -> Binding<String> {
        Binding(
            get: { custom[question.id] ?? "" },
            set: { value in
                custom[question.id] = value
                // A typed answer replaces a picked one rather than joining it:
                // the form asks for an answer, not for both.
                if !value.trimmingCharacters(in: .whitespaces).isEmpty {
                    selections[question.id] = []
                }
            }
        )
    }

    private func select(question: UserInputQuestion, label: String) {
        custom[question.id] = ""
        var current = selections[question.id] ?? []
        if question.multiSelect {
            if let existing = current.firstIndex(of: label) {
                current.remove(at: existing)
            } else {
                current.append(label)
            }
        } else {
            current = [label]
        }
        selections[question.id] = current
    }

    private func canContinue(_ question: UserInputQuestion) -> Bool {
        !(custom[question.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            || !(selections[question.id] ?? []).isEmpty
    }

    private func advance() {
        guard let question, canContinue(question), !submitting else { return }
        guard index + 1 == input.questions.count else {
            index += 1
            customFocused = false
            return
        }
        submitting = true
        submit(input.questions.map { item in
            let typed = (custom[item.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return UserInputAnswer(
                questionId: item.id,
                answers: typed.isEmpty ? (selections[item.id] ?? []) : [typed]
            )
        })
    }

    private func reset() {
        index = 0
        selections = [:]
        custom = [:]
        submitting = false
    }
}

/// Follow-ups waiting behind the running turn. Each can be edited back into
/// the composer, steered into the turn that is running, or dropped.
struct QueuedMessagesView: View {
    let messages: [QueuedMessage]
    let canSteer: Bool
    let edit: (QueuedMessage) -> Void
    let steer: (QueuedMessage) -> Void
    let remove: (QueuedMessage) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(messages) { message in
                HStack(spacing: 8) {
                    Image(systemName: "text.line.first.and.arrowtriangle.forward")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(label(for: message))
                        .font(.footnote)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Menu {
                        Button {
                            edit(message)
                        } label: {
                            Label("Edit in composer", systemImage: "pencil")
                        }
                        if canSteer {
                            Button {
                                steer(message)
                            } label: {
                                Label("Steer current turn", systemImage: "arrow.turn.down.right")
                            }
                        }
                        Button(role: .destructive) {
                            remove(message)
                        } label: {
                            Label("Remove follow-up", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 44, height: 32)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Queued message actions")
                }
                .padding(.leading, 12)
                .padding(.vertical, 2)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Queued: \(label(for: message))")
            }
        }
        .padding(.vertical, 4)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    private func label(for message: QueuedMessage) -> String {
        let visible = message.visibleContent
        if !visible.isEmpty { return visible }
        return message.attachments.map(\.name).joined(separator: ", ")
    }
}

/// The `@file` and `/command` suggestion list, above the box.
struct ComposerSuggestions: View {
    let rows: [ComposerAutocompleteRow]
    /// Where the arrow keys are. Touch ignores it and taps a row directly.
    let highlight: Int
    let accept: (ComposerAutocompleteRow) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        Button { accept(row) } label: {
                            content(row)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    index == highlight
                                        ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(row.id)
                        .accessibilityAddTraits(index == highlight ? [.isSelected] : [])
                        Divider().padding(.leading, 12)
                    }
                }
            }
            .onChange(of: highlight) { _, index in
                guard index < rows.count else { return }
                proxy.scrollTo(rows[index].id, anchor: .center)
            }
        }
        .frame(maxHeight: 210)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.separator) }
        .accessibilityLabel("Suggestions")
    }

    @ViewBuilder
    private func content(_ row: ComposerAutocompleteRow) -> some View {
        switch row {
        case .command(let command):
            HStack(spacing: 8) {
                Image(systemName: command.scope == .skill ? "sparkles" : "chevron.forward.square")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("/\(command.name)").font(.footnote.weight(.medium))
                if let hint = command.argumentHint {
                    Text(hint).font(.caption2).foregroundStyle(.tertiary)
                }
                Text(command.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(scopeLabel(command.scope))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .file(let file):
            HStack(spacing: 8) {
                Image(systemName: file.isDir ? "folder" : "doc")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(name(of: file.path)).font(.footnote)
                Text(parent(of: file.path))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 0)
            }
        }
    }

    private func scopeLabel(_ scope: CommandScope) -> String {
        switch scope {
        case .project: return String(localized: "project")
        case .user: return String(localized: "user")
        case .skill: return String(localized: "skill")
        case .builtin, .unknown: return String(localized: "built-in")
        }
    }

    private func name(of path: String) -> String {
        String(path.split(separator: "/").last ?? Substring(path))
    }

    private func parent(of path: String) -> String {
        let parts = path.split(separator: "/").dropLast()
        return parts.joined(separator: "/")
    }
}

/// One staged attachment. Images show their bytes once the daemon has handed
/// them over; everything else shows its name.
struct AttachmentTile: View {
    let attachment: MessageAttachment
    let store: SessionStore
    let remove: () -> Void

    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    VStack(spacing: 4) {
                        Image(systemName: attachment.isDir ? "folder" : "doc")
                            .foregroundStyle(.secondary)
                        Text(attachment.name)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.horizontal, 4)
                    }
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.separator) }

            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.55))
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(attachment.name)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(attachment.name)
        .task(id: attachment.blobReference) {
            guard attachment.isImage, let data = try? await store.attachmentData(attachment) else {
                return
            }
            image = UIImage(data: data)
        }
    }
}
