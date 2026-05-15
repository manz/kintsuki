import SwiftUI

/// Per-function profile panel. Mirrors the Python `profile_start/stop` API:
/// flat list of (pc, name, calls, incl, excl, max, min), sortable, with a
/// click-to-Debugger affordance on each row to match the Labels and
/// Bookmarks panels.
///
/// The panel keeps showing the last frozen recording until the user starts
/// another window or resets — useful for snapshotting before/after a code
/// change without losing the comparison row.
struct ProfilerView: View {
    @Bindable var emulator: Emulator
    @Environment(\.openWindow) private var openWindow

    @State private var sortOrder: [KeyPathComparator<Emulator.FnStat>] = [
        .init(\Emulator.FnStat.excl, order: .reverse)
    ]
    @State private var search: String = ""
    @State private var loText: String = ""
    @State private var hiText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if emulator.profileStats.isEmpty && !emulator.profileActive {
                ContentUnavailableView(
                    "No profile yet",
                    systemImage: "chart.bar.xaxis",
                    description: Text("Click **Start** to begin recording. Stats are aggregated from JSR/JSL/RTS/RTL hooks until you stop.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                table
            }
        }
        .frame(minWidth: 720, minHeight: 360)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
                .foregroundStyle(emulator.profileActive ? .red : .secondary)
            Text(emulator.profileActive
                 ? "Recording…"
                 : "Profile (\(emulator.profileStats.count) fns)")
                .font(.headline)
            Spacer(minLength: 8)
            TextField("Filter…", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 160)
            TextField("lo $", text: $loText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 80)
                .disabled(emulator.profileActive)
            TextField("hi $", text: $hiText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 80)
                .disabled(emulator.profileActive)
            if emulator.profileActive {
                Button("Stop") { emulator.profileStop() }
                    .keyboardShortcut(.return, modifiers: [])
            } else {
                Button("Start") {
                    let lo = parseHex(loText)
                    let hi = parseHex(hiText)
                    emulator.profileStart(lo: lo, hi: hi)
                }
            }
            Button("Reset") { emulator.profileReset() }
                .disabled(emulator.profileStats.isEmpty && !emulator.profileActive)
        }
        .padding(8)
    }

    private var filtered: [Emulator.FnStat] {
        var rows = emulator.profileStats
        let s = search.lowercased()
        if !s.isEmpty {
            rows = rows.filter {
                ($0.name?.lowercased().contains(s) ?? false)
                    || String(format: "%06x", $0.pc).contains(s)
            }
        }
        rows.sort(using: sortOrder)
        return rows
    }

    private var table: some View {
        Table(filtered, sortOrder: $sortOrder) {
            TableColumn("PC", value: \.pc) { row in
                Button {
                    emulator.requestDisasmView(pc: row.pc)
                    openWindow(id: "debugger")
                } label: {
                    Text(String(format: "$%06X", row.pc))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            }
            .width(80)
            TableColumn("Name") { row in
                Text(row.name ?? "—")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(row.name == nil ? .secondary : .primary)
            }
            .width(min: 120, ideal: 200)
            TableColumn("Calls", value: \.calls) { row in
                Text("\(row.calls)").monospacedDigit()
            }
            .width(60)
            TableColumn("Excl", value: \.excl) { row in
                Text("\(row.excl)").monospacedDigit()
            }
            .width(100)
            TableColumn("Incl", value: \.incl) { row in
                Text("\(row.incl)").monospacedDigit()
            }
            .width(100)
            TableColumn("Max", value: \.maxCycles) { row in
                Text("\(row.maxCycles)").monospacedDigit()
            }
            .width(80)
            TableColumn("Min", value: \.minCycles) { row in
                Text("\(row.minCycles)").monospacedDigit()
            }
            .width(80)
        }
    }

    private func parseHex(_ s: String) -> UInt32? {
        let t = s.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: "0x", with: "")
        if t.isEmpty { return nil }
        return UInt32(t, radix: 16)
    }
}

