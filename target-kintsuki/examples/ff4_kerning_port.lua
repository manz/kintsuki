-- Port of ff4 simple_kerning_test.lua. Original used emu.displayMessage
-- (Mesen UI overlay) — replaced with emu.log. emu.getState/setState path
-- preserved as commented-out section since stepping/breakpoints aren't ported.

dofile(os.getenv("KINTSUKI_ROOT") .. "/target-kintsuki/examples/mesen_compat.lua")
emu.loadLabels(os.getenv("FF4_SYM_PATH"))

local function log(msg) emu.log(msg) end

log("=== Kerning Data Inspection ===")

local count_addr = emu.getLabelAddress("kerning_search_count")
local data_addr  = emu.getLabelAddress("kerning_search_data")

assert(count_addr, "kerning_search_count label not found")
assert(data_addr,  "kerning_search_data label not found")

log("kerning_search_count: " .. string.format("0x%x", count_addr.address))
log("kerning_search_data:  " .. string.format("0x%x", data_addr.address))

-- Run enough frames so loaded ROM is fully visible (boot decompresses content).
emu.step(60, emu.stepType.ppuFrame)

local count = emu.read16(count_addr.address, count_addr.memType)
log(string.format("Kerning pairs count: %d", count))

log("First 5 entries:")
for i = 0, math.min(4, count - 1) do
  local off = i * 3
  local c1 = emu.read(data_addr.address + off,     data_addr.memType)
  local c2 = emu.read(data_addr.address + off + 1, data_addr.memType)
  local k  = emu.read(data_addr.address + off + 2, data_addr.memType)
  log(string.format("  [%d] 0x%02x,0x%02x -> kerning=%d", i, c1, c2, k))
end

log("Searching for pair (0x5c, 0x57) = 'Va':")
local target_c1, target_c2 = 0x5c, 0x57
local found = false
for i = 0, count - 1 do
  local off = i * 3
  local c1 = emu.read(data_addr.address + off,     data_addr.memType)
  local c2 = emu.read(data_addr.address + off + 1, data_addr.memType)
  if c1 == target_c1 and c2 == target_c2 then
    local k = emu.read(data_addr.address + off + 2, data_addr.memType)
    log(string.format("  Found at index %d: kerning=%d", i, k))
    found = true
    break
  end
end
if not found then log("  Not found in data!") end

emu.stop(0)
