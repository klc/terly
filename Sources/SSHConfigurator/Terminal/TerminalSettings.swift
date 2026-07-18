import AppKit
import SwiftUI
@preconcurrency import SwiftTerm

/// Identifies the shape of the terminal text cursor, independent of whether it
/// blinks. Mirrors the shape half of SwiftTerm's `CursorStyle` enum so it can be
/// stored/persisted without pulling SwiftTerm's blink variants into the picker.
enum TerminalCursorShape: String, CaseIterable {
    case block
    case bar
    case underline
}

/// Combines a cursor shape with the blink toggle to resolve SwiftTerm's own
/// `CursorStyle` enum, which encodes shape and blink as a single case. Kept as a
/// free function (not a `TerminalSettings` method) so it is testable without
/// touching the `@MainActor` singleton.
func resolveCursorStyle(shape: TerminalCursorShape, blinks: Bool) -> CursorStyle {
    switch (shape, blinks) {
    case (.block, true): return .blinkBlock
    case (.block, false): return .steadyBlock
    case (.bar, true): return .blinkBar
    case (.bar, false): return .steadyBar
    case (.underline, true): return .blinkUnderline
    case (.underline, false): return .steadyUnderline
    }
}

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

    @Published var cursorStyleID: String {
        didSet {
            UserDefaults.standard.set(cursorStyleID, forKey: "terminal.cursorStyle")
            invalidateResolvedCursorStyle()
        }
    }

    @Published var cursorBlinks: Bool {
        didSet {
            UserDefaults.standard.set(cursorBlinks, forKey: "terminal.cursorBlinks")
            invalidateResolvedCursorStyle()
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

    /// Cached SwiftTerm `CursorStyle` combining `cursorStyleID`/`cursorBlinks`,
    /// following the same pattern as `resolvedFont`/`resolvedTheme`.
    private(set) lazy var resolvedCursorStyle: CursorStyle = Self.makeCursorStyle(
        cursorStyleID: cursorStyleID, blinks: cursorBlinks
    )

    private init() {
        let savedSize = UserDefaults.standard.double(forKey: "terminal.fontSize")
        self.fontSize = savedSize > 0 ? savedSize : 13.0
        self.fontName = UserDefaults.standard.string(forKey: "terminal.fontName") ?? "SF Mono"
        self.themeID = UserDefaults.standard.string(forKey: "terminal.themeID") ?? TerminalThemeCatalog.system.id
        self.cursorStyleID = UserDefaults.standard.string(forKey: "terminal.cursorStyle") ?? TerminalCursorShape.block.rawValue
        self.cursorBlinks = UserDefaults.standard.object(forKey: "terminal.cursorBlinks") as? Bool ?? true
    }

    private func invalidateResolvedFont() {
        resolvedFont = Self.makeFont(name: fontName, size: fontSize)
    }

    private func invalidateResolvedTheme() {
        resolvedTheme = TerminalThemeCatalog.theme(withID: themeID)
    }

    private func invalidateResolvedCursorStyle() {
        resolvedCursorStyle = Self.makeCursorStyle(cursorStyleID: cursorStyleID, blinks: cursorBlinks)
    }

    private static func makeFont(name: String, size: Double) -> NSFont {
        if name == "SF Mono" {
            return .monospacedSystemFont(ofSize: CGFloat(size), weight: .regular)
        } else {
            return NSFont(name: name, size: CGFloat(size)) ?? .monospacedSystemFont(ofSize: CGFloat(size), weight: .regular)
        }
    }

    private static func makeCursorStyle(cursorStyleID: String, blinks: Bool) -> CursorStyle {
        let shape = TerminalCursorShape(rawValue: cursorStyleID) ?? .block
        return resolveCursorStyle(shape: shape, blinks: blinks)
    }
}

struct TerminalSettingsView: View {
    @ObservedObject var settings = TerminalSettings.shared

    /// Installed monospace font families, computed once per view instance
    /// rather than on every `body` evaluation (`NSFontManager` family/trait
    /// lookups aren't free). "SF Mono" is handled separately as the special
    /// first picker entry mapping to `.monospacedSystemFont`, so it is
    /// excluded here even if a family with that exact name happens to be
    /// installed.
    let availableFonts: [String] = Self.installedMonospaceFontFamilies()

    var body: some View {
        Form {
            Section {
                Picker("Yazı Tipi:", selection: $settings.fontName) {
                    Text("Sistem (SF Mono)").tag("SF Mono")
                    ForEach(availableFonts, id: \.self) { font in
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

                Picker("İmleç:", selection: $settings.cursorStyleID) {
                    Text("Blok").tag(TerminalCursorShape.block.rawValue)
                    Text("Dikey Çizgi").tag(TerminalCursorShape.bar.rawValue)
                    Text("Alt Çizgi").tag(TerminalCursorShape.underline.rawValue)
                }

                Toggle("Yanıp sönme", isOn: $settings.cursorBlinks)
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

    private func color(_ themeColor: TerminalThemeColor) -> SwiftUI.Color {
        SwiftUI.Color(nsColor: themeColor.nsColor)
    }

    /// Scans installed font families for fixed-pitch (monospace) ones, using
    /// each family's regular member to decide — a family can mix fixed- and
    /// proportional-pitch faces, but its regular face is representative enough
    /// for a font picker. "SF Mono" is excluded since it's already offered as
    /// the special system entry above. Sorted alphabetically for a stable,
    /// predictable picker order.
    private static func installedMonospaceFontFamilies() -> [String] {
        let fontManager = NSFontManager.shared
        let families = fontManager.availableFontFamilies
        let monospaceFamilies = families.filter { family in
            guard family != "SF Mono" else { return false }
            guard let members = fontManager.availableMembers(ofFontFamily: family) else { return false }
            // Prefer the regular weight (NSFontManager encodes it as weight 5)
            // so families that mix fixed- and proportional-pitch faces (e.g. a
            // "Regular" that's monospace alongside a decorative "Italic" that
            // isn't) are judged by the face a user would actually pick by
            // default; fall back to the first listed member otherwise.
            let regularMember = members.first { ($0[2] as? Int) == 5 } ?? members.first
            guard let fontName = regularMember?[0] as? String else { return false }
            if let font = NSFont(name: fontName, size: 12), font.isFixedPitch {
                return true
            }
            let traits = NSFontDescriptor(name: fontName, size: 12).symbolicTraits
            return traits.contains(.monoSpace)
        }
        return monospaceFamilies.sorted()
    }
}
