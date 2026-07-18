import SwiftUI

/// Shared sheet header idiom: an optional leading icon, a headline title, a
/// secondary subtitle, and a trailing "Kapat" button bound to `.cancelAction`
/// (so Esc always closes the sheet).
///
/// The five custom headers this replaces don't all look identical — some have
/// no icon, one uses a larger icon size, one uses a monospaced subtitle — so
/// `iconFont` and `subtitle` (a pre-styled `Text`, not a plain `String`) exist
/// specifically to let each call site reproduce its original look exactly.
/// `accessory` renders between the title block and Kapat, for headers that had
/// extra trailing controls (e.g. a conditional "Yeniden çalıştır" button).
struct SheetHeader<Accessory: View>: View {
    let systemImage: String?
    let iconFont: Font?
    let title: String
    let subtitle: Text?
    let onClose: () -> Void
    @ViewBuilder let accessory: () -> Accessory

    init(
        systemImage: String? = nil,
        iconFont: Font? = nil,
        title: String,
        subtitle: Text? = nil,
        onClose: @escaping () -> Void,
        @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }
    ) {
        self.systemImage = systemImage
        self.iconFont = iconFont
        self.title = title
        self.subtitle = subtitle
        self.onClose = onClose
        self.accessory = accessory
    }

    var body: some View {
        HStack(spacing: 12) {
            if let systemImage {
                icon(named: systemImage)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                if let subtitle {
                    subtitle
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            accessory()
            Button("Kapat", action: onClose)
                .keyboardShortcut(.cancelAction)
        }
        .padding()
    }

    @ViewBuilder
    private func icon(named name: String) -> some View {
        if let iconFont {
            Image(systemName: name)
                .font(iconFont)
                .foregroundStyle(.secondary)
        } else {
            Image(systemName: name)
                .foregroundStyle(.secondary)
        }
    }
}
