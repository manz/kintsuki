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

from kintsuki import Emu, annotate_trace


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


def test_annotate_trace_pure():
    """Pure-string helper: PC matches a label → header line gets injected
    above; consecutive lines at the same PC don't repeat the header."""
    text = (
        "00:8000 lda #$01    ; A:00\n"
        "00:8000 lda #$01    ; A:00\n"
        "00:8002 sta $00     ; A:01\n"
    )
    out = annotate_trace(text, {0x008000: "reset", 0x008002: "store"})
    assert "; --- reset ---" in out
    assert "; --- store ---" in out
    # Header for `reset` only appears once, not twice for the duplicate PC.
    assert out.count("; --- reset ---") == 1


def test_tracer_annotate_with_adbg(assemble_rom, tmp_path):
    """End-to-end: load ROM with its .adbg, FILE-trace the reset path,
    annotate the trace.log, verify a label header is spliced in.

    FILE mode is used so ring eviction doesn't drop the reset entry once
    the boot drops into its idle loop."""
    rom = assemble_rom("test_ppu_state.s")
    adbg = Path(str(rom) + ".adbg")
    if not adbg.exists():
        pytest.skip(f"missing .adbg next to {rom.name}")
    log = tmp_path / "trace.log"
    with Emu() as emu:
        emu.load_rom(str(rom), adbg=adbg)
        assert emu._labels, "label table empty after load_rom(adbg=...)"
        emu.tracer_start(lo=0x008000, hi=0x0080FF, path=str(log))
        emu.run_frames(1)
        emu.tracer_stop()
    annotated = annotate_trace(log.read_text(), emu._labels)
    assert "; --- reset ---" in annotated, (
        "expected `reset` label header in annotated trace; got:\n"
        + "\n".join(annotated.splitlines()[:5])
    )
