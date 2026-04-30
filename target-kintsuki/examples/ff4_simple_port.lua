-- Port of ff4 tests/lua/test_simple.lua via mesen_compat shim.
-- Original Mesen API preserved verbatim below the shim load.
dofile(os.getenv("KINTSUKI_ROOT") .. "/target-kintsuki/examples/mesen_compat.lua")

-- ===== ORIGINAL test_simple.lua BELOW (unchanged) =====
emu.log("=== Simple Test ===")

emu.step(10, emu.stepType.ppuFrame)

local ef65 = emu.read16(0xEF65, emu.memType.snesWorkRam)
local ef71 = emu.read(0xEF71, emu.memType.snesWorkRam)

emu.log(string.format("EF65=%d EF71=%d", ef65, ef71))

emu.log("Test complete")
emu.stop(0)
