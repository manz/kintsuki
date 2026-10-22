"""Timeline: a Perfetto trace of calls, interrupts, DMA and frames.

`asm/test_timeline.s` loops on `jsr work`; each NMI calls `nmi_sub` and fires
a 32-byte DMA into VMDATA. The trace is decoded here with a minimal protobuf
reader (only the fields kintsuki writes), so the test needs no perfetto.
"""

from __future__ import annotations

import struct
from dataclasses import dataclass, field
from pathlib import Path

import pytest

from kintsuki import Emu

BEGIN, END, INSTANT, COUNTER = 1, 2, 3, 4
VBLANK_LINES = 262 - 225  # NTSC, no overscan


def _varint(buf: bytes, i: int) -> tuple[int, int]:
    value = shift = 0
    while True:
        b = buf[i]
        i += 1
        value |= (b & 0x7F) << shift
        shift += 7
        if b < 0x80:
            return value, i


Field = int | bytes


def _fields(buf: bytes) -> list[tuple[int, Field]]:
    out: list[tuple[int, Field]] = []
    i = 0
    while i < len(buf):
        key, i = _varint(buf, i)
        if key & 7 == 0:
            value, i = _varint(buf, i)
            out.append((key >> 3, value))
        elif key & 7 == 1:  # fixed64: a counter's double
            out.append((key >> 3, buf[i:i + 8]))
            i += 8
        else:
            size, i = _varint(buf, i)
            out.append((key >> 3, buf[i:i + size]))
            i += size
    return out


@dataclass
class Event:
    type: int
    track: str
    ts: int
    name: str
    args: dict[str, int] = field(default_factory=dict)
    category: str = ""
    jpeg: bytes = b""
    value: float | None = None


def _bytes(value: Field) -> bytes:
    assert isinstance(value, bytes)
    return value


def _int(value: Field) -> int:
    assert isinstance(value, int)
    return value


def _decode(path: Path) -> list[Event]:
    tracks: dict[int, str] = {}
    names: dict[int, str] = {}
    events: list[Event] = []
    for num, packet in _fields(path.read_bytes()):
        assert num == 1
        fields = _fields(_bytes(packet))
        ts = next((_int(v) for n, v in fields if n == 8), 0)
        for n, v in fields:
            if n == 60:
                desc = dict(_fields(_bytes(v)))
                tracks[_int(desc[1])] = _bytes(desc[2]).decode()
            elif n == 12:
                for k, entry in _fields(_bytes(v)):
                    if k == 2:
                        e = dict(_fields(_bytes(entry)))
                        names[_int(e[1])] = _bytes(e[2]).decode()
        ev = next((_bytes(v) for n, v in fields if n == 11), None)
        if ev is None:
            continue
        ef = _fields(ev)
        d = dict(ef)
        args = {}
        for k, ann in ef:
            if k == 4:
                a = dict(_fields(_bytes(ann)))
                args[_bytes(a[10]).decode()] = _int(a[3])
        name = names.get(_int(d.get(10, 0)), "")
        category = _bytes(d[22]).decode() if 22 in d else ""
        jpeg = _bytes(dict(_fields(_bytes(d[50])))[1]) if 50 in d else b""
        value = struct.unpack("<d", _bytes(d[44]))[0] if 44 in d else None
        events.append(Event(_int(d[9]), tracks[_int(d[11])], ts, name, args, category, jpeg, value))
    return events


@pytest.fixture
def emu_rom(assemble_rom):
    rom = assemble_rom("test_timeline.s")
    adbg = Path(str(rom) + ".adbg")
    if not adbg.exists():
        pytest.skip(f"missing .adbg next to {rom.name}")
    with Emu() as emu:
        emu.load_rom(str(rom), adbg=str(adbg))
        emu.run_frames(1)
        yield emu


def _symbol(emu: Emu, name: str) -> int:
    addr = emu.lookup_symbol_addr(name)
    assert addr is not None, name
    return addr


@pytest.fixture
def recorded(emu_rom, tmp_path):
    path = tmp_path / "t.pftrace"
    with emu_rom.timeline(path):
        emu_rom.run_frames(5)
    return path


def test_timeline_stop_reports_the_file_size(emu_rom, tmp_path):
    path = tmp_path / "t.pftrace"
    emu_rom.timeline_start(path)
    emu_rom.run_frames(2)
    assert emu_rom.timeline_stop() == path.stat().st_size > 0


def test_timeline_stop_without_start_is_zero(emu_rom):
    assert emu_rom.timeline_stop() == 0


def test_timeline_start_rejects_an_unwritable_path(emu_rom, tmp_path):
    with pytest.raises(OSError):
        emu_rom.timeline_start(tmp_path / "missing" / "t.pftrace")


def test_timeline_declares_its_tracks(recorded):
    tracks = {e.track for e in _decode(recorded)}
    assert {"65816", "Frames", "DMA 0", "Vblank margin"} <= tracks


def test_timeline_slices_balance_on_every_track(recorded):
    depth: dict[str, int] = {}
    for e in _decode(recorded):
        if e.type == BEGIN:
            depth[e.track] = depth.get(e.track, 0) + 1
        elif e.type == END:
            depth[e.track] -= 1
            assert depth[e.track] >= 0
    assert set(depth.values()) == {0}


def test_timeline_has_a_frame_instant_per_frame(recorded):
    frames = [e for e in _decode(recorded) if e.track == "Frames"]
    assert len(frames) == 5


def test_timeline_has_an_nmi_slice_per_frame_at_vblank(recorded):
    nmis = [e for e in _decode(recorded) if e.type == BEGIN and e.name.startswith("NMI ")]
    assert len(nmis) == 5
    assert all(e.name == "NMI nmi" and e.args["line"] == 225 for e in nmis)


def test_timeline_nests_the_nmi_handler_call_inside_the_nmi(recorded):
    stack: list[str] = []
    seen = False
    for e in _decode(recorded):
        if e.track != "65816":
            continue
        if e.type == BEGIN:
            if e.name == "nmi_sub":
                assert stack[-1].startswith("NMI ")
                seen = True
            stack.append(e.name)
        elif e.type == END:
            stack.pop()
    assert seen


def test_timeline_has_a_dma_slice_per_transfer(recorded):
    dma = [e for e in _decode(recorded) if e.track == "DMA 0" and e.type == BEGIN]
    assert len(dma) == 5
    assert all(e.name == "$2118" and e.args["bytes"] == 32 for e in dma)


def test_timeline_dma_slice_lasts_its_bytes(recorded):
    events = [e for e in _decode(recorded) if e.track == "DMA 0"]
    begin, end = events[0], events[1]
    assert (begin.type, end.type) == (BEGIN, END)
    assert 11_000 < end.ts - begin.ts < 13_000  # (8 + 32 * 8) master cycles ~ 12.3 us


def test_timeline_has_an_hdma_slice_per_frame_for_its_lines(recorded):
    events = [e for e in _decode(recorded) if e.track == "HDMA 1"]
    begins = [e for e in events if e.type == BEGIN]
    assert len(begins) == 5
    assert all(e.name == "$2132" and e.args["line"] == 0 for e in begins)
    begin, end = events[0], events[1]
    assert end.type == END
    assert 990_000 < end.ts - begin.ts < 1_040_000  # 16 lines of 1364 master cycles ~ 1.016 ms


def test_timeline_has_no_overruns_under_forced_blank(recorded):
    assert not [e for e in _decode(recorded) if e.track == "Overruns"]


def test_timeline_marks_each_frame_a_vram_write_is_dropped(emu_rom, tmp_path):
    path = tmp_path / "t.pftrace"
    emu_rom.write(0x7E0100, 1)  # OVERRUN in test_timeline.s
    with emu_rom.timeline(path):
        emu_rom.run_frames(3)
    overruns = [e for e in _decode(path) if e.track == "Overruns"]
    assert [e.name for e in overruns] == ["VRAM overrun"] * 3
    assert all(0 <= e.args["line"] < 225 for e in overruns)


def _margins(path: Path) -> list[float]:
    return [e.value for e in _decode(path) if e.track == "Vblank margin" and e.type == COUNTER]


def test_timeline_vblank_margin_is_the_whole_vblank_under_forced_blank(recorded):
    margins = _margins(recorded)
    assert len(margins) >= 4  # a sample per vblank the trace saw begin
    assert margins == [VBLANK_LINES] * len(margins)


def test_timeline_vblank_margin_counts_the_lines_after_the_last_landed_write(emu_rom, tmp_path):
    path = tmp_path / "t.pftrace"
    emu_rom.write(0x7E0100, 1)  # OVERRUN: screen on, `work` writes VMDATA all vblank long
    with emu_rom.timeline(path):
        emu_rom.run_frames(4)
    margins = _margins(path)
    assert len(margins) >= 3
    assert all(0 <= m < 8 for m in margins)  # a `work` pass, its last write's distance to line 0, is ~6 lines


def test_timeline_mark_lands_on_the_marks_track(emu_rom, tmp_path):
    path = tmp_path / "t.pftrace"
    sub = _symbol(emu_rom, "nmi_sub")
    emu_rom.add_exec_callback(sub, sub, lambda pc, v: emu_rom.timeline_mark("sub"))
    with emu_rom.timeline(path):
        emu_rom.run_frames(3)
    marks = [e for e in _decode(path) if e.track == "Marks"]
    assert [e.name for e in marks] == ["sub"] * 3


def test_timeline_has_no_screenshots_by_default(recorded):
    assert not [e for e in _decode(recorded) if e.name == "Screenshot"]


def test_timeline_screenshots_every_nth_frame_as_jpeg(emu_rom, tmp_path):
    path = tmp_path / "t.pftrace"
    with emu_rom.timeline(path, screenshot_every=2):
        emu_rom.run_frames(4)
    shots = [e for e in _decode(path) if e.name == "Screenshot"]
    assert len(shots) == 2
    assert all(e.category == "android_screenshot" and e.jpeg[:2] == b"\xff\xd8" for e in shots)


def test_nmi_is_a_callstack_frame(emu_rom):
    snaps = []
    sub = _symbol(emu_rom, "nmi_sub")
    emu_rom.add_exec_callback(sub, sub, lambda pc, v: snaps.append(emu_rom.callstack(4)))
    emu_rom.run_frames(2)
    assert snaps
    _, target, kind = snaps[0][1]
    assert (target, kind) == (_symbol(emu_rom, "nmi"), 2)


def test_profiler_counts_the_nmi_as_its_own_function(emu_rom):
    emu_rom.profile_start()
    emu_rom.run_frames(10)
    stats = {s.pc: s for s in emu_rom.profile_stop()}
    assert 9 <= stats[_symbol(emu_rom, "nmi")].calls <= 10
