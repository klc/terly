import SwiftUI

enum HelpPresentation: String, Identifiable {
    case help
    case orientation

    var id: String { rawValue }
}

struct HelpCenterView: View {
    let presentation: HelpPresentation
    let onCompleteOrientation: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                systemImage: presentation == .orientation ? "sparkles" : "questionmark.circle",
                title: presentation == .orientation
                    ? String(localized: "Welcome to Terly")
                    : String(localized: "Terly Help"),
                subtitle: presentation == .orientation
                    ? Text("A quick tour of the menus and terminal controls.")
                    : Text("A guide to connections, terminal controls, and keyboard shortcuts."),
                onClose: close
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    helpSection(
                        title: "Connections and sidebar",
                        systemImage: "sidebar.left",
                        rows: [
                            ("server.rack", "Select a connection to open its terminal."),
                            ("rectangle.split.2x1", "Hold ⌥ while clicking a connection to split it vertically in the current tab; add ⇧ for horizontal. You can also use the connection's shortcut menu or drag it onto a pane edge."),
                            ("plus", "Use + to add a server or connection group."),
                            ("gearshape", "Open connection settings; duplicate and transfer actions are beside it."),
                            ("magnifyingglass", "Use Quick Access or press \(AppShortcut.quickAccess.displayString) to find a connection from anywhere."),
                            ("terminal", "Local Terminal returns to its open tab; use the new tab button for a second one."),
                        ]
                    )

                    helpSection(
                        title: "Terminal buttons",
                        systemImage: "terminal",
                        rows: [
                            ("record.circle", "Start session recording and choose a folder to save it to. Press again to stop and reveal it in Finder."),
                            ("arrow.left.arrow.right", "Open file transfer for the active connection."),
                            ("plus.rectangle.on.rectangle", "Open the active terminal's connection again in a new tab (\(AppShortcut.newTab.displayString))."),
                            ("rectangle.split.2x1", "Split the active terminal vertically (\(AppShortcut.splitVertically.displayString))."),
                            ("rectangle.split.1x2", "Split it horizontally (\(AppShortcut.splitHorizontally.displayString))."),
                            ("arrow.up.left.and.arrow.down.right", "Zoom the active pane; use \(AppShortcut.zoomPane.displayString) to restore it."),
                            ("rectangle.portrait.and.arrow.right", "Close the selected terminal session."),
                            ("gearshape", "Change the terminal font, theme, cursor, and scroll behavior."),
                        ]
                    )

                    helpSection(
                        title: "Menus and shortcuts",
                        systemImage: "menubar.rectangle",
                        rows: [
                            ("doc.text", "File includes the raw config editor and change preview."),
                            ("gear", "Settings contains General, Terminal, Sync, and Updates."),
                            ("questionmark.circle", "Help opens this guide or restarts the welcome tour."),
                            ("magnifyingglass", "Find inside the active terminal with \(AppShortcut.findInTerminal.displayString); continue with \(AppShortcut.findNext.displayString) or \(AppShortcut.findPrevious.displayString)."),
                        ]
                    )

                    if presentation == .help {
                        helpSection(
                            title: "Session recording",
                            systemImage: "lock.doc",
                            rows: [
                                ("eye", "Only output shown by the terminal while recording is active is saved."),
                                ("folder", "Each recording is saved as a folder with one asciinema .cast file per pane, named after the pane's alias."),
                                ("play.rectangle", "Play a .cast file back with asciinema play <file>."),
                                ("lock", "The recording folder is created with owner-only permissions (0700) and each .cast file with 0600. They may contain sensitive data."),
                            ]
                        )
                    }
                }
                .padding(24)
            }

            Divider()

            HStack {
                if presentation == .orientation {
                    Text("You can reopen this tour later from Help → Welcome Tour.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(
                    presentation == .orientation
                        ? String(localized: "Get Started")
                        : String(localized: "Done")
                ) {
                    if presentation == .orientation {
                        onCompleteOrientation()
                    } else {
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 620, height: presentation == .orientation ? 650 : 700)
        .interactiveDismissDisabled(presentation == .orientation)
    }

    private func helpSection(
        title: LocalizedStringKey,
        systemImage: String,
        rows: [(String, LocalizedStringKey)]
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(rows.enumerated()), id: \.offset) { entry in
                    let row = entry.element
                    Label {
                        Text(row.1)
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: row.0)
                            .frame(width: 20)
                            .foregroundStyle(.tint)
                    }
                }
            }
            .padding(.leading, 4)
        }
    }

    private func close() {
        if presentation == .orientation {
            onCompleteOrientation()
        } else {
            dismiss()
        }
    }
}
