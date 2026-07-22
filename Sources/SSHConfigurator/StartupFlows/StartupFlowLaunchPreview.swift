import SwiftUI

struct StartupFlowLaunchPreviewItem: Identifiable, Equatable {
    let id = UUID()
    let target: SSHConnectionTarget
    let profile: StartupFlowProfile?
}

struct StartupFlowLaunchPreviewSheet: View {
    let items: [StartupFlowLaunchPreviewItem]
    let onRun: () -> Void
    let onSkip: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                title: items.count == 1 ? String(localized: "Connection startup flow") : String(localized: "Group startup flows"),
                subtitle: Text("Review the steps that will run automatically before the SSH connection opens.").font(.caption),
                onClose: { dismiss() }
            )

            Divider()

            List(items) { item in
                VStack(alignment: .leading, spacing: 7) {
                    Label(item.target.alias, systemImage: "server.rack")
                        .font(.subheadline.weight(.semibold))

                    if let profile = item.profile,
                       profile.automaticallyRun,
                       !profile.steps.isEmpty {
                        ForEach(Array(profile.steps.enumerated()), id: \.element.id) { index, step in
                            HStack(alignment: .firstTextBaseline) {
                                Text("\(index + 1).")
                                    .foregroundStyle(.secondary)
                                Text(step.summary)
                                    .font(.system(.caption, design: .monospaced))
                            }
                        }
                    } else {
                        Text("No automatic startup flow")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 5)
            }

            Divider()

            HStack {
                Label(
                    "All startup flows run as a single SSH bootstrap command.",
                    systemImage: "shield.lefthalf.filled"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                Spacer()
                Button(items.count == 1 ? "Skip this time" : "Skip all this time") {
                    dismiss()
                    onSkip()
                }
                Button("Connect and run") {
                    dismiss()
                    onRun()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 590, minHeight: 460)
    }
}

struct StartupFlowOrphanSection: View {
    let records: [StartupFlowRecord]
    let aliases: [String]
    let onReassign: (UUID, String) -> Void

    var body: some View {
        if !records.isEmpty {
            Section("Orphaned startup flows") {
                ForEach(records) { record in
                    Menu {
                        ForEach(aliases, id: \.self) { alias in
                            Button(alias) { onReassign(record.id, alias) }
                        }
                    } label: {
                        Label(record.profile.alias, systemImage: "link.badge.plus")
                    }
                    .help("Select a new connection for an alias that's missing from the config")
                }
            }
        }
    }
}
