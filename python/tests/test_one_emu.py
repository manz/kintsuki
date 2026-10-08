"""kintsuki runs one emulator per process (a single native handle). An Emu
left open used to share it with the next one, then destroy it from its
finaliser at some later point - under the new Emu, at a reused address (a
use-after-free that crashed long test suites at random). A new Emu now closes
the previous one, and close() unregisters its callbacks before freeing their
trampolines."""

from __future__ import annotations

from pathlib import Path

import pytest

from kintsuki import Emu


@pytest.fixture
def rom(assemble_rom) -> Path:
    return assemble_rom("test_sram.s")


def test_a_new_emu_closes_the_previous_one(rom: Path) -> None:
    a = Emu(load_srm_sidecar=False)
    a.load_rom(str(rom))
    with pytest.warns(ResourceWarning, match="still open"):
        b = Emu(load_srm_sidecar=False)
    assert a._handle is None
    a.close()  # a no-op now
    b.load_rom(str(rom))
    b.run_frames(2)
    b.close()


def test_a_closed_emus_callbacks_stop_firing(rom: Path) -> None:
    hits: list[int] = []
    a = Emu(load_srm_sidecar=False)
    a.load_rom(str(rom))
    a.add_write_callback(0x7E0000, 0x7FFFFF, lambda addr, _v: hits.append(addr))
    a.close()
    with Emu(load_srm_sidecar=False) as b:
        b.load_rom(str(rom))
        b.run_frames(4)
    assert hits == []
