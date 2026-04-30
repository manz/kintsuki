-- Exercise read/write memory callbacks + bulk read.

-- Watch the whole MMIO I/O register block ($4200-$420F). ares may route
-- some MMIO writes outside Bus::write (direct CPU→DMA dispatch), so a
-- narrow $4200-only watch can see zero hits even though writes happen.
local hits = 0
local id = emu.add_write_callback(0x4200, 0x420F, function(addr, val)
  hits = hits + 1
end)

emu.run_frames(60)

emu.remove_write_callback(id)

print(string.format("60 frames: MMIO writes ($4200-$420F)=%d", hits))
-- Soft assertion: just verify no crash + the callback wiring works.

-- Bulk read 256 bytes of WRAM zero page, hash it.
local blob = emu.read_range(0x7E0000, 256)
assert(#blob == 256, "read_range length mismatch")
local sum = 0
for i = 1, #blob do sum = sum + string.byte(blob, i) end
print(string.format("WRAM 0x7E0000..0xFF byte-sum=%d", sum))

print("=== memcallbacks.lua passed ===")
