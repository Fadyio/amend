import SwiftUI
import MacDubCore

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
            HStack {
                Image(systemName: "text.badge.checkmark")
                    .font(.title)
                    .foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 2) {
                    Text(actionTitle)
                        .font(.title2.bold())
                    Text("Review the changes below before replacing your narration text. Original transcript is always preserved.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            Text("Changes Preview:")
                .font(.headline)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // Inline Diff Flow
                    Text(diffAttributedString)
                        .font(.body)
                        .lineSpacing(6)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    HStack(spacing: 16) {
                        HStack(spacing: 4) {
                            Circle().fill(Color.red.opacity(0.4)).frame(width: 8, height: 8)
                            Text("Removed").font(.caption).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 4) {
                            Circle().fill(Color.green.opacity(0.4)).frame(width: 8, height: 8)
                            Text("Added").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(height: 140)

            Divider()

            HStack {
                Button("Cancel", role: .cancel) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Apply Rewrite") {
                    onApply(result.rewrittenText)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var diffAttributedString: AttributedString {
        var str = AttributedString()
        for chunk in result.diff {
            var chunkStr = AttributedString(chunk.text + " ")
            switch chunk.type {
            case .unchanged:
                chunkStr.foregroundColor = .primary
            case .added:
                chunkStr.foregroundColor = .green
                chunkStr.backgroundColor = Color.green.opacity(0.15)
                chunkStr.inlinePresentationIntent = .stronglyEmphasized
            case .deleted:
                chunkStr.foregroundColor = .red
                chunkStr.backgroundColor = Color.red.opacity(0.15)
                chunkStr.strikethroughStyle = .single
            }
            str.append(chunkStr)
        }
        return str
    }
}
