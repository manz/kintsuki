dofile(os.getenv("KINTSUKI_ROOT") .. "/target-kintsuki/examples/mesen_compat.lua")

-- ===== ORIGINAL test_sanity.lua BELOW (unchanged) =====
local TEST_PASSED = 0
local TEST_FAILED = 1

emu.log("=== Sanity Test ===")

local val = emu.read(0x0000, emu.memType.snesWorkRam)
emu.log("Read WRAM $0000: " .. string.format("%02X", val))

local rom_val = emu.read(0x8000, emu.memType.snesPrgRom)
emu.log("Read ROM $8000: " .. string.format("%02X", rom_val))

local frame_count = 0
emu.addEventCallback(function()
    frame_count = frame_count + 1
    if frame_count == 3 then
        emu.log("Completed " .. frame_count .. " frames")
        emu.log("=== Sanity Test PASSED ===")
        emu.stop(TEST_PASSED)
    end
end, emu.eventType.endFrame)

emu.log("Waiting for 3 frames...")
