import AppKit
@preconcurrency import SwiftTerm

/// A single RGB color value used to describe a terminal theme. Stored as 8-bit
/// components so palettes can be written as compact hex literals in the catalog
/// below, and converted on demand to whatever color type the call site needs
/// (`NSColor` for the surrounding AppKit chrome, SwiftTerm's own `Color` for the
/// ANSI palette SwiftTerm installs into the terminal engine).
struct TerminalThemeColor: Equatable, Sendable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    init(_ red: UInt8, _ green: UInt8, _ blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Parses a `#RRGGBB` or `RRGGBB` hex string. Returns `nil` for any other
    /// length or non-hex characters (no `#RGB`/alpha shorthand — the catalog
    /// below always writes full 6-digit values).
    init?(hex: String) {
        var value = hex
        if value.hasPrefix("#") {
            value.removeFirst()
        }
        guard value.count == 6, let intValue = UInt32(value, radix: 16) else {
            return nil
        }
        red = UInt8((intValue >> 16) & 0xFF)
        green = UInt8((intValue >> 8) & 0xFF)
        blue = UInt8(intValue & 0xFF)
    }

    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    }

    /// SwiftTerm's palette color type stores components in the 0...65535 range;
    /// `installColors`/`installPalette` expect an array of these.
    var swiftTermColor: SwiftTerm.Color {
        SwiftTerm.Color(red: UInt16(red) * 257, green: UInt16(green) * 257, blue: UInt16(blue) * 257)
    }
}

/// The full set of colors a terminal theme controls: the 16 ANSI palette
/// entries SwiftTerm uses to resolve SGR color codes, plus the surface
/// background/foreground and the text cursor.
///
/// `cursor` is optional so a theme can defer to the platform's dynamic accent
/// color instead of a fixed value — only the built-in "system" theme does
/// this today, to preserve the app's pre-theme behavior exactly.
struct TerminalColorPalette: Equatable, Sendable {
    let ansi: [TerminalThemeColor]
    let background: TerminalThemeColor
    let foreground: TerminalThemeColor
    let cursor: TerminalThemeColor?

    init(ansi: [TerminalThemeColor], background: TerminalThemeColor, foreground: TerminalThemeColor, cursor: TerminalThemeColor?) {
        precondition(ansi.count == 16, "Terminal color palette must define exactly 16 ANSI colors")
        self.ansi = ansi
        self.background = background
        self.foreground = foreground
        self.cursor = cursor
    }
}

struct TerminalTheme: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let palette: TerminalColorPalette
}

/// Built-in terminal color themes. Values are the published/reference hex
/// colors for each theme (Solarized: ethanschoonover.com/solarized; Dracula:
/// draculatheme.com/contribute; Nord: nordtheme.com; Gruvbox: morhetz/gruvbox;
/// One Dark: the widely-ported Atom "One Dark" terminal palette; Tokyo Night:
/// folke/tokyonight.nvim; Catppuccin: catppuccin/catppuccin; Monokai: the
/// classic Sublime Text "Monokai" scheme as reproduced by most terminal theme
/// collections). No import or custom-theme-file support — that is explicitly
/// out of scope for 1.0.
enum TerminalThemeCatalog {
    /// Matches the app's original hardcoded terminal appearance exactly:
    /// same ANSI 16 (macOS Terminal.app's default "Basic" palette, which is
    /// also SwiftTerm's own built-in default) and the same background/
    /// foreground constants used before themes existed. The cursor is left
    /// `nil` so it keeps following the system accent color, as it always has.
    static let system = TerminalTheme(
        id: "system",
        displayName: String(localized: "System"),
        palette: TerminalColorPalette(
            // Byte-for-byte SwiftTerm's `Color.defaultInstalledColors`, so
            // selecting "Sistem" (or switching back to it from another theme)
            // reproduces the library's untouched ANSI palette exactly.
            ansi: [
                TerminalThemeColor(0x00, 0x00, 0x00),
                TerminalThemeColor(0x99, 0x00, 0x01),
                TerminalThemeColor(0x00, 0xA6, 0x03),
                TerminalThemeColor(0x99, 0x99, 0x00),
                TerminalThemeColor(0x03, 0x00, 0xB2),
                TerminalThemeColor(0xB2, 0x00, 0xB2),
                TerminalThemeColor(0x00, 0xA5, 0xB2),
                TerminalThemeColor(0xBF, 0xBF, 0xBF),
                TerminalThemeColor(0x8A, 0x89, 0x8A),
                TerminalThemeColor(0xE5, 0x00, 0x01),
                TerminalThemeColor(0x00, 0xD8, 0x00),
                TerminalThemeColor(0xE5, 0xE5, 0x00),
                TerminalThemeColor(0x07, 0x00, 0xFE),
                TerminalThemeColor(0xE5, 0x00, 0xE5),
                TerminalThemeColor(0x00, 0xE5, 0xE5),
                TerminalThemeColor(0xE5, 0xE5, 0xE5),
            ],
            background: TerminalThemeColor(0x09, 0x0B, 0x0E),
            foreground: TerminalThemeColor(0xEB, 0xEB, 0xEB),
            cursor: nil
        )
    )

    /// Solarized's 16 ANSI values are identical across the dark/light
    /// variants; only background/foreground/cursor swap.
    private static let solarizedAnsi: [TerminalThemeColor] = [
        TerminalThemeColor(hex: "073642")!,
        TerminalThemeColor(hex: "dc322f")!,
        TerminalThemeColor(hex: "859900")!,
        TerminalThemeColor(hex: "b58900")!,
        TerminalThemeColor(hex: "268bd2")!,
        TerminalThemeColor(hex: "d33682")!,
        TerminalThemeColor(hex: "2aa198")!,
        TerminalThemeColor(hex: "eee8d5")!,
        TerminalThemeColor(hex: "002b36")!,
        TerminalThemeColor(hex: "cb4b16")!,
        TerminalThemeColor(hex: "586e75")!,
        TerminalThemeColor(hex: "657b83")!,
        TerminalThemeColor(hex: "839496")!,
        TerminalThemeColor(hex: "6c71c4")!,
        TerminalThemeColor(hex: "93a1a1")!,
        TerminalThemeColor(hex: "fdf6e3")!,
    ]

    static let solarizedDark = TerminalTheme(
        id: "solarizedDark",
        displayName: "Solarized Dark",
        palette: TerminalColorPalette(
            ansi: solarizedAnsi,
            background: TerminalThemeColor(hex: "002b36")!,
            foreground: TerminalThemeColor(hex: "839496")!,
            cursor: TerminalThemeColor(hex: "93a1a1")!
        )
    )

    static let solarizedLight = TerminalTheme(
        id: "solarizedLight",
        displayName: "Solarized Light",
        palette: TerminalColorPalette(
            ansi: solarizedAnsi,
            background: TerminalThemeColor(hex: "fdf6e3")!,
            foreground: TerminalThemeColor(hex: "657b83")!,
            cursor: TerminalThemeColor(hex: "586e75")!
        )
    )

    static let dracula = TerminalTheme(
        id: "dracula",
        displayName: "Dracula",
        palette: TerminalColorPalette(
            ansi: [
                TerminalThemeColor(hex: "21222c")!,
                TerminalThemeColor(hex: "ff5555")!,
                TerminalThemeColor(hex: "50fa7b")!,
                TerminalThemeColor(hex: "f1fa8c")!,
                TerminalThemeColor(hex: "bd93f9")!,
                TerminalThemeColor(hex: "ff79c6")!,
                TerminalThemeColor(hex: "8be9fd")!,
                TerminalThemeColor(hex: "f8f8f2")!,
                TerminalThemeColor(hex: "6272a4")!,
                TerminalThemeColor(hex: "ff6e6e")!,
                TerminalThemeColor(hex: "69ff94")!,
                TerminalThemeColor(hex: "ffffa5")!,
                TerminalThemeColor(hex: "d6acff")!,
                TerminalThemeColor(hex: "ff92df")!,
                TerminalThemeColor(hex: "a4ffff")!,
                TerminalThemeColor(hex: "ffffff")!,
            ],
            background: TerminalThemeColor(hex: "282a36")!,
            foreground: TerminalThemeColor(hex: "f8f8f2")!,
            cursor: TerminalThemeColor(hex: "f8f8f2")!
        )
    )

    static let nord = TerminalTheme(
        id: "nord",
        displayName: "Nord",
        palette: TerminalColorPalette(
            ansi: [
                TerminalThemeColor(hex: "3b4252")!,
                TerminalThemeColor(hex: "bf616a")!,
                TerminalThemeColor(hex: "a3be8c")!,
                TerminalThemeColor(hex: "ebcb8b")!,
                TerminalThemeColor(hex: "81a1c1")!,
                TerminalThemeColor(hex: "b48ead")!,
                TerminalThemeColor(hex: "88c0d0")!,
                TerminalThemeColor(hex: "e5e9f0")!,
                TerminalThemeColor(hex: "4c566a")!,
                TerminalThemeColor(hex: "bf616a")!,
                TerminalThemeColor(hex: "a3be8c")!,
                TerminalThemeColor(hex: "ebcb8b")!,
                TerminalThemeColor(hex: "81a1c1")!,
                TerminalThemeColor(hex: "b48ead")!,
                TerminalThemeColor(hex: "8fbcbb")!,
                TerminalThemeColor(hex: "eceff4")!,
            ],
            background: TerminalThemeColor(hex: "2e3440")!,
            foreground: TerminalThemeColor(hex: "d8dee9")!,
            cursor: TerminalThemeColor(hex: "d8dee9")!
        )
    )

    static let oneDark = TerminalTheme(
        id: "oneDark",
        displayName: "One Dark",
        palette: TerminalColorPalette(
            ansi: [
                TerminalThemeColor(hex: "282c34")!,
                TerminalThemeColor(hex: "e06c75")!,
                TerminalThemeColor(hex: "98c379")!,
                TerminalThemeColor(hex: "e5c07b")!,
                TerminalThemeColor(hex: "61afef")!,
                TerminalThemeColor(hex: "c678dd")!,
                TerminalThemeColor(hex: "56b6c2")!,
                TerminalThemeColor(hex: "abb2bf")!,
                TerminalThemeColor(hex: "5c6370")!,
                TerminalThemeColor(hex: "e06c75")!,
                TerminalThemeColor(hex: "98c379")!,
                TerminalThemeColor(hex: "e5c07b")!,
                TerminalThemeColor(hex: "61afef")!,
                TerminalThemeColor(hex: "c678dd")!,
                TerminalThemeColor(hex: "56b6c2")!,
                TerminalThemeColor(hex: "ffffff")!,
            ],
            background: TerminalThemeColor(hex: "282c34")!,
            foreground: TerminalThemeColor(hex: "abb2bf")!,
            cursor: TerminalThemeColor(hex: "528bff")!
        )
    )

    static let gruvboxDark = TerminalTheme(
        id: "gruvboxDark",
        displayName: "Gruvbox Dark",
        palette: TerminalColorPalette(
            ansi: [
                TerminalThemeColor(hex: "282828")!,
                TerminalThemeColor(hex: "cc241d")!,
                TerminalThemeColor(hex: "98971a")!,
                TerminalThemeColor(hex: "d79921")!,
                TerminalThemeColor(hex: "458588")!,
                TerminalThemeColor(hex: "b16286")!,
                TerminalThemeColor(hex: "689d6a")!,
                TerminalThemeColor(hex: "a89984")!,
                TerminalThemeColor(hex: "928374")!,
                TerminalThemeColor(hex: "fb4934")!,
                TerminalThemeColor(hex: "b8bb26")!,
                TerminalThemeColor(hex: "fabd2f")!,
                TerminalThemeColor(hex: "83a598")!,
                TerminalThemeColor(hex: "d3869b")!,
                TerminalThemeColor(hex: "8ec07c")!,
                TerminalThemeColor(hex: "ebdbb2")!,
            ],
            background: TerminalThemeColor(hex: "282828")!,
            foreground: TerminalThemeColor(hex: "ebdbb2")!,
            cursor: TerminalThemeColor(hex: "ebdbb2")!
        )
    )

    /// tokyonight.nvim's published "Night" terminal palette
    /// (github.com/folke/tokyonight.nvim, extras/kitty & extras/alacritty).
    static let tokyoNight = TerminalTheme(
        id: "tokyoNight",
        displayName: "Tokyo Night",
        palette: TerminalColorPalette(
            ansi: [
                TerminalThemeColor(hex: "15161e")!,
                TerminalThemeColor(hex: "f7768e")!,
                TerminalThemeColor(hex: "9ece6a")!,
                TerminalThemeColor(hex: "e0af68")!,
                TerminalThemeColor(hex: "7aa2f7")!,
                TerminalThemeColor(hex: "bb9af7")!,
                TerminalThemeColor(hex: "7dcfff")!,
                TerminalThemeColor(hex: "a9b1d6")!,
                TerminalThemeColor(hex: "414868")!,
                TerminalThemeColor(hex: "f7768e")!,
                TerminalThemeColor(hex: "9ece6a")!,
                TerminalThemeColor(hex: "e0af68")!,
                TerminalThemeColor(hex: "7aa2f7")!,
                TerminalThemeColor(hex: "bb9af7")!,
                TerminalThemeColor(hex: "7dcfff")!,
                TerminalThemeColor(hex: "c0caf5")!,
            ],
            background: TerminalThemeColor(hex: "1a1b26")!,
            foreground: TerminalThemeColor(hex: "c0caf5")!,
            cursor: TerminalThemeColor(hex: "c0caf5")!
        )
    )

    /// Catppuccin's published "Mocha" terminal palette
    /// (github.com/catppuccin/catppuccin, terminal color reference).
    static let catppuccinMocha = TerminalTheme(
        id: "catppuccinMocha",
        displayName: "Catppuccin Mocha",
        palette: TerminalColorPalette(
            ansi: [
                TerminalThemeColor(hex: "45475a")!,
                TerminalThemeColor(hex: "f38ba8")!,
                TerminalThemeColor(hex: "a6e3a1")!,
                TerminalThemeColor(hex: "f9e2af")!,
                TerminalThemeColor(hex: "89b4fa")!,
                TerminalThemeColor(hex: "f5c2e7")!,
                TerminalThemeColor(hex: "94e2d5")!,
                TerminalThemeColor(hex: "bac2de")!,
                TerminalThemeColor(hex: "585b70")!,
                TerminalThemeColor(hex: "f38ba8")!,
                TerminalThemeColor(hex: "a6e3a1")!,
                TerminalThemeColor(hex: "f9e2af")!,
                TerminalThemeColor(hex: "89b4fa")!,
                TerminalThemeColor(hex: "f5c2e7")!,
                TerminalThemeColor(hex: "94e2d5")!,
                TerminalThemeColor(hex: "a6adc8")!,
            ],
            background: TerminalThemeColor(hex: "1e1e2e")!,
            foreground: TerminalThemeColor(hex: "cdd6f4")!,
            cursor: TerminalThemeColor(hex: "f5e0dc")!
        )
    )

    /// Monokai's widely-ported terminal palette (monokai.pro / the classic
    /// Sublime Text "Monokai" color scheme, as reproduced by most terminal
    /// theme collections).
    static let monokai = TerminalTheme(
        id: "monokai",
        displayName: "Monokai",
        palette: TerminalColorPalette(
            ansi: [
                TerminalThemeColor(hex: "272822")!,
                TerminalThemeColor(hex: "f92672")!,
                TerminalThemeColor(hex: "a6e22e")!,
                TerminalThemeColor(hex: "f4bf75")!,
                TerminalThemeColor(hex: "66d9ef")!,
                TerminalThemeColor(hex: "ae81ff")!,
                TerminalThemeColor(hex: "a1efe4")!,
                TerminalThemeColor(hex: "f8f8f2")!,
                TerminalThemeColor(hex: "75715e")!,
                TerminalThemeColor(hex: "f92672")!,
                TerminalThemeColor(hex: "a6e22e")!,
                TerminalThemeColor(hex: "f4bf75")!,
                TerminalThemeColor(hex: "66d9ef")!,
                TerminalThemeColor(hex: "ae81ff")!,
                TerminalThemeColor(hex: "a1efe4")!,
                TerminalThemeColor(hex: "f9f8f5")!,
            ],
            background: TerminalThemeColor(hex: "272822")!,
            foreground: TerminalThemeColor(hex: "f8f8f2")!,
            cursor: TerminalThemeColor(hex: "f8f8f2")!
        )
    )

    /// github.com/morhetz/gruvbox's published light palette (the "medium"
    /// contrast light background variant, matching `gruvboxDark`'s own source).
    static let gruvboxLight = TerminalTheme(
        id: "gruvboxLight",
        displayName: "Gruvbox Light",
        palette: TerminalColorPalette(
            ansi: [
                TerminalThemeColor(hex: "fbf1c7")!,
                TerminalThemeColor(hex: "cc241d")!,
                TerminalThemeColor(hex: "98971a")!,
                TerminalThemeColor(hex: "d79921")!,
                TerminalThemeColor(hex: "458588")!,
                TerminalThemeColor(hex: "b16286")!,
                TerminalThemeColor(hex: "689d6a")!,
                TerminalThemeColor(hex: "7c6f64")!,
                TerminalThemeColor(hex: "928374")!,
                TerminalThemeColor(hex: "9d0006")!,
                TerminalThemeColor(hex: "79740e")!,
                TerminalThemeColor(hex: "b57614")!,
                TerminalThemeColor(hex: "076678")!,
                TerminalThemeColor(hex: "8f3f71")!,
                TerminalThemeColor(hex: "427b58")!,
                TerminalThemeColor(hex: "3c3836")!,
            ],
            background: TerminalThemeColor(hex: "fbf1c7")!,
            foreground: TerminalThemeColor(hex: "3c3836")!,
            cursor: TerminalThemeColor(hex: "3c3836")!
        )
    )

    static let all: [TerminalTheme] = [
        system, solarizedDark, solarizedLight, dracula, nord, oneDark, gruvboxDark,
        tokyoNight, catppuccinMocha, monokai, gruvboxLight,
    ]

    static func theme(withID id: String) -> TerminalTheme {
        all.first { $0.id == id } ?? system
    }
}
