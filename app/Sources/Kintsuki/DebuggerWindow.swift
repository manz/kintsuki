import SwiftUI
import AppKit

/// 65816 source-level debugger. Live disassembly around PC, gutter
/// breakpoints, register snapshot, step/over/out/run-to-cursor.
/// `.adbg`-aware: shows containing-routine + source line per row, lets
/// the user jump to any loaded label and set breakpoints by symbol.
struct DebuggerView: View {
    /// Held as a plain reference, NOT `@EnvironmentObject` /
    /// `@ObservedObject`. The Emulator's `@Published` properties churn
    /// at 60 Hz while running (cpuState, fps, lastFrameID) — subscribing
    /// would force this whole body to re-evaluate every tick, costing
    /// ~50% emulator FPS just from SwiftUI diffing the disasm rows.
    /// We take an unsubscribed handle and manually pull snapshots into
    /// `@State` on pause / step / nav so the view stays static while
    /// the emulator runs.
    let emulator: Emulator
    @State private var cursorPC: UInt32? = nil       // run-to-cursor target
    @State private var refreshTick: Int = 0          // bumped on pause / step
    /// Override: when set, the disassembly pane is centered here instead
    /// of the live PC. Cleared by "Back to PC" or when the live PC
    /// catches up to the override (e.g. after run-to-cursor).
    @State private var displayPC: UInt32? = nil
    @State private var addrPickerShown: Bool = false
    @State private var addrInput: String = ""
    @State private var symbolBPInput: String = ""
    @State private var newBpKind: Emulator.BreakKind = .exec
    @State private var newBpHalt: Bool = true
    /// Flag overrides used when disassembling away from live PC. Live
    /// flags drift relative to a target's expected M/X; defaulting
    /// 16-bit-everything is the SNES code-base norm. Toggles surface
    /// next to "Back to PC" when the user is browsing.
    @State private var overrideM: Bool = false
    @State private var overrideX: Bool = false
    @State private var overrideE: Bool = false
    /// Navigation history of `displayPC` jumps. `navIndex == nil`
    /// means "following live PC"; otherwise it's the slot in `navStack`
    /// the user is currently viewing. Back/forward buttons walk this.
    @State private var navStack: [UInt32] = []
    @State private var navIndex: Int? = nil
    /// Disassembly snapshot rendered by the pane. Computed on pause /
    /// step / nav / refreshTick — never on every body redraw, since
    /// reading @Published `cpuState` inside the row would otherwise
    /// invalidate this view at 60 Hz and re-disassemble live.
    @State private var displayedLines: [Emulator.DisasmLine] = []
    /// Center-of-window PC for the displayed lines (matches what the
    /// scroll-into-view target hashes against).
    @State private var displayedPC: UInt32 = 0
    /// Live CPU PC at the time `displayedLines` was rebuilt — drives
    /// the green arrow marker. Cached so the marker doesn't chase the
    /// live PC at 60 Hz while running.
    @State private var displayedActivePC: UInt32 = 0
    /// Snapshot of the CPU register file at the last refresh point.
    /// Drives the sidebar's CPU section instead of reading the live
    /// `@Published` `emulator.cpuState`, which otherwise re-renders the
    /// debugger body 60 Hz while running.
    @State private var displayedCpuState: Emulator.CpuState = .init()
    /// Cached breakpoint list. The view doesn't subscribe to the live
    /// `emulator.breakpoints` (`let emulator` — no auto-redraw), so we
    /// shadow it into @State and refresh via `.onReceive` so each
    /// row sees the latest BP set when it re-renders.
    @State private var displayedBreakpoints: [Emulator.Breakpoint] = []
    /// Project functions whose range covers any displayed disasm row.
    /// Updated alongside `displayedLines` in `rebuildLines` so the
    /// gutter doesn't pull at 60 Hz.
    @State private var displayedFunctions: [Emulator.ProjectFunction] = []
    /// Cached running flag — drives toolbar Pause/Resume label without
    /// taking a `@ObservedObject` subscription that would re-render the
    /// pane every emulator @Published mutation.
    @State private var displayedRunning: Bool = false
    /// Cached label list — refetched when .adbg state changes (currently
    /// after a ROM load resets the table). Cheap snapshot via a single
    /// FFI hop, so re-grab any time `refreshTick` advances.
    @State private var labelCache: [Emulator.Label] = []

    private static let windowSize = 80          // total disassembly lines
    private static let linesBeforePC = 8         // lines retained above PC
    private static let pageGrow = 64             // lines added per scroll page
    private static let pageCap = 2000            // hard cap on retained rows
    @State private var loadingTop = false
    @State private var loadingBottom = false
    @State private var prependBlocked = false   // can't walk back further
    @State private var appendBlocked  = false   // hit bank wrap / ROM end

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HSplitView {
                disassemblyPane
                    .frame(minWidth: 460, idealWidth: 640)
                sidebar
                    .frame(minWidth: 240, idealWidth: 280, maxWidth: 380)
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .onAppear {
            labelCache = emulator.allLabels()
            displayedRunning = emulator.running
            rebuildLines()
        }
        // We don't subscribe to `emulator` via `@EnvironmentObject`, so
        // SwiftUI body invalidation has to be driven manually. `.onReceive`
        // on the published streams keeps working regardless and avoids
        // the 60 Hz redraw storm that comes with full ObservableObject
        // subscription.
        .onChange(of: emulator.running) { _, isRunning in
            displayedRunning = isRunning
            if !isRunning { rebuildLines() }
        }
        .onChange(of: emulator.loadedROM) { _, _ in
            labelCache = emulator.allLabels()
            rebuildLines()
        }
        .onChange(of: emulator.breakpoints) { _, _ in rebuildLines() }
        .onChange(of: emulator.crashBacktrace) { _, _ in rebuildLines() }
        // Project labels join the .adbg pool — re-pull the cache so
        // autocomplete + per-row badges see imported IDA names without
        // a window reopen.
        .onChange(of: emulator.projectIsOpen) { _, _ in
            labelCache = emulator.allLabels()
            rebuildLines()
        }
        .onChange(of: emulator.projectDir) { _, _ in
            labelCache = emulator.allLabels()
            rebuildLines()
        }
        .onChange(of: emulator.disasmNavRequest) { _, req in
            handleDisasmNav(req)
        }
        .onAppear { handleDisasmNav(emulator.disasmNavRequest) }
        // (refreshTick is bumped *by* rebuildLines to force the LazyVStack
        // to re-anchor; calling rebuildLines from its own onChange would
        // recurse, so the scroll-side handlers below depend on
        // displayedPC / displayedActivePC instead.)
        .onChange(of: emulator.loadedROM) { _, _ in
            labelCache = emulator.allLabels()
        }
    }

    // ----- Toolbar -----
    private var toolbar: some View {
        HStack(spacing: 6) {
            Button(action: { emulator.togglePause() }) {
                Image(systemName: displayedRunning ? "pause.fill" : "play.fill")
                Text(displayedRunning ? "Pause" : "Resume")
            }
            Button(action: { emulator.stepInstruction(); rebuildLines() }) {
                Image(systemName: "arrow.right.to.line.compact")
                Text("Step")
            }
            .disabled(displayedRunning)
            Button(action: { emulator.stepOver(); rebuildLines() }) {
                Image(systemName: "arrow.turn.down.right")
                Text("Over")
            }
            .disabled(displayedRunning)
            Button(action: { emulator.stepOut(); rebuildLines() }) {
                Image(systemName: "arrow.up.forward")
                Text("Out")
            }
            .disabled(displayedRunning)
            Button(action: {
                if let pc = cursorPC {
                    _ = emulator.runToCursor(pc: pc)
                    rebuildLines()
                }
            }) {
                Image(systemName: "smallcircle.filled.circle")
                Text("Run to Cursor")
            }
            .disabled(displayedRunning || cursorPC == nil)
            Spacer()
            navBackButton
            navForwardButton
            addressJumpButton
            if displayPC != nil {
                Button(action: {
                    displayPC = nil
                    navIndex = nil
                    rebuildLines()
                }) {
                    Image(systemName: "scope")
                    Text("Back to PC")
                }
                Toggle("M", isOn: $overrideM)
                    .toggleStyle(.button)
                    .help("M=1 (8-bit accumulator immediate)")
                    .onChange(of: overrideM) { _, _ in rebuildLines() }
                Toggle("X", isOn: $overrideX)
                    .toggleStyle(.button)
                    .help("X=1 (8-bit index immediate)")
                    .onChange(of: overrideX) { _, _ in rebuildLines() }
                Toggle("E", isOn: $overrideE)
                    .toggleStyle(.button)
                    .help("E=1 (emulation/6502 mode)")
                    .onChange(of: overrideE) { _, _ in rebuildLines() }
            }
        }
        .padding(8)
        .buttonStyle(.bordered)
    }

    private var navBackButton: some View {
        Button(action: navigateBack) {
            Image(systemName: "chevron.left")
        }
        .keyboardShortcut("[", modifiers: [.command])
        .disabled(!canNavigateBack)
        .help("Back (⌘[)")
    }

    private var navForwardButton: some View {
        Button(action: navigateForward) {
            Image(systemName: "chevron.right")
        }
        .keyboardShortcut("]", modifiers: [.command])
        .disabled(!canNavigateForward)
        .help("Forward (⌘])")
    }

    private var canNavigateBack: Bool {
        // Backable when there's history to step into. Two cases:
        //  - Following live PC: any prior displayPC visit can be revisited.
        //  - Already viewing slot i: i > 0 means a previous slot exists.
        if navStack.isEmpty { return false }
        if let i = navIndex { return i > 0 }
        return true   // following PC, jump back to most recent slot
    }

    private var canNavigateForward: Bool {
        guard let i = navIndex else { return false }
        return i < navStack.count - 1
    }

    private func navigateBack() {
        guard !navStack.isEmpty else { return }
        let target: Int
        if let i = navIndex {
            guard i > 0 else { return }
            target = i - 1
        } else {
            target = navStack.count - 1
        }
        navIndex = target
        displayPC = navStack[target]
        cursorPC = navStack[target]
        rebuildLines()
    }

    private func navigateForward() {
        guard let i = navIndex, i < navStack.count - 1 else { return }
        let target = i + 1
        navIndex = target
        displayPC = navStack[target]
        cursorPC = navStack[target]
        rebuildLines()
    }

    @State private var lastHandledDisasmNonce: Int = 0

    /// Honour an `Emulator.disasmNavRequest` exactly once per nonce.
    /// Used by external panels (Labels, Bookmarks, DMA caller) to jump
    /// the disasm view without owning a binding into `displayPC`.
    private func handleDisasmNav(_ req: Emulator.DisasmNavRequest?) {
        guard let req, req.nonce != lastHandledDisasmNonce else { return }
        lastHandledDisasmNonce = req.nonce
        pushNav(req.pc)
    }

    /// Push `addr` onto the navigation stack and focus it. Truncates
    /// any forward history past the current slot — same semantics as a
    /// browser back/forward stack. Use this for every user-initiated
    /// displayPC change so back/forward stays predictable.
    private func pushNav(_ addr: UInt32) {
        if let i = navIndex, i < navStack.count - 1 {
            navStack.removeSubrange((i + 1)...)
        }
        // Skip duplicate consecutive entries.
        if navStack.last != addr {
            navStack.append(addr)
        }
        navIndex = navStack.count - 1
        displayPC = addr
        cursorPC = addr
        rebuildLines()
    }

    /// Toolbar button → small popover with a hex address field. Centers
    /// the disassembly at the entered PC. M/X default to 0 (16-bit) when
    /// jumping to an arbitrary address; the per-flag toggles next to
    /// "Back to PC" let you correct that for routines that run with the
    /// flags set.
    private var addressJumpButton: some View {
        Button(action: { addrPickerShown.toggle() }) {
            Image(systemName: "number")
            Text("Go to…")
        }
        .popover(isPresented: $addrPickerShown) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Go to…").font(.headline)
                TextField("$XXXXXX or label name", text: $addrInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 280)
                    .onSubmit { commitAddressJump() }
                let matches = addrSuggestions()
                if !matches.isEmpty {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(matches) { lbl in
                                Button(action: {
                                    pushNav(lbl.addr)
                                    addrPickerShown = false
                                    addrInput = ""
                                    overrideM = false; overrideX = false; overrideE = false
                                }) {
                                    HStack {
                                        Text(lbl.name)
                                            .font(.system(.caption, design: .monospaced))
                                            .lineLimit(1)
                                        Spacer()
                                        Text(String(format: "%06X", lbl.addr))
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(width: 280, height: 200)
                    .background(Color.gray.opacity(0.08))
                    .cornerRadius(4)
                }
                HStack {
                    Spacer()
                    Button("Jump") { commitAddressJump() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(parseAddrInput() == nil
                                  && emulator.resolveSymbol(addrInput.trimmingCharacters(in: .whitespaces)) == nil
                                  && addrSuggestions().isEmpty)
                }
            }
            .padding(10)
        }
    }

    private func addrSuggestions() -> [Emulator.Label] {
        let needle = addrInput.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        if needle.hasPrefix("$") || needle.hasPrefix("0x") { return [] }
        if needle.allSatisfy({ "0123456789abcdef".contains($0) }) && needle.count >= 4 {
            return []
        }
        return labelCache
            .filter { $0.name.lowercased().contains(needle) }
            .prefix(12)
            .map { $0 }
    }

    private func parseAddrInput() -> UInt32? {
        var s = addrInput.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("$") { s.removeFirst() }
        else if s.lowercased().hasPrefix("0x") { s.removeFirst(2) }
        guard !s.isEmpty,
              s.allSatisfy({ "0123456789abcdefABCDEF".contains($0) }),
              let v = UInt32(s, radix: 16) else { return nil }
        return v & 0xFFFFFF
    }

    private func commitAddressJump() {
        // Resolution priority: hex literal first (so `8000` is unambiguous
        // even when a label of the same name exists), then top label
        // suggestion, then exact symbol resolve.
        let raw = addrInput.trimmingCharacters(in: .whitespaces)
        let target: UInt32?
        if let v = parseAddrInput() {
            target = v
        } else if let first = addrSuggestions().first {
            target = first.addr
        } else if let v = emulator.resolveSymbol(raw) {
            target = v
        } else {
            target = nil
        }
        guard let addr = target else { NSSound.beep(); return }
        addrPickerShown = false
        addrInput = ""
        // Default to 16-bit M/X for arbitrary jumps — typical SNES game
        // code runs with `rep #$30`. User can flip the toolbar toggles
        // when landing in early-boot or interrupt-handler territory.
        overrideM = false
        overrideX = false
        overrideE = false
        pushNav(addr)
    }

    // ----- Disassembly pane -----
    private var disassemblyPane: some View {
        let lines = displayedLines
        let centerPC = displayedPC
        return ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // Top sentinel: appears in the lazy stack viewport
                    // only when the user scrolls within ~one row of the
                    // first decoded line. Triggers a back-walk + prepend.
                    Color.clear
                        .frame(height: 1)
                        .onAppear { loadMoreTop() }
                    ForEach(lines) { line in
                        VStack(alignment: .leading, spacing: 0) {
                            // Label header — shown above any line whose PC
                            // is the start of a known routine. Mirrors the
                            // tracer's "; --- name ---" annotation.
                            if let name = emulator.exactLabel(at: line.pc) {
                                Text("\(name):")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.orange)
                                    .padding(.horizontal, 8)
                                    .padding(.top, 4)
                            }
                            disasmRow(line: line)
                        }
                        .id(line.pc)
                    }
                    // Bottom sentinel: trips an append when visible.
                    Color.clear
                        .frame(height: 1)
                        .onAppear { loadMoreBottom() }
                }
                // Tie the LazyVStack's identity to the breakpoint set
                // so adding / removing a BP forces every row to re-eval
                // its gutter dot. Without this SwiftUI's lazy diff
                // sometimes reuses the prior row's body and the dot
                // doesn't repaint.
                .id(refreshTick)
                .padding(.vertical, 6)
                .background(.background)
                .font(.system(.body, design: .monospaced))
            }
            .onChange(of: displayedPC) { _, _ in
                if let target = lines.first(where: { $0.pc == centerPC }) {
                    withAnimation(.none) { scroller.scrollTo(target.pc, anchor: .center) }
                }
            }
            .onChange(of: displayedActivePC) { _, _ in
                if let target = lines.first(where: { $0.pc == centerPC }) {
                    withAnimation(.none) { scroller.scrollTo(target.pc, anchor: .center) }
                }
            }
            .onAppear {
                if let target = lines.first(where: { $0.pc == centerPC }) {
                    scroller.scrollTo(target.pc, anchor: .center)
                }
            }
        }
    }

    /// Colour for a single token-kind. Hex-width tiers share the orange
    /// family so operand widths cluster visually; long-form `$XXXXXX`
    /// reads bolder than DP `$XX` reads.
    private static func tokColor(_ k: Emulator.DisasmTok) -> NSColor {
        switch k {
        case .mnemonic: return .controlAccentColor
        case .immHex:   return .systemYellow
        case .absHex:   return .systemOrange
        case .longHex:  return .systemRed
        case .dpHex:    return .systemTeal
        case .reg:      return .systemPurple
        case .punct:    return .secondaryLabelColor
        case .labelRef: return .systemBlue
        case .arrow:    return .tertiaryLabelColor
        case .comment:  return .secondaryLabelColor
        case .other:    return .labelColor
        }
    }

    /// Build a syntax-coloured AttributedString for one disasm row using
    /// the per-char `kinds` array emitted by libkintsuki. Each contiguous
    /// run of identical kinds becomes one styled span. When the project
    /// flags this PC as non-code, the line is replaced with `.db $XX`
    /// so the byte still reads visibly without the walker pretending
    /// the data is a 65816 opcode.
    private func disasmAttributed(for line: Emulator.DisasmLine) -> AttributedString {
        // Data-aware override (slice 7 follow-up).
        if emulator.projectIsOpen,
           let off = emulator.projectBusToRom(line.pc) {
            let raw = emulator.projectClassify(romOffset: off)
            let cls = Emulator.ByteClass(rawValue: raw & 0x7F) ?? .unknown
            if cls == .data || cls == .pointer || cls == .string
                || cls == .graphics || cls == .tilemap
                || cls == .palette || cls == .audio {
                let byte = emulator.readBus(line.pc) ?? 0
                var s = AttributedString(String(format: ".db $%02X", byte))
                s.foregroundColor = .secondary
                if let range = s.range(of: ".db") {
                    s[range].foregroundColor = NSColor.systemGray
                }
                return s
            }
        }

        var attr = AttributedString(line.text)
        attr.font = .system(.body, design: .monospaced)
        attr.foregroundColor = NSColor.labelColor
        let utf8 = Array(line.text.utf8)
        let n = min(utf8.count, line.kinds.count)
        guard n > 0 else { return attr }
        // Walk runs of identical kind; build NSRange (UTF-16) per run +
        // map to AttributedString.Index.
        var i = 0
        while i < n {
            let k = line.kinds[i]
            var j = i
            while j < n && line.kinds[j] == k { j += 1 }
            let tok = Emulator.DisasmTok(rawValue: k) ?? .other
            // Resolve byte offsets to AttributedString indices through
            // the underlying String. AttributedString.index(_:offsetBy:)
            // operates on its own opaque indices, which line up with
            // UTF-8 here (ASCII-only disasm output).
            let start = attr.index(attr.startIndex, offsetByCharacters: i)
            let end   = attr.index(attr.startIndex, offsetByCharacters: j)
            attr[start..<end].foregroundColor = Self.tokColor(tok)
            if tok == .mnemonic {
                attr[start..<end].font = .system(.body, design: .monospaced).bold()
            }
            i = j
        }
        return attr
    }

    /// Per-row description of how the function gutter should render.
    private struct FunctionGutter {
        let color: Color
        let isEntry: Bool
        let isExit: Bool
    }

    /// Find the project function whose `[entry, endApprox]` range covers
    /// `pc`. Returns nil when no project is open or no recorded function
    /// spans this PC. Linear scan — function tables stay in the hundreds
    /// even for big games, the cost is negligible per row.
    private func functionGutter(for pc: UInt32) -> FunctionGutter? {
        guard !displayedFunctions.isEmpty else { return nil }
        for f in displayedFunctions {
            guard let end = f.endApprox else {
                if f.entry == pc {
                    return FunctionGutter(color: gutterColor(forEntry: f.entry),
                                          isEntry: true, isExit: false)
                }
                continue
            }
            if pc >= f.entry && pc <= end {
                let isExit = f.exits.contains(pc)
                return FunctionGutter(color: gutterColor(forEntry: f.entry),
                                      isEntry: pc == f.entry,
                                      isExit: isExit)
            }
        }
        return nil
    }

    /// Stable per-function colour. Hash entry → hue. Saturation +
    /// brightness fixed so the bar reads cleanly against the row bg.
    private func gutterColor(forEntry entry: UInt32) -> Color {
        // 24-bit golden-ratio hash → hue in [0, 1).
        let h = Double((entry &* 2654435761) & 0xFFFFFFFF) / 4294967296.0
        return Color(hue: h, saturation: 0.55, brightness: 0.95)
    }

    private func disasmRow(line: Emulator.DisasmLine) -> some View {
        // Use the cached "active PC" rather than the live @Published
        // value so the row doesn't repaint at 60 Hz while running.
        let isPC = line.pc == displayedActivePC
        let isCursor = line.pc == cursorPC
        let bp = displayedBreakpoints.first { $0.kind == .exec && line.pc >= $0.lo && line.pc <= $0.hi }
        // Source-line lookup ("; file:N") deliberately omitted on disasm
        // rows. `.adbg` LINES entries snap to "the largest address ≤ pc
        // that emitted a line", which is fine for a backtrace frame
        // (rough hint of where execution sits) but wrong on disassembly
        // where every row of a routine ends up tagged with the same
        // line — sometimes kilobytes away from the actual instruction.
        let funcGutter = functionGutter(for: line.pc)
        return HStack(spacing: 0) {
            // Function gutter: vertical bar coloured per function entry.
            // Tick at top = function start, tick at bottom = exit PC.
            // Width is tight so it doesn't push the BP dot column out.
            ZStack(alignment: .leading) {
                if let fg = funcGutter {
                    Rectangle()
                        .fill(fg.color.opacity(0.55))
                        .frame(width: 3)
                    if fg.isEntry {
                        Rectangle()
                            .fill(fg.color)
                            .frame(width: 6, height: 2)
                            .offset(y: -7)
                    }
                    if fg.isExit {
                        Rectangle()
                            .fill(fg.color)
                            .frame(width: 6, height: 2)
                            .offset(y: 7)
                    }
                }
            }
            .frame(width: 6)
            // Gutter
            Button(action: { toggleBreakpoint(at: line.pc) }) {
                Image(systemName: bp != nil ? "circle.fill" : "circle")
                    .foregroundStyle(bp != nil ? Color.red : Color.secondary.opacity(0.4))
                    .frame(width: 18)
            }
            .buttonStyle(.plain)
            // PC arrow
            Image(systemName: isPC ? "arrowtriangle.right.fill" : "")
                .foregroundStyle(Color.accentColor)
                .frame(width: 14)
            // PC text
            Text(String(format: "%02X:%04X",
                        (line.pc >> 16) & 0xFF, line.pc & 0xFFFF))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            // Entry-label badge. Project overlay (purple) wins over
            // .adbg (blue). Helps the disasm read as IDA-style "Name:"
            // separators without breaking the row-per-instruction layout.
            if let projName = emulator.projectExactLabel(at: line.pc) {
                Text(projName)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.purple)
                    .padding(.horizontal, 4).padding(.vertical, 0)
                    .background(Color.purple.opacity(0.12), in: Capsule())
                    .padding(.trailing, 6)
            } else if let adbgName = emulator.exactLabel(at: line.pc) {
                Text(adbgName)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 4).padding(.vertical, 0)
                    .background(Color.blue.opacity(0.10), in: Capsule())
                    .padding(.trailing, 6)
            }
            // Disassembly. If the project byte-class says this PC is
            // Data, override the live disasm with `.db $XX` — keeps the
            // walker from speculatively decoding a known data byte as
            // an opcode (and burning its operand bytes on garbage).
            Text(disasmAttributed(for: line))
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
        .background(isPC ? Color.accentColor.opacity(0.18)
                    : (isCursor ? Color.gray.opacity(0.12) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            // Double-click on a control-flow op = follow the static
            // target. Falls back to selecting the row when the line has
            // no resolvable target.
            if let tgt = line.target {
                pushNav(tgt)
            } else {
                cursorPC = line.pc
            }
        }
        .onTapGesture { cursorPC = line.pc }
    }

    /// Pull a fresh disassembly snapshot into `displayedLines`. Called
    /// by every code path the user can trigger (pause edge, step, nav,
    /// breakpoint halt). Never wired to a live @Published change — that
    /// would re-disassemble at 60 Hz.
    private func rebuildLines() {
        let s = emulator.cpuState
        displayedCpuState = s
        displayedActivePC = s.pc
        displayedPC = displayPC ?? s.pc
        displayedLines = currentLines()
        displayedBreakpoints = emulator.breakpoints
        displayedFunctions = emulator.projectFunctions()
        // Fresh window — unblock paging so the user can grow again.
        prependBlocked = false
        appendBlocked = false
        // Bump the LazyVStack's `.id` so SwiftUI rebuilds it, the
        // scroll position resets, and the .onAppear-style scrollTo on
        // the inner ScrollViewReader re-anchors on the (possibly new)
        // active PC. Without this the lazy stack reuses old offsets
        // after a step and the highlight scrolls out of view.
        refreshTick &+= 1
    }

    /// Append more disasm lines past the last visible row. Walks the
    /// `length` field of the current tail to find the next PC, then
    /// asks the emulator for `pageGrow` more lines. Stops walking on
    /// bank wrap so we don't leak across mapper boundaries.
    private func loadMoreBottom() {
        if loadingBottom || appendBlocked { return }
        guard let last = displayedLines.last else { return }
        loadingBottom = true
        defer { loadingBottom = false }
        let bankBase = last.pc & 0xFF0000
        let next16 = UInt32(last.pc & 0xFFFF) + UInt32(last.length)
        if next16 > 0xFFFF { appendBlocked = true; return }
        let nextPc = bankBase | next16
        let more = emulator.disassemble(at: nextPc,
                                        count: Self.pageGrow,
                                        eOverride: nil,
                                        mOverride: nil,
                                        xOverride: nil)
        guard !more.isEmpty else { appendBlocked = true; return }
        displayedLines.append(contentsOf: more)
        // Trim from the top if we blew past the cap. Don't trim while
        // the user might still want to scroll back through the prepend
        // window — leave at least one full page above PC.
        if displayedLines.count > Self.pageCap {
            let drop = displayedLines.count - Self.pageCap
            displayedLines.removeFirst(drop)
            prependBlocked = false
        }
        refreshTick &+= 1
    }

    /// Prepend more lines above the first visible row. 65816 isn't
    /// reverse-decodable without context, so we probe back ~3 bytes per
    /// requested line, disassemble forward from that anchor, then keep
    /// only the entries strictly before the current top.
    private func loadMoreTop() {
        if loadingTop || prependBlocked { return }
        guard let first = displayedLines.first else { return }
        loadingTop = true
        defer { loadingTop = false }
        let bankBase = first.pc & 0xFF0000
        let pc16 = first.pc & 0xFFFF
        // Always probe at least 3 bytes per requested line; bank-clamp.
        let probeBack = UInt32(Self.pageGrow) * 3
        if pc16 <= 0x8000 + probeBack {
            // We're close to the bottom of the bank's ROM window — give
            // up rather than producing speculative gibberish.
            prependBlocked = true
            return
        }
        let start = bankBase | (pc16 - probeBack)
        let probed = emulator.disassemble(at: start,
                                          count: Self.pageGrow * 2,
                                          eOverride: nil,
                                          mOverride: nil,
                                          xOverride: nil)
        let prefix = probed.prefix { $0.pc < first.pc }
        guard !prefix.isEmpty else { prependBlocked = true; return }
        displayedLines.insert(contentsOf: prefix, at: 0)
        if displayedLines.count > Self.pageCap {
            let drop = displayedLines.count - Self.pageCap
            displayedLines.removeLast(drop)
            appendBlocked = false
        }
        refreshTick &+= 1
    }

    private func currentLines() -> [Emulator.DisasmLine] {
        _ = refreshTick
        let pc = displayPC ?? emulator.cpuState.pc
        // Override flags only apply when browsing away from the live PC;
        // the live view inherits the actual register state.
        let useOverrides = displayPC != nil
        let mFlag: Bool? = useOverrides ? overrideM : nil
        let xFlag: Bool? = useOverrides ? overrideX : nil
        let eFlag: Bool? = useOverrides ? overrideE : nil
        // ~3 bytes/instruction average; probe enough back-bytes that
        // we can spare ~`linesBeforePC` decoded lines above the focal PC
        // and the rest go forward. Caps the "before" context tight so
        // the user mostly sees code AHEAD of the breakpoint, not a
        // rear-view mirror of where they came from.
        let probeBack = Self.linesBeforePC * 4
        let bankBase = pc & 0xFF0000
        let pc16 = pc & 0xFFFF
        if pc16 >= UInt32(probeBack) {
            let start = bankBase | (pc16 - UInt32(probeBack))
            let probed = emulator.disassemble(at: start,
                                              count: Self.windowSize,
                                              eOverride: eFlag,
                                              mOverride: mFlag,
                                              xOverride: xFlag)
            if let pcIdx = probed.firstIndex(where: { $0.pc == pc }) {
                // Trim to keep only `linesBeforePC` rows above pc; the
                // rest of the window (linesBeforePC..windowSize) stays
                // ahead. That's where execution is going next.
                let lo = max(0, pcIdx - Self.linesBeforePC)
                return Array(probed[lo...])
            }
        }
        return emulator.disassemble(at: pc,
                                    count: Self.windowSize,
                                    eOverride: eFlag,
                                    mOverride: mFlag,
                                    xOverride: xFlag)
    }

    private func toggleBreakpoint(at pc: UInt32) {
        if let bp = displayedBreakpoints.first(where: {
            $0.kind == .exec && pc >= $0.lo && pc <= $0.hi
        }) {
            emulator.removeBreakpoint(bp)
        } else {
            emulator.addBreakpoint(kind: .exec, lo: pc, hi: pc, halt: true)
        }
        rebuildLines()
        refreshTick &+= 1   // force LazyVStack row diff to re-eval
    }

    // ----- Sidebar -----
    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                cpuSection
                Divider()
                callstackSection
                Divider()
                breakpointsSection
                Spacer(minLength: 0)
            }
            .padding(12)
        }
    }

    private var cpuSection: some View {
        // Cached snapshot — sidebar refreshes on pause / step / nav,
        // not on the live 60 Hz `cpuState` churn.
        let s = displayedCpuState
        return VStack(alignment: .leading, spacing: 6) {
            Text("CPU").font(.headline)
            if let containing = emulator.containingLabel(at: s.pc) {
                Text("\(containing.name)+\(String(format: "%X", containing.offset))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
            regGrid(s)
            Text(flagString(s.p))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            if s.stp { Text("STP halted").foregroundStyle(.red).font(.caption) }
            if s.wai { Text("WAI").foregroundStyle(.orange).font(.caption) }
        }
    }

    private func regGrid(_ s: Emulator.CpuState) -> some View {
        let rows: [[(String, String)]] = [
            [("A",  String(format: "%04X", s.a)),
             ("X",  String(format: "%04X", s.x)),
             ("Y",  String(format: "%04X", s.y))],
            [("S",  String(format: "%04X", s.s)),
             ("D",  String(format: "%04X", s.d)),
             ("B",  String(format: "%02X", s.b))],
            [("PC", String(format: "%06X", s.pc)),
             ("P",  String(format: "%02X", s.p)),
             ("E",  s.e ? "1" : "0")],
        ]
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(rows.indices, id: \.self) { i in
                HStack {
                    ForEach(rows[i].indices, id: \.self) { j in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rows[i][j].0).font(.caption2).foregroundStyle(.secondary)
                            Text(rows[i][j].1).font(.system(.body, design: .monospaced))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func flagString(_ p: UInt8) -> String {
        let labels: [(UInt8, Character)] = [
            (0x80, "N"), (0x40, "V"), (0x20, "M"), (0x10, "X"),
            (0x08, "D"), (0x04, "I"), (0x02, "Z"), (0x01, "C"),
        ]
        return String(labels.map { (p & $0.0) != 0 ? $0.1 : Character($0.1.lowercased()) })
    }

    private var callstackSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Backtrace").font(.headline)
            if emulator.crashBacktrace.isEmpty {
                Text("(running — pause to capture)")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(emulator.crashBacktrace) { f in
                    HStack {
                        Text(f.label.map { "\($0)+\(String(format: "%X", f.offset))" }
                             ?? String(format: "%06X", f.callsite))
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                        Spacer()
                        Button(action: { pushNav(f.callsite) }) {
                            Image(systemName: "arrow.right.square")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var breakpointsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Breakpoints").font(.headline)
            symbolBPField
            if displayedBreakpoints.isEmpty {
                Text("none — click a gutter dot, type a symbol, or use the picker.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(displayedBreakpoints) { bp in
                    HStack {
                        Image(systemName: bp.halt ? "octagon.fill" : "circle")
                            .foregroundStyle(bp.halt ? Color.red : Color.yellow)
                            .font(.caption2)
                        Text(breakpointLabel(bp))
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                        Spacer()
                        Text("hits: \(bp.halt ? bp.hitCount : emulator.tracingHitCount(bp))")
                            .font(.caption2).foregroundStyle(.secondary)
                        Button(action: { emulator.removeBreakpoint(bp) }) {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.plain)
                    }
                    .contentShape(Rectangle())
                    // Double-click any breakpoint row to focus the
                    // disassembly on its address. Single-click is left
                    // free for future row selection.
                    .onTapGesture(count: 2) { pushNav(bp.lo) }
                }
            }
        }
    }

    /// Autocomplete-aware breakpoint entry. Live matches against the
    /// loaded label table appear under the field; ↑/↓ navigate, Enter
    /// commits the highlighted suggestion (or, with an empty list,
    /// parses the raw input as hex / a symbol name).
    private var symbolBPField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Picker("", selection: $newBpKind) {
                    ForEach(Emulator.BreakKind.allCases) { k in
                        Text(k.label).tag(k)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
                Toggle(isOn: $newBpHalt) {
                    Image(systemName: newBpHalt ? "octagon.fill" : "circle")
                        .foregroundStyle(newBpHalt ? Color.red : Color.yellow)
                }
                .toggleStyle(.button)
                .help(newBpHalt ? "halt on hit" : "trace only (no pause)")
                Spacer()
            }
            HStack(spacing: 4) {
                TextField("symbol or $hex", text: $symbolBPInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .onSubmit {
                        let s = bpSuggestions()
                        if let first = s.first {
                            commitBreakpoint(addr: first.addr)
                        } else {
                            addBreakpointFromInput()
                        }
                    }
                Button(action: addBreakpointFromInput) {
                    Image(systemName: "plus.circle.fill")
                }
                .buttonStyle(.plain)
                .disabled(symbolBPInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !bpSuggestions().isEmpty {
                suggestionList(bpSuggestions())
            }
        }
    }

    private func commitBreakpoint(addr: UInt32) {
        emulator.addBreakpoint(kind: newBpKind, lo: addr, hi: addr, halt: newBpHalt)
        symbolBPInput = ""
        rebuildLines()
    }

    private func bpSuggestions() -> [Emulator.Label] {
        let needle = symbolBPInput
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        guard !needle.isEmpty else { return [] }
        // Don't suggest for hex inputs (those go through addBreakpointFromInput).
        if needle.hasPrefix("$") || needle.hasPrefix("0x") { return [] }
        if needle.allSatisfy({ "0123456789abcdef".contains($0) }) && needle.count >= 4 {
            return []
        }
        return labelCache
            .filter { $0.name.lowercased().contains(needle) }
            .prefix(8)
            .map { $0 }
    }

    private func suggestionList(_ items: [Emulator.Label]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { lbl in
                Button(action: { commitBreakpoint(addr: lbl.addr) }) {
                    HStack {
                        Text(lbl.name)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                        Spacer()
                        Text(String(format: "%06X", lbl.addr))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color.gray.opacity(0.08))
        .cornerRadius(4)
    }

    private func addBreakpointFromInput() {
        let raw = symbolBPInput.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }
        // Hex literal? Accept `$XXXXXX`, `0xXXXXXX`, or bare hex string.
        var hex = raw
        if hex.hasPrefix("$") { hex.removeFirst() }
        else if hex.lowercased().hasPrefix("0x") { hex.removeFirst(2) }
        if let addr = UInt32(hex, radix: 16),
           hex.allSatisfy({ "0123456789abcdefABCDEF".contains($0) }),
           !hex.isEmpty {
            commitBreakpoint(addr: addr)
            return
        }
        // Otherwise treat as symbol name.
        if let addr = emulator.resolveSymbol(raw) {
            commitBreakpoint(addr: addr)
        } else {
            NSSound.beep()
        }
    }

    /// Annotate a breakpoint with its containing label when .adbg has
    /// one. Lets the user tell apart five exec BPs at a glance.
    private func breakpointLabel(_ bp: Emulator.Breakpoint) -> String {
        let addrStr: String = bp.lo == bp.hi
            ? String(format: "%06X", bp.lo)
            : String(format: "%06X..%06X", bp.lo, bp.hi)
        if let exact = emulator.exactLabel(at: bp.lo) {
            return "\(bp.kind.label)  \(exact)  \(addrStr)"
        }
        if let containing = emulator.containingLabel(at: bp.lo), bp.lo == bp.hi {
            return "\(bp.kind.label)  \(containing.name)+\(String(format: "%X", containing.offset))"
        }
        return "\(bp.kind.label)  \(addrStr)"
    }
}
