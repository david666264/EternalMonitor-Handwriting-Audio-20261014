import SwiftUI
import UIKit

/// Session-independent, in-memory only: reconnecting/recreating DisplayView
/// cannot erase a draft or accidentally promote marked Pinyin to committed text.
@MainActor
final class KeyboardDraftStore {
    var text = ""
    var selection = NSRange(location: 0, length: 0)
    var markedRange: NSRange?
}

/// A native UITextInput document. UIKit owns Chinese composition, selection,
/// paste and Scribble; only an explicit submission leaves this local draft.
final class RelayKeyboardInputView: UITextView, UITextViewDelegate {
    weak var relay: RelayTouchUIView?
    var onDismiss: (() -> Void)?
    var draftStore: KeyboardDraftStore? {
        didSet { if draftStore !== oldValue { prepareForPresentation() } }
    }
    private var modifierButtons: [UInt16: UIButton] = [:]
    private var relayedHardwareKeys = Set<UInt16>()
    private let hint = UILabel()
    private let placeholder = UILabel()
    private var submitButton: UIButton?
    private var submitReturnButton: UIButton?
    private var restoringDraft = false
    private var preservingDraftOnDismiss = false

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        delegate = self
        keyboardType = .default
        autocorrectionType = .default
        autocapitalizationType = .none
        spellCheckingType = .default
        smartQuotesType = .no
        smartDashesType = .no
        font = .preferredFont(forTextStyle: .body)
        adjustsFontForContentSizeCategory = true
        textColor = .label
        backgroundColor = .secondarySystemBackground
        tintColor = UIColor(Theme.accent)
        layer.cornerRadius = 12
        layer.borderWidth = 1
        layer.borderColor = UIColor.separator.cgColor
        textContainerInset = UIEdgeInsets(top: 32, left: 10, bottom: 8, right: 10)
        accessibilityLabel = "本地输入草稿"
        accessibilityHint = "支持中文拼音和系统手写，选字并编辑后，点输入到电脑。"
        accessibilityIdentifier = "keyboard.input"
        hint.text = "先点电脑输入框；选字后点“输入到电脑”"
        hint.font = .preferredFont(forTextStyle: .caption1)
        hint.textColor = .secondaryLabel
        hint.accessibilityIdentifier = "keyboard.hint"
        hint.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hint)
        placeholder.text = "在这里输入中文、英文，或粘贴文字…"
        placeholder.font = font
        placeholder.textColor = .placeholderText
        placeholder.isUserInteractionEnabled = false
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholder)
        NSLayoutConstraint.activate([
            hint.topAnchor.constraint(equalTo: frameLayoutGuide.topAnchor, constant: 8),
            hint.leadingAnchor.constraint(equalTo: frameLayoutGuide.leadingAnchor, constant: 14),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: frameLayoutGuide.trailingAnchor, constant: -12),
            placeholder.topAnchor.constraint(equalTo: frameLayoutGuide.topAnchor, constant: 32),
            placeholder.leadingAnchor.constraint(equalTo: frameLayoutGuide.leadingAnchor, constant: 14),
            placeholder.trailingAnchor.constraint(lessThanOrEqualTo: frameLayoutGuide.trailingAnchor, constant: -12)
        ])
        inputAccessoryView = accessory
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func resignFirstResponder() -> Bool {
        let wasFirstResponder = isFirstResponder
        if wasFirstResponder {
            saveDraft()
            preservingDraftOnDismiss = true
        }
        let resigned = super.resignFirstResponder()
        if !resigned { preservingDraftOnDismiss = false }
        if wasFirstResponder && resigned {
            relayedHardwareKeys.removeAll()
            relay?.keyboardDidResign()
        }
        return resigned
    }

    func prepareForPresentation() {
        preservingDraftOnDismiss = false
        guard let store = draftStore else { return }
        restoringDraft = true
        text = store.text
        let length = (store.text as NSString).length
        let selection = NSRange(location: min(length, max(0, store.selection.location)),
            length: min(store.selection.length, max(0, length - store.selection.location)))
        if let marked = store.markedRange, marked.location <= length,
           marked.length <= length - marked.location {
            selectedRange = marked
            let markedText = (store.text as NSString).substring(with: marked)
            let relative = min(marked.length, max(0, selection.location - marked.location))
            super.setMarkedText(markedText, selectedRange: NSRange(location: relative, length: 0))
        } else { selectedRange = selection }
        restoringDraft = false
        updateDraftPresentation()
    }

    private func saveDraft() {
        guard !restoringDraft, !preservingDraftOnDismiss, let store = draftStore else { return }
        store.text = text ?? ""
        store.selection = selectedRange
        store.markedRange = markedTextRange.map {
            NSRange(location: offset(from: beginningOfDocument, to: $0.start),
                length: offset(from: $0.start, to: $0.end))
        }
    }

    func textViewDidChange(_ textView: UITextView) { updateDraftPresentation() }
    func textViewDidChangeSelection(_ textView: UITextView) { updateDraftPresentation() }

    override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        super.setMarkedText(markedText, selectedRange: selectedRange)
        updateDraftPresentation()
    }

    override func unmarkText() {
        super.unmarkText()
        updateDraftPresentation()
    }

    override func insertText(_ text: String) {
        // Explicit remote Ctrl/Alt/Win still supports a one-key shortcut.
        // Normal typing, including hardware-keyboard IME, stays local.
        if !hasText, markedTextRange == nil, relay?.hasRemoteStickyModifiers == true,
           text.utf16.count == 1, let unit = text.utf16.first,
           KeyboardRelayMachine.asciiKey(unit) != nil {
            relay?.insertRemoteText(text)
        } else { super.insertText(text) }
        updateDraftPresentation()
    }

    override func deleteBackward() {
        if hasText || markedTextRange != nil { super.deleteBackward() }
        else { relay?.tapRemoteKey(0x2a) }
        updateDraftPresentation()
    }

    /// A marked range is an unfinished candidate. Never force-unmark and send
    /// its Pinyin; the user first chooses a word, then submits it explicitly.
    @discardableResult
    func submitDraft(appendReturn: Bool = false) -> Bool {
        guard markedTextRange == nil else {
            hint.text = "请先选择候选词，再输入到电脑"
            return false
        }
        guard let relay, relay.canSendKeyboardInput else {
            hint.text = "连接暂不可用，草稿已保留"
            return false
        }
        let draft = text ?? ""
        guard !draft.isEmpty else { return false }
        relay.commitRemoteDraft(draft, appendReturn: appendReturn)
        text = ""
        undoManager?.removeAllActions()
        updateDraftPresentation()
        hint.text = appendReturn ? "已输入到电脑并回车" : "已输入到电脑；尚未按回车"
        return true
    }

    func clearDraft() {
        // This is a local edit, never a remote Backspace.
        if markedTextRange != nil { super.unmarkText() }
        text = ""
        undoManager?.removeAllActions()
        updateDraftPresentation()
    }

    private func updateDraftPresentation() {
        saveDraft()
        placeholder.isHidden = hasText
        let ready = hasText && markedTextRange == nil
        submitButton?.isEnabled = ready
        submitReturnButton?.isEnabled = ready
        hint.text = markedTextRange != nil ? "正在选字；确认候选词后再输入电脑"
            : "先点电脑输入框；选字后点“输入到电脑”"
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var local = Set<UIPress>()
        var remote = Set<UIPress>()
        for press in presses {
            guard let key = press.key else { local.insert(press); continue }
            let usage = UInt16(key.keyCode.rawValue)
            let flags: UInt8 = (key.modifierFlags.contains(.shift) ? 1 : 0)
                | (key.modifierFlags.contains(.control) ? 2 : 0)
                | (key.modifierFlags.contains(.alternate) ? 4 : 0)
                | (key.modifierFlags.contains(.command) ? 8 : 0)
            if KeyboardRelayMachine.routesHardwareToRemote(usage: usage, modifiers: flags,
                hasDraft: hasText, composing: markedTextRange != nil,
                sticky: relay?.hasRemoteStickyModifiers == true) {
                relayedHardwareKeys.insert(usage)
                remote.insert(press)
            } else { local.insert(press) }
        }
        if !remote.isEmpty { relay?.relayHardwarePressesBegan(remote) }
        if !local.isEmpty { super.pressesBegan(local, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var local = Set<UIPress>()
        var remote = Set<UIPress>()
        for press in presses {
            guard let key = press.key else { local.insert(press); continue }
            let usage = UInt16(key.keyCode.rawValue)
            if relayedHardwareKeys.remove(usage) != nil { remote.insert(press) }
            else { local.insert(press) }
            // Release a modifier inferred by a remote shortcut, even if its
            // original key-down was handled by UIKit for local text editing.
            if KeyboardRelayMachine.modifierBit(usage) != 0,
               relay?.hasRemoteHardwareState == true { remote.insert(press) }
        }
        if !remote.isEmpty { relay?.relayHardwarePressesEnded(remote) }
        if !local.isEmpty { super.pressesEnded(local, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        relayedHardwareKeys.removeAll()
        relay?.relayHardwarePressesCancelled()
        super.pressesCancelled(presses, with: event)
    }

    func updateSticky(_ held: Set<UInt16>) {
        for (usage, button) in modifierButtons {
            button.isSelected = held.contains(usage)
            button.accessibilityValue = held.contains(usage) ? "已按下" : "未按下"
            button.configuration?.baseBackgroundColor = held.contains(usage) ? UIColor(Theme.accent) : .secondarySystemFill
            button.configuration?.baseForegroundColor = held.contains(usage) ? .black : .label
        }
    }

    private func button(_ title: String, id: String, prominent: Bool = false,
                        action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        var configuration = prominent ? UIButton.Configuration.filled() : .gray()
        configuration.title = title
        configuration.baseBackgroundColor = prominent ? UIColor(Theme.accent) : .secondarySystemFill
        configuration.baseForegroundColor = prominent ? .black : .label
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10)
        button.configuration = configuration
        button.accessibilityIdentifier = id
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    private lazy var accessory: UIInputView = {
        let view = UIInputView(frame: CGRect(x: 0, y: 0, width: 700, height: 104), inputViewStyle: .keyboard)
        let actionScroll = UIScrollView()
        actionScroll.translatesAutoresizingMaskIntoConstraints = false
        actionScroll.showsHorizontalScrollIndicator = false
        view.addSubview(actionScroll)
        let actions = UIStackView()
        actions.axis = .horizontal
        actions.spacing = 6
        actions.translatesAutoresizingMaskIntoConstraints = false
        actionScroll.addSubview(actions)
        let submit = button("输入到电脑", id: "keyboard.submit", prominent: true) { [weak self] in
            self?.submitDraft()
        }
        let submitReturn = button("输入并回车", id: "keyboard.submitReturn") { [weak self] in
            self?.submitDraft(appendReturn: true)
        }
        submitButton = submit
        submitReturnButton = submitReturn
        actions.addArrangedSubview(submit)
        actions.addArrangedSubview(submitReturn)
        actions.addArrangedSubview(button("清空草稿", id: "keyboard.clear") { [weak self] in self?.clearDraft() })
        actions.addArrangedSubview(button("收起", id: "keyboard.done") { [weak self] in self?.onDismiss?() })
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsHorizontalScrollIndicator = false
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            actionScroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            actionScroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            actionScroll.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            actionScroll.heightAnchor.constraint(equalToConstant: 44),
            actions.leadingAnchor.constraint(equalTo: actionScroll.contentLayoutGuide.leadingAnchor, constant: 6),
            actions.trailingAnchor.constraint(equalTo: actionScroll.contentLayoutGuide.trailingAnchor, constant: -6),
            actions.topAnchor.constraint(equalTo: actionScroll.contentLayoutGuide.topAnchor),
            actions.bottomAnchor.constraint(equalTo: actionScroll.contentLayoutGuide.bottomAnchor),
            actions.heightAnchor.constraint(equalTo: actionScroll.frameLayoutGuide.heightAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: actionScroll.bottomAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4)
        ])
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor)
        ])
        let keys: [(String, String, UInt16)] = [
            ("Esc", "电脑 Escape", 0x29), ("Tab", "电脑 Tab", 0x2b),
            ("Ctrl", "电脑 Control", 0xe0), ("Alt", "电脑 Alt", 0xe2), ("Win", "Windows 键", 0xe3),
            ("←", "电脑左箭头", 0x50), ("↑", "电脑上箭头", 0x52),
            ("↓", "电脑下箭头", 0x51), ("→", "电脑右箭头", 0x4f),
            ("电脑退格", "电脑退格", 0x2a), ("电脑回车", "电脑回车", 0x28),
            ("Home", "电脑行首", 0x4a), ("End", "电脑行尾", 0x4d), ("Del", "电脑删除", 0x4c)
        ]
        for (title, label, usage) in keys {
            let key = button(title, id: "keyboard.key.\(usage)") { [weak self] in
                guard let self else { return }
                if KeyboardRelayMachine.modifierBit(usage) != 0 { self.relay?.toggleRemoteModifier(usage) }
                else { self.relay?.tapRemoteKey(usage) }
            }
            key.accessibilityLabel = label
            key.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            if KeyboardRelayMachine.modifierBit(usage) != 0 {
                modifierButtons[usage] = key
                key.accessibilityValue = "未按下"
            }
            stack.addArrangedSubview(key)
        }
        updateDraftPresentation()
        return view
    }()
}
