-- exec_hook.lua: count instructions executed in NMI vector range during 60 frames.

local hits = 0
local pcs = {}

-- NTSC NMI vector at $00FFEA-$00FFEB. SNES jumps to bank 0 by default; cover
-- whole bank 0 ROM region $008000-$00FFFF for a wide net.
local id = emu.add_exec_callback(0x008000, 0x00FFFF, function(pc)
  hits = hits + 1
  pcs[pc] = (pcs[pc] or 0) + 1
end)

emu.run_frames(60)
emu.remove_exec_callback(id)

emu.log("instructions in bank 0 ROM during 60 frames: " .. hits)

-- Show top 5 hottest PCs.
local sorted = {}
for pc, n in pairs(pcs) do sorted[#sorted+1] = {pc, n} end
table.sort(sorted, function(a, b) return a[2] > b[2] end)
emu.log("top 5 hot PCs:")
for i = 1, math.min(5, #sorted) do
  emu.log(string.format("  $%06X: %d hits", sorted[i][1], sorted[i][2]))
end

assert(hits > 0, "expected at least one instruction in bank 0 ROM")
emu.log("=== exec_hook.lua passed ===")
