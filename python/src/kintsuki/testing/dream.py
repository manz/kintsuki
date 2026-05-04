"""Failure-dump helper for the kintsuki test loop.

`dump_on_failure(emu, recorder, *, out_dir)` writes:

  - Every retained frame from the recorder as `frame_NNN.png`
  - A `state.json` capturing the emulator's CPU + PPU state plus
    SHA-1 fingerprints + sizes of WRAM/VRAM/CGRAM/OAM (memory blobs
    are omitted from the JSON to keep it small; callers re-dump
    raw memory via `emu.read_range` / `vram_dump` if they need it).

`snapshot_to_json(state)` turns a `StateSnapshot` into a JSON-friendly
dict for the same purpose, exposed standalone so tests can store
arbitrary structural snapshots without the PNG dump.

Both helpers are explicit — no autouse magic. Tests opt in by calling
them from their own teardown / fixture / pytest hook. Explicit > implicit.
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import asdict, fields, is_dataclass
from pathlib import Path
from typing import Any

from ..diff import StateSnapshot, snapshot
from ..recorder import FrameRecorder


def dump_on_failure(emu: Any, recorder: FrameRecorder, *,
                    out_dir: str | Path) -> list[Path]:
    """Write the recorder's PNGs + a state.json into `out_dir`.
    Returns the list of every file written (PNGs + state.json)."""
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    paths = list(recorder.dump_pngs(out_dir))

    state = snapshot(emu)
    state_path = out_dir / "state.json"
    state_path.write_text(json.dumps(snapshot_to_json(state),
                                     indent=2, sort_keys=True))
    paths.append(state_path)
    return paths


def snapshot_to_json(state: StateSnapshot) -> dict[str, Any]:
    """JSON-friendly dict from a StateSnapshot. CPU + PPU registers
    serialized in full; memory blobs replaced with SHA-1 fingerprint +
    byte size to keep the file small + diff-able."""
    return {
        "cpu": _struct_to_dict(state.cpu),
        "ppu": _struct_to_dict(state.ppu),
        "wram_sha1": _sha1(state.wram), "wram_size": len(state.wram),
        "vram_sha1": _sha1(state.vram), "vram_size": len(state.vram),
        "cgram_sha1": _sha1(state.cgram), "cgram_size": len(state.cgram),
        "oam_sha1":  _sha1(state.oam),  "oam_size":  len(state.oam),
    }


def _sha1(b: bytes) -> str:
    return hashlib.sha1(b).hexdigest()


def _struct_to_dict(obj: Any) -> dict[str, Any]:
    """Reduce a dataclass-or-attr-bag to a JSON-serializable dict.
    Recurses into nested dataclasses (e.g., DmaChannelState entries)."""
    if obj is None:
        return {}
    if is_dataclass(obj) and not isinstance(obj, type):
        out: dict[str, Any] = {}
        for f in fields(obj):
            v = getattr(obj, f.name)
            out[f.name] = _to_jsonable(v)
        return out
    # Plain attribute bag (test stubs).
    out = {}
    for name in dir(obj):
        if name.startswith("_"):
            continue
        v = getattr(obj, name)
        if callable(v):
            continue
        out[name] = _to_jsonable(v)
    return out


def _to_jsonable(v: Any) -> Any:
    if is_dataclass(v) and not isinstance(v, type):
        return {f.name: _to_jsonable(getattr(v, f.name)) for f in fields(v)}
    if isinstance(v, (tuple, list)):
        return [_to_jsonable(x) for x in v]
    if isinstance(v, (bytes, bytearray)):
        return f"<{len(v)} bytes sha1={_sha1(bytes(v))}>"
    if isinstance(v, (int, str, float, bool)) or v is None:
        return v
    return repr(v)
