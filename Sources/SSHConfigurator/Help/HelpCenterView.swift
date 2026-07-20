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
                            ("plus", "Use + to add a server or connection group."),
                            ("gearshape", "Open connection settings; duplicate and transfer actions are beside it."),
                            ("magnifyingglass", "Use Quick Access or press ⌘K to find a connection from anywhere."),
                        ]
                    )

                    helpSection(
                        title: "Terminal buttons",
                        systemImage: "terminal",
                        rows: [
                            ("record.circle", "Start session recording and choose a .log file. Press again to stop."),
                            ("arrow.left.arrow.right", "Open file transfer for the active connection."),
                            ("rectangle.split.2x1", "Split the active terminal vertically (⌘D)."),
                            ("rectangle.split.1x2", "Split it horizontally (⇧⌘D)."),
                            ("arrow.up.left.and.arrow.down.right", "Zoom the active pane; use ⇧⌘Return to restore it."),
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
                            ("magnifyingglass", "Find inside the active terminal with ⌘F; continue with ⌘G or ⇧⌘G."),
                        ]
                    )

                    if presentation == .help {
                        helpSection(
                            title: "Session recording",
                            systemImage: "lock.doc",
                            rows: [
                                ("eye", "Only output shown by the terminal while recording is active is saved."),
                                ("rectangle.split.3x1", "All panes in the recorded tab are written to the same file with pane separators."),
                                ("lock", "Recordings are created with owner-only file permissions (0600). They may contain sensitive data."),
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
