"""Input scripting via fluent builder.

A `Sequence` is an ordered list of dataclass actions (`Press`, `Wait`,
`ReleaseAll`, `Repeat`). `.run(emu)` flattens repeats and translates the
timeline into per-frame button-mask updates via `Emu.press()` /
`Emu.release()` / `Emu.run_frames()`.

Why a builder + dataclasses, not a text DSL: IDE autocomplete works on
button names, the action list survives construction (debuggable), and
composing sub-sequences via `.repeat(inner, count=N)` is just normal
Python — no parser, no quoting issues, no surprises.

Usage:

    from kintsuki import Button
    from kintsuki.input import Sequence

    (Sequence()
        .press(Button.DOWN, frames=6)
        .press(Button.A,    frames=6)
        .repeat(Sequence().press(Button.DOWN, frames=6), count=5)
        .wait(60)
        .run(emu))
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Protocol


class _EmuLike(Protocol):
    """Minimal surface Sequence.run() needs from an Emu."""

    def press(self, port: int, button: int, pressed: bool = True) -> None: ...
    def release(self, port: int, button: int) -> None: ...
    def run_frames(self, n: int) -> None: ...


# ---- Action dataclasses ---------------------------------------------------
@dataclass(frozen=True)
class Press:
    """Press `button` on `port` for `frames` frames, then release."""

    button: int
    frames: int
    port: int = 1


@dataclass(frozen=True)
class Wait:
    """Advance the emulator by `frames` frames with no input change."""

    frames: int


@dataclass(frozen=True)
class ReleaseAll:
    """Release every button this Sequence has currently held."""


@dataclass(frozen=True)
class Repeat:
    """Inline sub-sequence repeated `count` times."""

    inner: "Sequence"
    count: int


_Action = Press | Wait | ReleaseAll | Repeat


# ---- Builder --------------------------------------------------------------
@dataclass
class Sequence:
    """Fluent input-timeline builder. Chain calls then `.run(emu)`."""

    actions: list[_Action] = field(default_factory=list)

    def press(self, button: int, *, frames: int, port: int = 1,
              count: int = 1) -> "Sequence":
        if count < 1:
            raise ValueError(f"count must be >= 1, got {count}")
        if count == 1:
            self.actions.append(Press(button=button, frames=frames, port=port))
        else:
            sub = Sequence([Press(button=button, frames=frames, port=port)])
            self.actions.append(Repeat(inner=sub, count=count))
        return self

    def wait(self, frames: int) -> "Sequence":
        if frames < 0:
            raise ValueError(f"frames must be >= 0, got {frames}")
        self.actions.append(Wait(frames=frames))
        return self

    def release_all(self) -> "Sequence":
        self.actions.append(ReleaseAll())
        return self

    def repeat(self, inner: "Sequence", *, count: int) -> "Sequence":
        if count < 1:
            raise ValueError(f"repeat count must be >= 1, got {count}")
        self.actions.append(Repeat(inner=inner, count=count))
        return self

    def run(self, emu: _EmuLike) -> None:
        held: set[tuple[int, int]] = set()
        for act in _flatten(self.actions):
            if isinstance(act, Press):
                emu.press(act.port, act.button, True)
                held.add((act.port, act.button))
                emu.run_frames(act.frames)
                emu.release(act.port, act.button)
                held.discard((act.port, act.button))
            elif isinstance(act, Wait):
                if act.frames > 0:
                    emu.run_frames(act.frames)
            elif isinstance(act, ReleaseAll):
                for port, btn in list(held):
                    emu.release(port, btn)
                held.clear()


def _flatten(actions: list[_Action]) -> list[_Action]:
    """Expand `Repeat` actions in place; returns a flat list of leaf
    actions (Press / Wait / ReleaseAll)."""
    out: list[_Action] = []
    for a in actions:
        if isinstance(a, Repeat):
            for _ in range(a.count):
                out.extend(_flatten(a.inner.actions))
        else:
            out.append(a)
    return out
