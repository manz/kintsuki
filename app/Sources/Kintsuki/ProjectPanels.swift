import SwiftUI
import AppKit

/// Labels panel — overlay-only labels from the kintsuki project file.
/// Distinct from the `.adbg` symbol table (read-only, sourced from a816);
/// this panel writes back to `labels.tsv`. Use it to rename routines mid-
/// reverse without touching the assembly source.
struct ProjectLabelsView: View {
    @Bindable var emulator: Emulator
    @Environment(\.openWindow) private var openWindow
    @State private var labels: [Emulator.ProjectLabel] = []
    @State private var search: String = ""
    @State private var editingAddr: UInt32? = nil
    @State private var draftName: String = ""
    @State private var draftType: String = ""
    @State private var draftComment: String = ""
    @State private var newAddrText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if !emulator.projectIsOpen {
                ContentUnavailableView(
                    "No project attached",
                    systemImage: "rectangle.dashed",
                    description: Text("Open or create a `.kintsuki/` project from the Project menu.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                table
            }
        }
        .frame(minWidth: 560, minHeight: 360)
        .onAppear { refresh() }
        .onChange(of: emulator.projectDir) { _, _ in refresh() }
        .onReceive(Timer.publish(every: 2.0, on: .main, in: .common).autoconnect()) { _ in
            // Pick up auto-seeded entry flags from the JSR/JSL hook.
            refresh()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "tag.fill").foregroundStyle(.purple)
            Text("Labels (\(labels.count))").font(.headline)
            Spacer(minLength: 8)
            TextField("Filter…", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)
            TextField("New $addr", text: $newAddrText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 110)
                .onSubmit { addNew() }
            Button("Add") { addNew() }
                .disabled(parseAddr(newAddrText) == nil)
        }
        .padding(8)
    }

    private var filtered: [Emulator.ProjectLabel] {
        let s = search.lowercased()
        if s.isEmpty { return labels }
        return labels.filter {
            $0.name.lowercased().contains(s)
                || $0.type.lowercased().contains(s)
                || String(format: "%06x", $0.addr).contains(s)
        }
    }

    private var table: some View {
        Table(filtered) {
            TableColumn("Addr") { L in
                HStack(spacing: 4) {
                    // Primary click → open Debugger at this PC. Labels
                    // are code-flavoured by default (function entries,
                    // jump targets); the disasm view is the natural
                    // landing spot. The small memory glyph next to it
                    // still routes to the Memory Viewer for data labels.
                    Button {
                        emulator.requestDisasmView(pc: L.addr)
                        openWindow(id: "debugger")
                    } label: {
                        Text(String(format: "$%06X", L.addr))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    Button {
                        let region: Emulator.MemRegion =
                            (0x7E0000...0x7FFFFF).contains(L.addr) ? .wram : .rom
                        let off = region == .wram
                            ? Int(L.addr & 0x1FFFF)
                            : Int(emulator.projectBusToRom(L.addr) ?? L.addr)
                        emulator.requestMemoryView(region: region, offset: off)
                        openWindow(id: "memory")
                    } label: {
                        Image(systemName: "memorychip")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help("Open in Memory Viewer")
                }
            }
            .width(min: 110, ideal: 120)
            TableColumn("Name") { L in
                if editingAddr == L.addr {
                    TextField("name", text: $draftName)
                        .onSubmit { commitEdit() }
                } else {
                    Text(L.name).onTapGesture(count: 2) { beginEdit(L) }
                }
            }
            .width(min: 120, ideal: 180)
            TableColumn("Type") { L in
                if editingAddr == L.addr {
                    TextField("type", text: $draftType)
                        .onSubmit { commitEdit() }
                } else {
                    Text(L.type).foregroundStyle(.secondary)
                }
            }
            .width(min: 80, ideal: 100)
            TableColumn("M") { L in flagText(L.m) }.width(28)
            TableColumn("X") { L in flagText(L.x) }.width(28)
            TableColumn("E") { L in flagText(L.e) }.width(28)
            TableColumn("Comment") { L in
                if editingAddr == L.addr {
                    TextField("comment", text: $draftComment)
                        .onSubmit { commitEdit() }
                } else {
                    Text(L.comment).foregroundStyle(.secondary)
                }
            }
            TableColumn("") { L in
                HStack(spacing: 4) {
                    if editingAddr == L.addr {
                        Button("Save") { commitEdit() }
                        Button("Cancel") { cancelEdit() }
                    } else {
                        Button { beginEdit(L) } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.plain)
                        Button { delete(L) } label: {
                            Image(systemName: "trash").foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .width(80)
        }
    }

    @ViewBuilder
    private func flagText(_ v: Int8) -> some View {
        Text(v < 0 ? "—" : "\(v)")
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(v < 0 ? .secondary : .primary)
    }

    private func refresh() {
        labels = emulator.projectLabels()
    }

    private func parseAddr(_ s: String) -> UInt32? {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("$") { t = String(t.dropFirst()) }
        if t.lowercased().hasPrefix("0x") { t = String(t.dropFirst(2)) }
        return UInt32(t, radix: 16).map { $0 & 0xFFFFFF }
    }

    private func addNew() {
        guard let a = parseAddr(newAddrText) else { return }
        emulator.projectLabelSet(addr: a, name: "lbl_\(String(a, radix: 16))")
        newAddrText = ""
        refresh()
        beginEdit(emulator.projectLabelGet(addr: a) ?? Emulator.ProjectLabel(
            addr: a, name: "", type: "", comment: "", m: -1, x: -1, e: -1))
    }

    private func beginEdit(_ L: Emulator.ProjectLabel) {
        editingAddr = L.addr
        draftName = L.name
        draftType = L.type
        draftComment = L.comment
    }

    private func commitEdit() {
        guard let a = editingAddr,
              let existing = emulator.projectLabelGet(addr: a) else {
            cancelEdit(); return
        }
        emulator.projectLabelSet(
            addr: a, name: draftName, type: draftType, comment: draftComment,
            m: existing.m < 0 ? nil : Int(existing.m),
            x: existing.x < 0 ? nil : Int(existing.x),
            e: existing.e < 0 ? nil : Int(existing.e))
        cancelEdit()
        refresh()
    }

    private func cancelEdit() {
        editingAddr = nil
        draftName = ""; draftType = ""; draftComment = ""
    }

    private func delete(_ L: Emulator.ProjectLabel) {
        emulator.projectLabelClear(addr: L.addr)
        refresh()
    }
}

/// Bookmarks panel — named view targets persisted in the project. Lighter
/// than labels: just a (name, addr, view-hint, comment) tuple. Frontend
/// jumps to the memory viewer matching the `view` field.
struct ProjectBookmarksView: View {
    @Bindable var emulator: Emulator
    @State private var bookmarks: [Emulator.ProjectBookmark] = []
    @State private var newName: String = ""
    @State private var newAddr: String = ""
    @State private var newView: String = "rom"

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "bookmark.fill").foregroundStyle(.purple)
                Text("Bookmarks (\(bookmarks.count))").font(.headline)
                Spacer()
                TextField("name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 140)
                TextField("$addr", text: $newAddr)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 100)
                Picker("", selection: $newView) {
                    Text("rom").tag("rom")
                    Text("wram").tag("wram")
                    Text("vram").tag("vram")
                    Text("cgram").tag("cgram")
                    Text("oam").tag("oam")
                }
                .frame(maxWidth: 90)
                Button("Add") { addNew() }
                    .disabled(newName.isEmpty || parseAddr(newAddr) == nil)
            }
            .padding(8)
            Divider()
            if !emulator.projectIsOpen {
                ContentUnavailableView(
                    "No project attached",
                    systemImage: "rectangle.dashed")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(bookmarks) {
                    TableColumn("Name") { b in Text(b.name) }
                        .width(min: 100, ideal: 140)
                    TableColumn("Addr") { b in
                        Button {
                            let region = regionFor(b.view, fallback: b.addr)
                            let off = offsetFor(region: region, addr: b.addr)
                            emulator.requestMemoryView(region: region, offset: off)
                        } label: {
                            Text(String(format: "$%06X", b.addr))
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                    .width(min: 80, ideal: 90)
                    TableColumn("View") { b in
                        Text(b.view).font(.caption).foregroundStyle(.secondary)
                    }
                    .width(60)
                    TableColumn("Comment") { b in
                        Text(b.comment).foregroundStyle(.secondary)
                    }
                    TableColumn("") { b in
                        Button { delete(b) } label: {
                            Image(systemName: "trash").foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                    .width(40)
                }
            }
        }
        .frame(minWidth: 540, minHeight: 320)
        .onAppear { refresh() }
        .onChange(of: emulator.projectDir) { _, _ in refresh() }
    }

    private func refresh() { bookmarks = emulator.projectBookmarks() }

    private func parseAddr(_ s: String) -> UInt32? {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("$") { t = String(t.dropFirst()) }
        if t.lowercased().hasPrefix("0x") { t = String(t.dropFirst(2)) }
        return UInt32(t, radix: 16).map { $0 & 0xFFFFFF }
    }

    private func addNew() {
        guard let a = parseAddr(newAddr) else { return }
        emulator.projectBookmarkSet(name: newName, addr: a, view: newView)
        newName = ""; newAddr = ""
        refresh()
    }

    private func delete(_ b: Emulator.ProjectBookmark) {
        emulator.projectBookmarkClear(name: b.name)
        refresh()
    }

    private func regionFor(_ view: String, fallback addr: UInt32) -> Emulator.MemRegion {
        switch view {
        case "wram":  return .wram
        case "vram":  return .vram
        case "cgram": return .cgram
        case "oam":   return .oam
        case "rom":   return .rom
        default:
            return (0x7E0000...0x7FFFFF).contains(addr) ? .wram : .rom
        }
    }

    private func offsetFor(region: Emulator.MemRegion, addr: UInt32) -> Int {
        switch region {
        case .wram:   return Int(addr & 0x1FFFF)
        case .vram, .cgram, .oam: return Int(addr & 0xFFFF)
        case .sram:   return Int(addr & 0xFFFF)
        case .rom:    return Int(addr & 0xFFFFFF)
        }
    }
}
