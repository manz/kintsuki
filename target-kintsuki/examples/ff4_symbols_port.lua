-- Demonstrates the symbol loader against ff4's actual sym file.
dofile(os.getenv("KINTSUKI_ROOT") .. "/target-kintsuki/examples/mesen_compat.lua")
emu.loadLabels(os.getenv("FF4_SYM_PATH"))

local sym = emu.getLabelAddress("GetKerningAdjustmentLinearSearch")
assert(sym, "GetKerningAdjustmentLinearSearch label missing")

emu.log(string.format("GetKerningAdjustmentLinearSearch -> 0x%x (memType=%d)",
  sym.address, sym.memType))

emu.step(10, emu.stepType.ppuFrame)

local first = emu.read(sym.address, sym.memType)
emu.log(string.format("First byte at function entry: 0x%02x", first))

-- Read CPU state — verify regs in plausible range after boot.
local s = emu.getState()
emu.log(string.format("CPU: A=%04X X=%04X Y=%04X PC=%06X P=%02X",
  s.cpu.a, s.cpu.x, s.cpu.y, s.cpu.pc, s.cpu.p))
-- ares performance PPU can sit anywhere in WRAM/ROM after a fixed frame
-- budget; just check the address fits in the 24-bit bus.
assert(s.cpu.pc >= 0 and s.cpu.pc <= 0xFFFFFF, "PC out of range")

emu.stop(0)
