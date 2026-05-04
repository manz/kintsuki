import SwiftUI
import SwiftData
import AppKit

/// Grid of save states for the currently loaded ROM. Click a card to load,
/// double-click the title to rename, hover for delete.
struct SaveStateBrowserView: View {
    @EnvironmentObject var emulator: Emulator
    @Environment(\.dismiss) private var dismiss
    @Query private var entries: [SaveStateEntry]

    init(romPath: String) {
        let predicate = #Predicate<SaveStateEntry> { $0.romPath == romPath }
        _entries = Query(filter: predicate,
                         sort: [SortDescriptor(\.createdAt, order: .reverse)])
    }

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Save States").font(.title3).bold()
                if let url = emulator.loadedROM {
                    Text(url.lastPathComponent)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("New") {
                    emulator.saveState(named: "")
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(emulator.loadedROM == nil)
                Button("Import Mesen…") { importMesenState() }
                    .disabled(emulator.loadedROM == nil)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            if entries.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(entries) { entry in
                            SaveStateCard(entry: entry)
                                .environmentObject(emulator)
                                .onTapGesture(count: 2) {
                                    emulator.loadState(entry)
                                    dismiss()
                                }
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(minWidth: 540, minHeight: 380)
    }

    /// Pop an NSOpenPanel scoped to .mss files, then call the C ABI
    /// importer. Surfaces success/failure as a non-modal NSAlert so
    /// the user knows whether the state actually loaded.
    private func importMesenState() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Select a Mesen 2 savestate (.mss)"
        panel.prompt = "Import"
        if panel.runModal() == .OK, let url = panel.url {
            let ok = emulator.importMesenState(url: url)
            let alert = NSAlert()
            if ok {
                alert.messageText = "Imported \(url.lastPathComponent)"
                alert.informativeText = "Emulator state loaded from the Mesen savestate."
            } else {
                alert.alertStyle = .warning
                alert.messageText = "Import failed"
                alert.informativeText = "Could not parse \(url.lastPathComponent) as a Mesen 2 .mss file."
            }
            alert.runModal()
            if ok { dismiss() }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No save states for this ROM")
                .foregroundStyle(.secondary)
            Text("Press ⌘S in-game to capture one")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SaveStateCard: View {
    @EnvironmentObject var emulator: Emulator
    let entry: SaveStateEntry
    @State private var hovering = false
    @State private var renaming = false
    @State private var draftName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                thumbnail
                    .frame(maxWidth: .infinity)
                    .aspectRatio(8.0/7.0, contentMode: .fit)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                if hovering {
                    Button(role: .destructive) {
                        emulator.deleteState(entry)
                    } label: {
                        Image(systemName: "trash.fill")
                            .padding(6)
                            .background(.black.opacity(0.6), in: Circle())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                }
            }
            if renaming {
                TextField("Name", text: $draftName, onCommit: commitRename)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onExitCommand { renaming = false }
            } else {
                Text(entry.name)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .onTapGesture(count: 2) {
                        draftName = entry.name
                        renaming = true
                    }
            }
            Text(entry.createdAt, format: .dateTime.year().month().day().hour().minute())
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(8)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.separator, lineWidth: 0.5)
        )
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Load") { emulator.loadState(entry) }
            Button("Rename") {
                draftName = entry.name
                renaming = true
            }
            Divider()
            Button("Delete", role: .destructive) { emulator.deleteState(entry) }
        }
    }

    private func commitRename() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { emulator.renameState(entry, to: trimmed) }
        renaming = false
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let img = NSImage(data: entry.thumbnailPNG) {
            Image(nsImage: img)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Rectangle().fill(Color.black)
        }
    }
}
