import SwiftUI
import AppKit

/// Patch applied (or rejected) at the last ROM load: format, file, status
/// and the BPS metadata blob. Observes `emulator.patch`, which only changes
/// on a ROM load, so subscribing doesn't cost a 60 Hz re-render.
struct PatchInfoView: View {
    let emulator: Emulator

    var body: some View {
        Group {
            if let patch = emulator.patch {
                detail(patch)
            } else {
                ContentUnavailableView("No Patch",
                                       systemImage: "bandage",
                                       description: Text("No .bps or .ips sat next to the loaded ROM."))
            }
        }
        .frame(minWidth: 420, minHeight: 280)
    }

    private func detail(_ patch: Emulator.PatchInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("Format").foregroundStyle(.secondary)
                    Text(patch.kind.uppercased()).font(.body.monospaced())
                }
                GridRow {
                    Text("File").foregroundStyle(.secondary)
                    HStack {
                        Text(patch.path)
                            .font(.body.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: patch.path)])
                        } label: {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(.borderless)
                        .help("Reveal in Finder")
                    }
                }
                GridRow {
                    Text("Status").foregroundStyle(.secondary)
                    if patch.applied {
                        Label("Applied", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Rejected: \(patch.status)", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                }
            }
            Divider()
            Text("Metadata").font(.headline)
            if patch.metadata.isEmpty {
                Text(patch.kind == "bps" ? "This BPS carries no metadata." : "IPS patches carry no metadata.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView([.vertical, .horizontal]) {
                    Text(patch.metadata)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding()
    }
}
