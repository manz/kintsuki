"""Pytest fixtures for kintsuki tests.

Provides a session-scoped `assemble_rom` fixture that runs `a816 -f sfc`
on demand to (re)build a test ROM whenever its `.s` source is newer than
the cached `.sfc`. Tests don't ship .sfc binaries — fresh ROMs are built
locally + in CI.

Usage:
    def test_my_feature(assemble_rom):
        rom = assemble_rom("test_ppu_state.s")  # path to .sfc
        ...
"""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest


_ASM_DIR = Path(__file__).parent / "asm"


def _need_a816() -> str:
    """Locate the a816 assembler executable; skip if missing."""
    exe = shutil.which("a816")
    if exe is None:
        pytest.skip("a816 assembler not on PATH; install from "
                    "https://github.com/manz/a816")
    return exe


@pytest.fixture(scope="session")
def assemble_rom():
    """Returns a callable that takes the .s filename (relative to
    `tests/asm/`) and returns the assembled `.sfc` Path. Caches between
    tests; rebuilds when .s is newer than .sfc."""
    a816_exe = _need_a816()

    def _build(asm_filename: str) -> Path:
        asm_path = _ASM_DIR / asm_filename
        if not asm_path.exists():
            pytest.fail(f"asm source not found: {asm_path}")
        sfc_path = asm_path.with_suffix(".sfc")
        if sfc_path.exists() and sfc_path.stat().st_mtime >= asm_path.stat().st_mtime:
            return sfc_path
        result = subprocess.run(
            [a816_exe, "-f", "sfc", "-o", str(sfc_path), str(asm_path)],
            capture_output=True, text=True,
        )
        if result.returncode != 0:
            pytest.fail(
                f"a816 failed for {asm_path.name}:\n"
                f"--- stdout ---\n{result.stdout}\n"
                f"--- stderr ---\n{result.stderr}"
            )
        return sfc_path

    return _build
