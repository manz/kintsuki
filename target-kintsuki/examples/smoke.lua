-- snestest smoke test: exercise full Lua API surface end-to-end.

emu.log("=== smoke.lua ===")

-- Boot stabilization.
emu.run_frames(120)
emu.log("frames after boot: " .. emu.frame_count())

-- Memory peek (WRAM at $7E0000+).
local b = emu.read_u8(0x7E1700)
emu.log(string.format("0x7E1700 = 0x%02X", b))

-- Held input across frames.
emu.press(0, "Start")
emu.run_frames(60)
emu.release(0, "Start")
emu.run_frames(30)

-- Savestate roundtrip via blob.
local blob = emu.save_state()
emu.log("savestate size: " .. #blob .. " bytes")
emu.run_frames(60)
local ok = emu.load_state(blob)
assert(ok, "load_state(blob) failed")
emu.log("savestate roundtrip ok")

-- Screenshot.
assert(emu.screenshot("/tmp/smoke.ppm"), "screenshot failed")
emu.log("wrote /tmp/smoke.ppm")

emu.log("=== smoke.lua passed ===")
