import SwiftUI

struct StartupFlowLaunchPreviewItem: Identifiable, Equatable {
    let target: SSHConnectionTarget
    let profile: StartupFlowProfile?

    var id: String { target.alias }
}

struct StartupFlowLaunchPreviewSheet: View {
    let items: [StartupFlowLaunchPreviewItem]
    let onRun: () -> Void
    let onSkip: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                title: items.count == 1 ? "Bağlantı başlangıç akışı" : "Grup başlangıç akışları",
                subtitle: Text("SSH bağlantısı açılmadan önce otomatik çalışacak adımları kontrol et.").font(.caption),
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
                        Text("Otomatik başlangıç akışı yok")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 5)
            }

            Divider()

            HStack {
                Label(
                    "Tüm başlangıç akışları tek SSH bootstrap komutu olarak çalışır.",
                    systemImage: "shield.lefthalf.filled"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                Spacer()
                Button(items.count == 1 ? "Bu sefer atla" : "Tümünü bu sefer atla") {
                    dismiss()
                    onSkip()
                }
                Button("Bağlan ve çalıştır") {
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
            Section("Yetim başlangıç akışları") {
                ForEach(records) { record in
                    Menu {
                        ForEach(aliases, id: \.self) { alias in
                            Button(alias) { onReassign(record.id, alias) }
                        }
                    } label: {
                        Label(record.profile.alias, systemImage: "link.badge.plus")
                    }
                    .help("Config dışında kaybolan alias için yeni bir bağlantı seç")
                }
            }
        }
    }
}
