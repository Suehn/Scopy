import SwiftUI
import AppKit
import ScopyKit
import ScopyUISupport

/// The row's label. Interaction and popover lifetimes stay in `HistoryItemView`; this view
/// draws the already-resolved presentation values and leaves clock observation to its time leaf.
@MainActor
struct HistoryItemRowLabel: View {
    let item: ClipboardItemDTO
    let descriptor: HistoryItemRowDescriptor
    let searchMatchContext: SearchMatchContext?
    let statusMessage: String?
    let quickSlot: Int?
    let interactionCoordinator: HistoryListInteractionCoordinator

    /// From the prewarmed icon cache, so the row body never waits on LaunchServices.
    private var appIcon: NSImage? {
        guard let bundleID = descriptor.appIconBundleID else { return nil }
        return IconService.shared.icon(bundleID: bundleID)
    }

    var body: some View {
        let profileStart = ScrollPerformanceProfile.isEnabled ? CFAbsoluteTimeGetCurrent() : nil
        defer {
            if let profileStart {
                ScrollPerformanceProfile.recordTiming(
                    name: "swiftui.row_label_body_ms",
                    elapsedMs: (CFAbsoluteTimeGetCurrent() - profileStart) * 1000
                )
            }
        }
        return HStack(alignment: .center, spacing: ScopySpacing.sm) {
            // Pinned rows carry a colored bar on the leading edge.
            if item.isPinned {
                Capsule()
                    .fill(ScopyColors.selectionBorder)
                    .frame(width: ScopySize.Width.pinIndicator, height: ScopySize.Height.pinIndicator)
            }

            if let icon = appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: ScopySize.Icon.listApp, height: ScopySize.Icon.listApp)
                    .cornerRadius(ScopySize.Corner.sm)
            } else {
                Image(systemName: ScopyIcons.app)
                    .font(.system(size: ScopySize.Icon.sm))
                    .foregroundStyle(ScopyColors.mutedText)
                    .frame(width: ScopySize.Icon.listApp, height: ScopySize.Icon.listApp)
            }

            contentView

            Spacer(minLength: ScopySpacing.md)

            if item.isPinned {
                Image(systemName: ScopyIcons.pin)
                    .font(.system(size: ScopySize.Icon.pin))
                    .foregroundStyle(.orange)
            }

            if let statusMessage, !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(ScopyTypography.microMono)
                    .foregroundStyle(ScopyColors.mutedText)
            }

            // While ⌘ is held the slot replaces the time in the same font, so the row height
            // and trailing layout do not move.
            if let quickSlot {
                Text(verbatim: "⌘\(quickSlot)")
                    .font(ScopyTypography.microMono)
                    .foregroundStyle(ScopyColors.mutedText)
            } else {
                HistoryItemRelativeTimeView(itemID: item.id, lastUsedAt: item.lastUsedAt)
                    .font(ScopyTypography.microMono)
                    .foregroundStyle(ScopyColors.mutedText)
            }
        }
    }

    /// Derived here rather than in `init`: SwiftUI re-initializes every `ForEach` child on every list
    /// update, but a row's body only runs when the row actually changed. Building the evidence text in
    /// `init` made each search keystroke pay one attributed string, one accessibility string and one
    /// descriptor lookup for every loaded row.
    private var searchEvidence: (text: AttributedString, accessibilityText: String)? {
        guard let searchMatchContext else { return nil }
        return (
            SearchMatchPresentation.attributedText(
                context: searchMatchContext,
                itemType: item.type,
                metadataPrefix: descriptor.searchMetadataPrefix
            ),
            SearchMatchPresentation.accessibilityDescription(
                context: searchMatchContext,
                itemType: item.type
            )
        )
    }

    @ViewBuilder
    private var secondaryLine: some View {
        if let searchEvidence {
            Text(searchEvidence.text)
                .accessibilityLabel(searchEvidence.accessibilityText)
                .accessibilityIdentifier("HistoryItem.MatchEvidence")
        } else {
            Text(descriptor.metadataText)
        }
    }

    @ViewBuilder
    private var contentView: some View {
        switch item.type {
        case .image where descriptor.showThumbnails:
            // With a thumbnail, an image row shows the thumbnail and its metadata, not an "Image" title.
            HStack(spacing: ScopySpacing.md) {
                HistoryItemThumbnailView(
                    thumbnailPath: item.thumbnailPath,
                    height: descriptor.thumbnailHeight,
                    interactionCoordinator: interactionCoordinator
                )
                secondaryLine
                    .font(ScopyTypography.caption)
                    .foregroundStyle(ScopyColors.mutedText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        case .file:
            HStack(spacing: ScopySpacing.sm) {
                if descriptor.canShowFileThumbnail {
                    HistoryItemFileThumbnailView(
                        thumbnailPath: item.thumbnailPath,
                        height: descriptor.thumbnailHeight,
                        kind: descriptor.filePreviewKind ?? .other,
                        interactionCoordinator: interactionCoordinator
                    )
                } else {
                    Image(systemName: ScopyIcons.file)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: descriptor.thumbnailHeight, height: descriptor.thumbnailHeight)
                }
                VStack(alignment: .leading, spacing: ScopySpacing.xxs) {
                    Text(descriptor.titleText)
                        .font(ScopyTypography.body)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    secondaryLine
                        .font(ScopyTypography.caption)
                        .foregroundStyle(ScopyColors.mutedText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        case .image:
            VStack(alignment: .leading, spacing: ScopySpacing.xxs) {
                HStack(spacing: ScopySpacing.sm) {
                    Image(systemName: ScopyIcons.image)
                        .foregroundStyle(.green)
                    Text(descriptor.titleText)
                        .font(ScopyTypography.body)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                secondaryLine
                    .font(ScopyTypography.caption)
                    .foregroundStyle(ScopyColors.mutedText)
                    .lineLimit(1)
                    .padding(.leading, ScopySpacing.md)
            }
        default:
            VStack(alignment: .leading, spacing: ScopySpacing.xxs) {
                Text(descriptor.titleText)
                    .font(ScopyTypography.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                secondaryLine
                    .font(ScopyTypography.caption)
                    .foregroundStyle(ScopyColors.mutedText)
                    .lineLimit(1)
                    .padding(.leading, ScopySpacing.md)
            }
        }
    }

}
