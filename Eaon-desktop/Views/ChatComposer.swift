import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ChatComposer: View {
    @Environment(\.themeColors) private var colors
    @Bindable var viewModel: ChatViewModel
    @FocusState private var isFocused: Bool
    @State private var editorHeight: CGFloat = GrowingMessageField.minHeight
    @State private var isAttachMenuOpen = false
    @State private var isImageImporterPresented = false
    @State private var isFileImporterPresented = false

    private var canSend: Bool {
        let hasText = !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasAttachments = !viewModel.pendingAttachments.isEmpty
        return (hasText || hasAttachments) && !viewModel.isGenerating
    }

    private var hasContent: Bool {
        !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !viewModel.pendingAttachments.isEmpty
    }

    /// "Ask anything" is generic filler when the active model is already
    /// known — naming it costs nothing and feels more considered. Falls
    /// back to the generic phrasing only while there's genuinely no
    /// resolved model to name (nothing selected yet, or still loading).
    private var composerPlaceholder: String {
        guard !viewModel.selectedModel.isEmpty, !viewModel.isLoadingModels else {
            return "Ask anything"
        }
        let record = viewModel.chatModels.first { $0.id == viewModel.selectedModel }
        var name = ModelPreferencesStore.shared.nickname(for: viewModel.selectedModel)
            ?? ModelCatalog.displayName(modelId: viewModel.selectedModel, apiName: record?.name)
        // An Ollama-style "name:tag" id (e.g. "deepseek-r1:7b") has no
        // catalog entry or nickname to fall back on, so it reaches here
        // unstripped — "Ask deepseek-r1 anything" reads better inline than
        // including the tag. A real catalog/nickname name never has a colon.
        if let colonIndex = name.firstIndex(of: ":") {
            name = String(name[name.startIndex..<colonIndex])
        }
        return "Ask \(name) anything"
    }

    var body: some View {
        VStack(spacing: 8) {
            if !KeychainService.hasAPIKey {
                noticeBanner(icon: "key.fill", tint: .orange, text: "Add your API key in Settings → Aqua API to chat.")
            }
            if let notice = viewModel.composerNotice {
                noticeBanner(icon: "info.circle", tint: .orange, text: notice)
            }

            pill
        }
    }

    // MARK: - Composer pill

    private var pill: some View {
        VStack(spacing: 0) {
            if !viewModel.pendingAttachments.isEmpty {
                PendingAttachmentsBar(attachments: viewModel.pendingAttachments) { id in
                    viewModel.removePendingAttachment(id: id)
                }
                .padding(.top, 14)
            }

            // Row 1 — text area on its own line, spanning the full width.
            GrowingMessageField(
                text: $viewModel.inputText,
                isFocused: $isFocused,
                height: $editorHeight,
                onSend: sendIfPossible,
                placeholder: composerPlaceholder
            )
            .padding(.horizontal, 18)
            .padding(.top, 16)

            // Row 2 — attach button pinned left, send button pinned right.
            HStack(spacing: 8) {
                plusButton
                Spacer(minLength: 0)
                trailingControls
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(colors.backgroundInput)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(colors.borderSubtle, lineWidth: 1)
        )
        .shadow(color: colors.shadowColor.opacity(0.16), radius: 6, x: 0, y: 2)
        .fileImporter(
            isPresented: $isImageImporterPresented,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in handleImport(result, kind: .image) }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in handleImport(result, kind: .file) }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                AppFocus.activate()
                isFocused = true
            }
        }
        .onChange(of: viewModel.inputText) { _, _ in
            if viewModel.inputText.isEmpty {
                editorHeight = GrowingMessageField.minHeight
            }
        }
    }

    private var plusButton: some View {
        Button {
            isAttachMenuOpen.toggle()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(colors.textPrimary.opacity(0.85))
                .frame(width: 34, height: 34)
                .background(Circle().fill(colors.backgroundInputSecondary))
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .popover(isPresented: $isAttachMenuOpen, arrowEdge: .top) {
            ComposerAttachmentMenu(
                onPickImage: { isAttachMenuOpen = false; isImageImporterPresented = true },
                onPickFile: { isAttachMenuOpen = false; isFileImporterPresented = true },
                onPasteImage: { isAttachMenuOpen = false; viewModel.pasteImageAttachment() },
                onComingSoon: { feature in
                    isAttachMenuOpen = false
                    viewModel.composerNotice = "\(feature) is coming to Aqua soon."
                }
            )
        }
    }

    private var trailingControls: some View {
        Button(action: primaryAction) {
            primaryIcon
                .frame(width: 36, height: 36)
                .background(Circle().fill(primaryFill))
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(!viewModel.isGenerating && !hasContent)
    }

    @ViewBuilder
    private var primaryIcon: some View {
        if viewModel.isGenerating {
            Image(systemName: "stop.fill")
                .font(.system(size: 13))
                .foregroundStyle(.white)
        } else {
            Image(systemName: "arrow.up")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(colors.backgroundPrimary)
        }
    }

    // Monochrome inverted-surface fill (black-on-white in light, white-on-black
    // in dark) — dimmed when there's nothing to send, matching the target's
    // send button rather than a colored accent.
    private var primaryFill: Color {
        if viewModel.isGenerating { return colors.destructive }
        return hasContent ? colors.textPrimary : colors.textPrimary.opacity(0.35)
    }

    private func primaryAction() {
        if viewModel.isGenerating {
            viewModel.stopGeneration()
        } else if canSend {
            sendIfPossible()
        }
    }

    private func noticeBanner(icon: String, tint: Color, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).font(AppFont.sans(12)).foregroundStyle(colors.textSecondary)
            Spacer()
        }
        .padding(.horizontal, 8)
    }

    private func handleImport(_ result: Result<[URL], Error>, kind: AttachmentKind) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            viewModel.addAttachment(from: url, kind: kind)
        case .failure(let error):
            viewModel.composerNotice = error.localizedDescription
        }
    }

    private func sendIfPossible() {
        guard canSend else { return }
        editorHeight = GrowingMessageField.minHeight
        viewModel.startSend()
    }
}

private struct GrowingMessageField: View {
    @Environment(\.themeColors) private var colors
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    @Binding var height: CGFloat
    var onSend: () -> Void
    var placeholder: String = "Ask anything"

    static let minHeight: CGFloat = 46
    static let maxHeight: CGFloat = 220
    private let fontSize: CGFloat = 16

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(AppFont.sans(fontSize))
                        .foregroundColor(colors.textTertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .allowsHitTesting(false)
                }

                EnterToSendTextEditor(
                    text: $text,
                    isFocused: isFocused,
                    onSend: onSend,
                    textColor: colors.textPrimary
                )
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
            }
            .frame(height: height)
            .contentShape(Rectangle())
            .onTapGesture {
                AppFocus.activate()
                isFocused.wrappedValue = true
            }
            .onAppear { updateHeight(for: proxy.size.width) }
            .onChange(of: text) { _, _ in updateHeight(for: proxy.size.width) }
            .onChange(of: proxy.size.width) { _, newWidth in updateHeight(for: newWidth) }
        }
        .frame(height: height)
    }

    private func updateHeight(for width: CGFloat) {
        let measured = Self.height(for: text, width: width, fontSize: fontSize)
        withAnimation(.easeOut(duration: 0.12)) { height = measured }
    }

    private static func height(for text: String, width: CGFloat, fontSize: CGFloat) -> CGFloat {
        let horizontalInset: CGFloat = 12
        let usableWidth = max(width - horizontalInset, 120)
        let font = AppFont.sansNSFont(fontSize)
        let sample = text.isEmpty ? " " : text
        let rect = (sample as NSString).boundingRect(
            with: CGSize(width: usableWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        return min(max(minHeight, ceil(rect.height) + 8), maxHeight)
    }
}

private struct EnterToSendTextEditor: NSViewRepresentable {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    var onSend: () -> Void
    var textColor: Color

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder

        let textView = EnterSendingTextView()
        textView.delegate = context.coordinator
        textView.onSend = onSend
        configure(textView)

        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        textView.onSend = onSend
        applyColors(to: textView)
        if textView.string != text { textView.string = text }
        if isFocused.wrappedValue, scrollView.window?.firstResponder != textView {
            scrollView.window?.makeFirstResponder(textView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isFocused: isFocused)
    }

    private func configure(_ textView: EnterSendingTextView) {
        textView.isRichText = false
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.font = AppFont.sansNSFont(16)
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.string = text
        applyColors(to: textView)
    }

    private func applyColors(to textView: EnterSendingTextView) {
        let nsColor = NSColor(textColor)
        textView.textColor = nsColor
        textView.insertionPointColor = nsColor
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        var isFocused: FocusState<Bool>.Binding
        weak var textView: EnterSendingTextView?

        init(text: Binding<String>, isFocused: FocusState<Bool>.Binding) {
            _text = text
            self.isFocused = isFocused
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
        }

        func textDidBeginEditing(_ notification: Notification) {
            isFocused.wrappedValue = true
        }
    }
}

private final class EnterSendingTextView: NSTextView {
    var onSend: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let isReturnKey = event.keyCode == 36 || event.keyCode == 76
        if isReturnKey {
            if event.modifierFlags.contains(.shift) {
                insertNewline(nil)
            } else {
                onSend?()
            }
            return
        }
        super.keyDown(with: event)
    }
}
