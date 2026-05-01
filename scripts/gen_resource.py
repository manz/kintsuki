#!/usr/bin/env python3
"""Generate ares' resource.hpp / resource.cpp from resource.bml.

Upstream ares ships a `sourcery` tool that bakes PNG/file content into C++
arrays. kintsuki strips that tool out — it never renders anything, so we
emit empty `std::vector<uint8_t>` definitions for every binary entry. This
keeps the symbol surface intact (controller.cpp and friends include the
header even though the tests never instantiate light-gun controllers),
without dragging in image asset bytes.

Usage: gen_resource.py <input.bml> <output.hpp> <output.cpp>
"""
from __future__ import annotations

import sys
from pathlib import Path
from typing import Iterator


def parse_bml(text: str) -> Iterator[tuple[int, str, dict[str, str]]]:
    for raw in text.splitlines():
        line = raw.rstrip()
        stripped = line.lstrip()
        if not stripped or stripped.startswith("//"):
            continue
        indent = (len(line) - len(stripped)) // 2
        parts = stripped.split()
        kind = parts[0]
        attrs = {}
        for p in parts[1:]:
            if "=" in p:
                k, v = p.split("=", 1)
                attrs[k] = v
        yield indent, kind, attrs


def emit(bml_path: Path, hpp_path: Path, cpp_path: Path) -> None:
    ns_stack: list[tuple[int, str]] = []
    decls: list[tuple[list[str], str]] = []  # (namespace path, name)

    for indent, kind, attrs in parse_bml(bml_path.read_text()):
        while ns_stack and ns_stack[-1][0] >= indent:
            ns_stack.pop()
        if kind == "namespace":
            ns_stack.append((indent, attrs["name"]))
        elif kind == "binary":
            ns_path = [n for _, n in ns_stack]
            decls.append((ns_path, attrs["name"]))

    def open_ns(out: list[str], path: list[str]) -> None:
        for n in path:
            out.append(f"namespace {n} {{")

    def close_ns(out: list[str], path: list[str]) -> None:
        for n in reversed(path):
            out.append(f"}}  // namespace {n}")

    hpp = ["// Auto-generated from resource.bml by scripts/gen_resource.py.",
           "// Do not edit by hand — re-run the generator if resource.bml changes.",
           "#pragma once",
           "#include <cstdint>",
           "#include <vector>",
           ""]

    cpp = ["// Auto-generated from resource.bml by scripts/gen_resource.py.",
           "// Definitions are empty: kintsuki is headless and never renders",
           "// these assets. Symbols exist purely to satisfy linker references",
           "// from light-gun controllers and similar code paths.",
           "#include <ares/resource/resource.hpp>",
           ""]

    # Group entries by their namespace path to minimize open/close churn.
    last_path: list[str] | None = None
    for path, name in decls:
        if path != last_path:
            if last_path is not None:
                close_ns(hpp, last_path)
                close_ns(cpp, last_path)
                hpp.append("")
                cpp.append("")
            open_ns(hpp, path)
            open_ns(cpp, path)
            last_path = path
        hpp.append(f"  extern const std::vector<uint8_t> {name};")
        cpp.append(f"  const std::vector<uint8_t> {name} = {{}};")

    if last_path is not None:
        close_ns(hpp, last_path)
        close_ns(cpp, last_path)

    hpp_path.write_text("\n".join(hpp) + "\n")
    cpp_path.write_text("\n".join(cpp) + "\n")


def main() -> int:
    if len(sys.argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    emit(Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
