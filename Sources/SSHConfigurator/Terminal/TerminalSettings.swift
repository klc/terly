import AppKit
import SwiftUI

@MainActor
final class TerminalSettings: ObservableObject {
    static let shared = TerminalSettings()

    @Published var fontSize: Double {
        didSet {
            UserDefaults.standard.set(fontSize, forKey: "terminal.fontSize")
            invalidateResolvedFont()
        }
    }

    @Published var fontName: String {
        didSet {
            UserDefaults.standard.set(fontName, forKey: "terminal.fontName")
            invalidateResolvedFont()
        }
    }

    @Published var themeID: String {
        didSet {
            UserDefaults.standard.set(themeID, forKey: "terminal.themeID")
            invalidateResolvedTheme()
        }
    }

    /// Cached `NSFont` for the current `fontName`/`fontSize`. `NSFont(name:)` lookups
    /// are not free, so terminal surfaces should read this instead of resolving a
    /// font on every `updateNSView`. Recomputed lazily whenever the underlying
    /// settings change.
    private(set) lazy var resolvedFont: NSFont = Self.makeFont(name: fontName, size: fontSize)

    /// Cached theme lookup for `themeID`, following the same pattern as `resolvedFont`
    /// so terminal surfaces can read a resolved value instead of scanning the catalog
    /// on every `updateNSView`.
    private(set) lazy var resolvedTheme: TerminalTheme = TerminalThemeCatalog.theme(withID: themeID)

    private init() {
        let savedSize = UserDefaults.standard.double(forKey: "terminal.fontSize")
        self.fontSize = savedSize > 0 ? savedSize : 13.0
        self.fontName = UserDefaults.standard.string(forKey: "terminal.fontName") ?? "SF Mono"
        self.themeID = UserDefaults.standard.string(forKey: "terminal.themeID") ?? TerminalThemeCatalog.system.id
    }

    private func invalidateResolvedFont() {
        resolvedFont = Self.makeFont(name: fontName, size: fontSize)
    }

    private func invalidateResolvedTheme() {
        resolvedTheme = TerminalThemeCatalog.theme(withID: themeID)
    }

    private static func makeFont(name: String, size: Double) -> NSFont {
        if name == "SF Mono" {
            return .monospacedSystemFont(ofSize: CGFloat(size), weight: .regular)
        } else {
            return NSFont(name: name, size: CGFloat(size)) ?? .monospacedSystemFont(ofSize: CGFloat(size), weight: .regular)
        }
    }
}

struct TerminalSettingsView: View {
    @ObservedObject var settings = TerminalSettings.shared
    
    let availableFonts = [
        "SF Mono",
        "Menlo",
        "Monaco",
        "Courier New",
        "Courier",
        "Andale Mono"
    ]
    
    var body: some View {
        Form {
            Section {
                Picker("Yazı Tipi:", selection: $settings.fontName) {
                    Text("Sistem (SF Mono)").tag("SF Mono")
                    ForEach(availableFonts.filter { $0 != "SF Mono" }, id: \.self) { font in
                        Text(font).tag(font)
                    }
                }
                
                HStack {
                    Slider(value: $settings.fontSize, in: 9...24, step: 1) {
                        Text("Yazı Boyutu:")
                    }
                    Text("\(Int(settings.fontSize)) pt")
                        .font(.body.monospacedDigit())
                        .frame(width: 45, alignment: .trailing)
                }

                Picker("Tema:", selection: $settings.themeID) {
                    ForEach(TerminalThemeCatalog.all) { theme in
                        Text(theme.displayName).tag(theme.id)
                    }
                }
            } header: {
                Text("Görünüm")
            }

            Section {
                themePreview
            } header: {
                Text("Önizleme")
            }
        }
        .padding()
        .frame(width: 520)
    }

    private var fontPreview: Font {
        if settings.fontName == "SF Mono" {
            return .system(size: CGFloat(settings.fontSize), weight: .regular, design: .monospaced)
        } else {
            return .custom(settings.fontName, size: CGFloat(settings.fontSize))
        }
    }

    private var themePreview: some View {
        let palette = settings.resolvedTheme.palette
        return VStack(alignment: .leading, spacing: 6) {
            Text("$ echo \"Merhaba Dünya!\"")
                .font(fontPreview)
                .foregroundColor(color(palette.foreground))
            Text("Merhaba Dünya!")
                .font(fontPreview)
                .foregroundColor(color(palette.ansi[2]))
            HStack(spacing: 3) {
                ForEach(Array(palette.ansi.enumerated()), id: \.offset) { _, ansiColor in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color(ansiColor))
                        .frame(width: 14, height: 14)
                }
            }
            .padding(.top, 2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color(palette.background))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.primary.opacity(0.15))
        )
    }

    private func color(_ themeColor: TerminalThemeColor) -> Color {
        Color(nsColor: themeColor.nsColor)
    }
}
