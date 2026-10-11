#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import AppKit

// The B preview's fallback fonts are not product fonts; keep native text and controls.
enum ManagementStyle {
    static let actionTint = Color(red: 103 / 255, green: 81 / 255, blue: 202 / 255)
    static let tint = adaptive(NSColor(red: 103 / 255, green: 81 / 255, blue: 202 / 255, alpha: 1),
                               dark: NSColor(red: 183 / 255, green: 166 / 255, blue: 255 / 255, alpha: 1))
    static let accentText = tint
    static let background = adaptive(NSColor(red: 246 / 255, green: 247 / 255, blue: 251 / 255, alpha: 1), dark: .windowBackgroundColor)
    static let sidebar = adaptive(NSColor(red: 240 / 255, green: 241 / 255, blue: 247 / 255, alpha: 1), dark: .underPageBackgroundColor)
    static let surface = adaptive(.white, dark: NSColor(red: 36 / 255, green: 36 / 255, blue: 44 / 255, alpha: 1))

    private static func adaptive(_ light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

extension View {
    func managementCard(selected: Bool = false) -> some View {
        background(selected ? ManagementStyle.tint.opacity(0.10) : ManagementStyle.surface,
                   in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(selected ? ManagementStyle.tint : Color.secondary.opacity(0.12), lineWidth: 1)
            }
    }
}

struct ManagementNavigationButton: View {
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.callout.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? ManagementStyle.accentText : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(selected ? ManagementStyle.tint.opacity(0.12) : .clear,
                            in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct ManagementSearchField: View {
    let prompt: String
    @Binding var text: String
    let identifier: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(prompt, text: $text).textFieldStyle(.plain)
                .accessibilityLabel(prompt).accessibilityIdentifier(identifier)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("清除搜索")
                    .accessibilityIdentifier("management-search-clear")
            }
        }
        .padding(9)
        .managementCard()
    }
}
#endif
