# Building

## Native + Python wheel

```bash
make build           # cmake + ninja → build/ares/target-kintsuki/libkintsuki.dylib
make python-stage    # copies the dylib + ares System pak into python/src/kintsuki/_lib/
make tests           # full pytest suite against an FF4 ROM stub (no real ROM in CI)
make wheels          # py3-none-any wheel; CI retags per platform after `wheel tags`
```

Top-level `Makefile` orchestrates everything; `VERSION ?= 0.0.0.dev0` is
exported into the build environment so hatchling's `env`-based version
source resolves at non-tagged commits.

## macOS app

```bash
cd app
xcodegen
xcodebuild -project Kintsuki.xcodeproj -scheme Kintsuki -configuration Release build
```

`Release` builds emit:

- `Build/Products/Release/Kintsuki.app`
- `Build/Products/Release/Kintsuki.app.dSYM` (Swift symbols)
- `Build/Products/Release/libkintsuki.dylib.dSYM` (C++ symbols, via post-build `dsymutil`)

Hardened runtime is intentionally off so `instruments` can attach to a
locally-built ad-hoc-signed dylib without Team-ID library validation
complaining.

## Releasing

Tag-driven. `master` HEAD only; alpha series `vN.N.NaM`.

```bash
git tag -s v0.0.0aN master -m v0.0.0aN
git push origin v0.0.0aN
```

`.github/workflows/release.yml` picks up the `v*` tag, builds the wheel
on Linux + macOS arm64, retags via `python -m wheel tags --platform-tag
<plat>`, runs `auditwheel` on the Linux artifact, and publishes a
GitHub Release. Tags must be GPG-signed (or `-a` annotated); the
release workflow doesn't verify the signature itself, but commit
sign-off is the convention.

## Layout

```
target-kintsuki/    — C ABI shim around ares (libkintsuki.dylib)
ares/               — vendored ares core (patched: WDC65816 hooks, SFC bail flag)
python/             — Python wrapper (wheel)
app/                — Swift macOS app (XcodeGen)
docs/               — this site
```
