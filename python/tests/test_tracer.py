"""Phase 2 — formatted execution tracer.

The tracer wraps an exec callback that disassembles each hit instruction
plus dumps CPU registers, producing one Mesen-style line per fired exec
event. Two modes:

  - RING: stores last N lines in a fixed-size in-memory buffer. `drain()`
    extracts them as a single text blob. Use for short investigative
    windows from Python tests.
  - FILE: writes lines to disk as they fire. Use for longer captures
    where the ring would lose history.

The C ABI lives in `target-kintsuki/kintsuki.h` (`kintsuki_tracer_*`);
this test exercises the RING path end-to-end.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from kintsuki import Emu


def test_tracer_api_exists():
    """Smoke: kintsuki has a tracer API surfaced on Emu."""
    with Emu() as emu:
        assert hasattr(emu, "tracer"), "Emu.tracer() missing"
        assert hasattr(emu, "tracer_start"), "low-level tracer_start missing"
        assert hasattr(emu, "tracer_stop"), "low-level tracer_stop missing"
        assert hasattr(emu, "tracer_drain"), "low-level tracer_drain missing"


def test_tracer_ring_captures_executed_lines(assemble_rom):
    """Tracer set on the test ROM's reset path captures non-empty lines
    that contain disassembly + register columns. Verifies hit, format,
    and drain mechanics in one shot."""
    rom = assemble_rom("test_ppu_state.s")
    with Emu() as emu:
        emu.load_rom(str(rom))
        # Watch the entire reset path ($00:8000..$00:80FF) — every opcode
        # in the boot sequence triggers a trace line.
        emu.tracer_start(lo=0x008000, hi=0x0080FF, ring_capacity=4096)
        emu.run_frames(2)
        text = emu.tracer_drain()
        emu.tracer_stop()

    assert isinstance(text, str)
    assert text, "tracer drained empty string — exec callback didn't fire?"
    lines = [ln for ln in text.splitlines() if ln.strip()]
    assert lines, "no non-empty trace lines"
    # Every full line carries the PC as `BB:AAAA` at column 0 and the
    # A: register marker downstream. Skip the first entry — it can be a
    # partial fragment when the ring evicted bytes mid-line.
    for ln in lines[1:6]:
        assert ln[:7].strip(), f"line missing PC prefix: {ln!r}"
        assert ":" in ln[:7], f"line missing PB:PC marker: {ln!r}"
        assert "A:" in ln, f"line missing A register: {ln!r}"


def test_tracer_ring_evicts_oldest_when_full(assemble_rom):
    """Capacity is honoured: a tiny ring captures only the *last* N lines
    so long-running traces don't grow unbounded."""
    rom = assemble_rom("test_ppu_state.s")
    with Emu() as emu:
        emu.load_rom(str(rom))
        # Capacity is in bytes, deliberately small so the ring rolls over
        # several times during 60 frames of idle-loop spinning.
        emu.tracer_start(lo=0x008000, hi=0x00FFFF, ring_capacity=512)
        emu.run_frames(60)
        text = emu.tracer_drain()
        emu.tracer_stop()
    assert len(text) <= 512, f"ring overran cap: {len(text)} > 512"


def test_tracer_context_manager(assemble_rom):
    """`with emu.tracer(...) as tr` pattern: start on enter, drain on exit
    (or on demand), stop on exit. No leaked native callbacks."""
    rom = assemble_rom("test_ppu_state.s")
    with Emu() as emu:
        emu.load_rom(str(rom))
        with emu.tracer(lo=0x008000, hi=0x0080FF, ring_capacity=4096) as tr:
            emu.run_frames(2)
            text = tr.drain()
        assert text, "context-managed tracer drained empty string"
        # After exit, tracer is stopped — drain returns empty / cleared.
        empty = emu.tracer_drain()
        assert empty == "", "tracer_drain after stop should return empty"


def test_tracer_native_label_injection(assemble_rom, tmp_path):
    """End-to-end: load ROM with its .adbg, FILE-trace the reset path,
    verify the trace.log already contains ``; --- reset ---`` headers
    spliced in natively (no Python post-processing)."""
    rom = assemble_rom("test_ppu_state.s")
    adbg = Path(str(rom) + ".adbg")
    if not adbg.exists():
        pytest.skip(f"missing .adbg next to {rom.name}")
    log = tmp_path / "trace.log"
    with Emu() as emu:
        emu.load_rom(str(rom), adbg=adbg)
        assert emu.lookup_label(0x008000) is not None, (
            "no label resolved at reset vector — adbg load looks broken")
        emu.tracer_start(lo=0x008000, hi=0x0080FF, path=str(log))
        emu.run_frames(1)
        emu.tracer_stop()
    text = log.read_text()
    assert "; --- reset ---" in text, (
        "expected native `reset` label header in trace; got:\n"
        + "\n".join(text.splitlines()[:5])
    )


def test_tracer_resolves_control_flow_operands(assemble_rom, tmp_path):
    """Trace lines for JSR/JSL/JMP/Bxx with a known target label get a
    `-> name` suffix so the log reads like an annotated control-flow
    transcript without further processing."""
    rom = assemble_rom("test_callstack.s")
    adbg = Path(str(rom) + ".adbg")
    if not adbg.exists():
        pytest.skip(f"missing .adbg next to {rom.name}")
    log = tmp_path / "trace.log"
    with Emu() as emu:
        emu.load_rom(str(rom))
        emu.load_adbg(adbg)
        emu.tracer_start(lo=0x008000, hi=0x008300, path=str(log))
        # Boot through JSL outer + JSR inner before STP fires; one frame
        # is enough since the chain runs in <30 instructions.
        for _ in range(5):
            emu.run_frames(1)
            if emu.get_state().stp:
                break
        emu.tracer_stop()
    text = log.read_text()
    assert "jsr.l" in text or "jsl" in text or "jsr" in text, (
        "expected a JSR/JSL line in the trace; got:\n" + text[:400])
    # `jsr.l outer` should be tagged with the outer label
    assert " -> outer" in text, (
        "expected JSL target operand to resolve to `outer`; got:\n"
        + "\n".join(line for line in text.splitlines() if "jsr" in line.lower())[:400]
    )
    assert " -> inner" in text, (
        "expected JSR target operand to resolve to `inner`; got:\n"
        + "\n".join(line for line in text.splitlines() if "jsr" in line.lower())[:400]
    )


def test_lookup_source_resolves_file_line(assemble_rom):
    """``Emu.lookup_source`` returns ``(file, line, column)`` for any
    address covered by the ``.adbg`` LINES section. Reset is the most
    reliable target — the assembler always emits a line entry for it."""
    rom = assemble_rom("test_callstack.s")
    adbg = Path(str(rom) + ".adbg")
    if not adbg.exists():
        pytest.skip(f"missing .adbg next to {rom.name}")
    with Emu() as emu:
        emu.load_rom(str(rom))
        emu.load_adbg(adbg)
        src = emu.lookup_source(0x008000)
        assert src is not None, "no source mapping for reset"
        file, line, col = src
        assert file.endswith("test_callstack.s"), f"unexpected file: {file!r}"
        assert line >= 1
        assert col >= 1
        # Address below first emit should not resolve.
        assert emu.lookup_source(0x000000) is None


def test_lookup_label_roundtrip(assemble_rom):
    """``Emu.load_adbg`` + ``Emu.lookup_label`` resolve assembled symbols."""
    rom = assemble_rom("test_ppu_state.s")
    adbg = Path(str(rom) + ".adbg")
    if not adbg.exists():
        pytest.skip(f"missing .adbg next to {rom.name}")
    with Emu() as emu:
        emu.load_rom(str(rom))
        emu.load_adbg(adbg)
        # Assembled reset vector lives at $00:8000 in the test ROM.
        assert emu.lookup_label(0x008000) == "reset"
        emu.clear_adbg()
        assert emu.lookup_label(0x008000) is None
