#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI

struct StatusBar: View {
    let app: AppModel

    var body: some View {
        HStack(spacing: 8) {
            if app.isDirty {
                Circle()
                    .fill(.orange)
                    .frame(width: 8, height: 8)
                    .help("有未保存的修改")
                    .accessibilityLabel("有未保存的修改")
            }
            Text(app.displayPath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            Spacer(minLength: 16)

            if let status = app.status {
                Text(status.text)
                    .font(.caption)
                    .foregroundStyle(status.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
#endif
