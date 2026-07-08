import SwiftUI

struct ComposerAttachmentMenu: View {
    @Environment(\.themeColors) private var colors
    let onPickImage: () -> Void
    let onPickFile: () -> Void
    let onPasteImage: () -> Void
    var onComingSoon: (String) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            AttachmentMenuRow(icon: "paperclip", title: "Add photos & files") { onPickFile() }
            AttachmentMenuRow(icon: "doc.on.clipboard", title: "Paste image") { onPasteImage() }

            Divider()
                .overlay(colors.borderSubtle)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)

            AttachmentMenuRow(icon: "photo", title: "Create image") { onComingSoon("Image generation") }
            AttachmentMenuRow(icon: "lightbulb", title: "Thinking") { onComingSoon("Extended thinking") }
            AttachmentMenuRow(icon: "binoculars", title: "Deep research") { onComingSoon("Deep research") }
            AttachmentMenuRow(icon: "bag", title: "Shopping research") { onComingSoon("Shopping research") }
            AttachmentMenuRow(icon: "ellipsis", title: "More", showsChevron: true) { onComingSoon("More tools") }
        }
        .padding(.vertical, 6)
        .frame(width: 260)
        .background(colors.backgroundPopover)
        .presentationBackground(colors.backgroundPopover)
    }
}

private struct AttachmentMenuRow: View {
    @Environment(\.themeColors) private var colors
    let icon: String
    let title: String
    var showsChevron: Bool = false
    var action: () -> Void = {}

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(colors.textPrimary.opacity(0.85))
                    .frame(width: 22)

                Text(title)
                    .font(.system(size: 14))
                    .foregroundStyle(colors.textPrimary)

                Spacer(minLength: 0)

                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(colors.textTertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered ? colors.backgroundHover : .clear)
            )
            .contentShape(Rectangle())
            .padding(.horizontal, 6)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

struct PendingAttachmentsBar: View {
    let attachments: [MessageAttachment]
    let onRemove: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(attachments) { attachment in
                    PendingAttachmentChip(attachment: attachment) {
                        onRemove(attachment.id)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 8)
    }
}

private struct PendingAttachmentChip: View {
    @Environment(\.themeColors) private var colors
    let attachment: MessageAttachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if attachment.kind == .image,
               let image = AttachmentStore.loadImage(for: attachment) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Image(systemName: "doc.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(colors.textSecondary)
                    .frame(width: 36, height: 36)
                    .background(colors.backgroundInput)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.fileName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(colors.textPrimary)
                    .lineLimit(1)

                Text(attachment.kind == .image ? "Image" : "File")
                    .font(.system(size: 10))
                    .foregroundStyle(colors.textSecondary)
            }

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(colors.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(colors.backgroundChip)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(colors.borderSubtle, lineWidth: 1)
        )
    }
}

struct MessageAttachmentsView: View {
    @Environment(\.themeColors) private var colors
    let attachments: [MessageAttachment]

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(attachments) { attachment in
                if attachment.kind == .image,
                   let image = AttachmentStore.loadImage(for: attachment) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 220, maxHeight: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.fill")
                        Text(attachment.fileName)
                            .lineLimit(1)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(colors.textPrimary.opacity(0.85))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(colors.backgroundChipSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
    }
}
