dofile(os.getenv("KINTSUKI_ROOT") .. "/target-kintsuki/examples/mesen_compat.lua")

-- ===== ORIGINAL test_minimal.lua BELOW (unchanged) =====
emu.log("TEST: Script started")
emu.log("TEST: About to stop with code 0")
emu.stop(0)
