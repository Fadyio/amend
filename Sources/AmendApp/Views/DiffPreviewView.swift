import SwiftUI
import AmendCore

public struct DiffPreviewView: View {
    public let result: GrammarRewriteResult
    public let actionTitle: String
    public let onApply: (String) -> Void
    public let onCancel: () -> Void

    public init(
        result: GrammarRewriteResult,
        actionTitle: String,
        onApply: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.result = result
        self.actionTitle = actionTitle
        self.onApply = onApply
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "wand.and.stars")
                    .font(.title2)
                    .foregroundStyle(AmendTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(actionTitle)
                        .font(.headline.bold())
                        .foregroundStyle(.primary)
                    Text("Review the changes below before replacing your narration text.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            // Original vs Proposed Comparison (Phase 13)
            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ORIGINAL")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)

                    Text(result.originalText)
                        .font(.system(size: 13))
                        .lineSpacing(4)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .glassPanel(cornerRadius: AmendTheme.cornerRadiusSmall)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("PROPOSED")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(AmendTheme.accent)

                    Text(diffAttributedString)
                        .font(.system(size: 13))
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .glassPanel(cornerRadius: AmendTheme.cornerRadiusSmall)
                }
            }

            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    Circle().fill(AmendTheme.statusError.opacity(0.6)).frame(width: 7, height: 7)
                    Text("Removed").font(.caption2).foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    Circle().fill(AmendTheme.statusSuccess.opacity(0.8)).frame(width: 7, height: 7)
                    Text("Added").font(.caption2).foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack {
                Button("Cancel", role: .cancel) {
                    onCancel()
                }
                .buttonStyle(GlassButtonStyle())
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Apply") {
                    onApply(result.rewrittenText)
                }
                .buttonStyle(GlassButtonStyle(isProminent: true))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(AmendTheme.panelGraphite)
    }

    private var diffAttributedString: AttributedString {
        var str = AttributedString()
        for chunk in result.diff {
            var chunkStr = AttributedString(chunk.text + " ")
            switch chunk.type {
            case .unchanged:
                chunkStr.foregroundColor = .primary
            case .added:
                chunkStr.foregroundColor = AmendTheme.statusSuccess
                chunkStr.backgroundColor = AmendTheme.statusSuccess.opacity(0.18)
                chunkStr.inlinePresentationIntent = .stronglyEmphasized
            case .deleted:
                chunkStr.foregroundColor = AmendTheme.statusError
                chunkStr.backgroundColor = AmendTheme.statusError.opacity(0.18)
                chunkStr.strikethroughStyle = .single
            }
            str.append(chunkStr)
        }
        return str
    }
}
