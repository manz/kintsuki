"""Phase 4b — input scripting via fluent builder.

Replaces a tokenized DSL with a typed Sequence object so IDE autocomplete
works and the action list is composable / inspectable. Each call queues a
dataclass action; `.run(emu)` flattens repeats and translates the
timeline into per-frame button-mask updates via the existing
`Emu.press()` / `Emu.release()` C API.
"""

from __future__ import annotations

import pytest

from kintsuki import Button
from kintsuki.input import Sequence, Press, Wait, ReleaseAll


class _FakeEmu:
    """Minimal stub that records the (button, pressed) calls Sequence
    issues. Lets us test the builder without a real ROM."""

    def __init__(self) -> None:
        self.events: list[tuple[str, int, int]] = []
        self.frame_advances = 0

    def press(self, port: int, button: int, pressed: bool = True) -> None:
        self.events.append(("press" if pressed else "release", port, button))

    def release(self, port: int, button: int) -> None:
        self.events.append(("release", port, button))

    def run_frames(self, n: int) -> None:
        self.frame_advances += n


def test_sequence_press_then_run():
    """Single press: emits press, advances `frames`, emits release."""
    seq = Sequence().press(Button.DOWN, frames=6)
    emu = _FakeEmu()
    seq.run(emu)
    assert emu.frame_advances == 6
    assert ("press", 1, Button.DOWN) in emu.events
    assert ("release", 1, Button.DOWN) in emu.events
    # Press happens before frames advance, release after.
    press_idx = emu.events.index(("press", 1, Button.DOWN))
    release_idx = emu.events.index(("release", 1, Button.DOWN))
    assert press_idx < release_idx


def test_sequence_chains():
    """Fluent: builder returns self for chaining."""
    seq = Sequence().press(Button.A, frames=3).press(Button.B, frames=4)
    emu = _FakeEmu()
    seq.run(emu)
    assert emu.frame_advances == 7  # 3 + 4


def test_sequence_repeat_unrolls():
    """`.repeat(sub, count=N)` plays the inner sequence N times."""
    inner = Sequence().press(Button.DOWN, frames=2)
    seq = Sequence().repeat(inner, count=3)
    emu = _FakeEmu()
    seq.run(emu)
    assert emu.frame_advances == 6  # 3 × 2
    presses = [e for e in emu.events if e[0] == "press"]
    assert len(presses) == 3, f"expected 3 DOWN presses, got {presses}"


def test_sequence_wait_advances_no_press():
    seq = Sequence().wait(frames=10)
    emu = _FakeEmu()
    seq.run(emu)
    assert emu.frame_advances == 10
    assert emu.events == []


def test_sequence_release_all():
    """`release_all()` releases every button currently down — useful
    after stuck presses or when sequencing different action groups."""
    seq = (Sequence()
           .press(Button.A, frames=2)
           .release_all())
    emu = _FakeEmu()
    seq.run(emu)
    # Press, then release of A (from press), then release_all (which is
    # idempotent — no extra release if A wasn't held by us). At minimum
    # we expect at least one release for A.
    rel_count = sum(1 for e in emu.events if e[0] == "release")
    assert rel_count >= 1


def test_action_dataclasses_are_inspectable():
    """The actions list survives builder construction so debuggers /
    diffs can inspect what's queued before run()."""
    inner = Sequence().press(Button.UP, frames=4)
    seq = (Sequence()
           .press(Button.DOWN, frames=6)
           .wait(frames=20)
           .repeat(inner, count=2))
    actions = seq.actions
    assert any(isinstance(a, Press) and a.button == Button.DOWN for a in actions)
    assert any(isinstance(a, Wait) and a.frames == 20 for a in actions)


def test_press_count_keyword_repeats_inline():
    """Common pattern: `press(BUTTON, count=5)` is sugar for repeat-of-press."""
    seq = Sequence().press(Button.DOWN, frames=2, count=5)
    emu = _FakeEmu()
    seq.run(emu)
    assert emu.frame_advances == 10  # 5 × 2
    presses = [e for e in emu.events if e[0] == "press"]
    assert len(presses) == 5


def test_explicit_port():
    seq = Sequence().press(Button.START, frames=4, port=2)
    emu = _FakeEmu()
    seq.run(emu)
    presses = [e for e in emu.events if e[0] == "press"]
    assert presses[0] == ("press", 2, Button.START)


def test_invalid_count_raises():
    with pytest.raises(ValueError):
        Sequence().press(Button.A, frames=1, count=0)
    with pytest.raises(ValueError):
        Sequence().repeat(Sequence().press(Button.A, frames=1), count=-1)
