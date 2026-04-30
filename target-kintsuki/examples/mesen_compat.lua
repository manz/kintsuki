-- Mesen 2 compatibility shim for snestest.
-- Maps Mesen's emu.* API onto our native bindings so ff4 tests run unmodified.
-- dofile() this at the top of a ported test.

local native = emu  -- snestest's native bindings

-- =============================================================================
-- Memory type enum (mirrors Mesen 2)
-- =============================================================================
emu.memType = {
  snesWorkRam = 1,   -- 128KB WRAM, addressed 0..0x1FFFF
  snesSaveRam = 2,   -- cart SRAM (cart-mapped, route via bus)
  snesPrgRom  = 3,   -- ROM (route via bus, bank 0)
  snesVram    = 4,
  snesCgRam   = 5,
  snesOamRam  = 6,
  snesSpcRam  = 7,   -- not yet supported
}

-- Snake-case alias used by some tests.
emu.memType.snesWorkRam = emu.memType.snesWorkRam

-- =============================================================================
-- emu.read / emu.write with memType dispatch
-- =============================================================================
local band = bit.band
local function bus_wram(addr) return 0x7E0000 + band(addr, 0x1FFFF) end

local read_dispatch = {
  [emu.memType.snesWorkRam] = function(addr) return native.read_u8(bus_wram(addr)) end,
  [emu.memType.snesSaveRam] = function(addr) return native.read_u8(addr) end,  -- cart-mapped
  [emu.memType.snesPrgRom]  = function(addr) return native.read_u8(addr) end,  -- bank-direct
  [emu.memType.snesVram]    = function(addr) return native.vram_read(addr) end,
  [emu.memType.snesCgRam]   = function(addr) return native.cgram_read(addr) end,
  [emu.memType.snesOamRam]  = function(addr) return native.oam_read(addr) end,
}
local write_dispatch = {
  [emu.memType.snesWorkRam] = function(addr, v) native.write_u8(bus_wram(addr), v) end,
  [emu.memType.snesSaveRam] = function(addr, v) native.write_u8(addr, v) end,
  [emu.memType.snesVram]    = function(addr, v) native.vram_write(addr, v) end,
  [emu.memType.snesCgRam]   = function(addr, v) native.cgram_write(addr, v) end,
  [emu.memType.snesOamRam]  = function(addr, v) native.oam_write(addr, v) end,
}

emu.read = function(addr, memType)
  local fn = read_dispatch[memType]
  if not fn then error("unsupported memType: " .. tostring(memType)) end
  return fn(addr)
end

emu.read16 = function(addr, memType)
  local lo = emu.read(addr,     memType)
  local hi = emu.read(addr + 1, memType)
  return lo + hi * 256
end

emu.write = function(addr, value, memType)
  local fn = write_dispatch[memType]
  if not fn then error("unsupported memType: " .. tostring(memType)) end
  fn(addr, value)
end

-- =============================================================================
-- Frame stepping (Mesen's emu.step replaced by run_frames)
-- =============================================================================
emu.stepType = { ppuFrame = 1, cycle = 2, instruction = 3 }

emu.step = function(n, stepType)
  if stepType ~= emu.stepType.ppuFrame then
    error("only stepType.ppuFrame supported (got " .. tostring(stepType) .. ")")
  end
  native.run_frames(n)
end

-- =============================================================================
-- Event callbacks (frame end is the only one ff4 uses)
-- =============================================================================
emu.eventType = { endFrame = 1, inputPolled = 2, nmi = 3, scanline = 4 }

local frame_callbacks = {}
local drive_armed = false

emu.addEventCallback = function(fn, eventType)
  if eventType ~= emu.eventType.endFrame then
    error("only eventType.endFrame supported (got " .. tostring(eventType) .. ")")
  end
  table.insert(frame_callbacks, fn)
  drive_armed = true
  return #frame_callbacks
end

-- Run frames + dispatch callbacks until os.exit fires.
-- Hard cap at 1 hour of emulated time so a runaway test eventually fails.
local DRIVE_FRAME_CAP = 60 * 60 * 60  -- 60fps * 3600s
emu._shim_drive_loop = function()
  if not drive_armed then return end
  for _ = 1, DRIVE_FRAME_CAP do
    native.run_frames(1)
    for _, cb in ipairs(frame_callbacks) do cb() end
  end
  io.stderr:write("snestest: shim drive loop hit frame cap, no emu.stop() reached\n")
  os.exit(124)
end

-- =============================================================================
-- Stop / exit
-- =============================================================================
emu.stop = function(code) os.exit(code or 0) end

-- =============================================================================
-- Input
-- =============================================================================
emu.setInput = function(state, port, _ctrl)
  port = port or 0
  native.clear_input()
  for btn, pressed in pairs(state) do
    if pressed then native.press(port, btn) end
  end
end

-- =============================================================================
-- Screenshot (Mesen returns PNG bytes; we accept path)
-- =============================================================================
emu.takeScreenshot = function(path)
  if path then return native.screenshot(path) end
  -- Mesen returns bytes; we don't yet. Path-only for now.
  error("emu.takeScreenshot() without path not yet supported")
end

-- =============================================================================
-- Savestate (Mesen takes binary string)
-- =============================================================================
emu.loadSavestate = function(blob)
  return native.load_state(blob)
end
emu.saveSavestate = function() return native.save_state() end

-- =============================================================================
-- CPU state (Mesen 2 returns a nested {cpu = {a=..., x=..., ...}} table).
-- =============================================================================
emu.getState = function()
  return { cpu = native.get_state() }
end

emu.setState = function(state)
  native.set_state(state.cpu or state)
end

-- =============================================================================
-- Symbol loader (Mesen .sym format: [labels] header, "BANK:OFFSET name" rows).
-- =============================================================================
local labels = {}

local function classify(bank, offset)
  -- Bank 0x7E / 0x7F = WRAM directly mapped.
  if bank == 0x7E or bank == 0x7F then
    return (bank - 0x7E) * 0x10000 + offset, emu.memType.snesWorkRam
  end
  -- Bank 0 low ($00:0000-$00:1FFF) mirrors zero-page WRAM.
  if bank == 0 and offset < 0x2000 then
    return offset, emu.memType.snesWorkRam
  end
  -- Everything else: treat as ROM via CPU bus address.
  return bank * 0x10000 + offset, emu.memType.snesPrgRom
end

emu.loadLabels = function(path)
  local f = io.open(path, "r")
  if not f then error("cannot open sym file: " .. path) end
  for line in f:lines() do
    local b, o, name = line:match("^%s*(%x+):(%x+)%s+(%S+)")
    if b and o and name then
      local bank = tonumber(b, 16)
      local offset = tonumber(o, 16)
      local addr, mt = classify(bank, offset)
      labels[name] = { address = addr, memType = mt }
    end
  end
  f:close()
end

emu.getLabelAddress = function(name)
  return labels[name]
end

-- =============================================================================
-- Memory callbacks (stubbed — exec hook only)
-- =============================================================================
emu.callbackType = { exec = 1, read = 2, write = 3 }

emu.addMemoryCallback = function(fn, cbType, lo, hi)
  if cbType == emu.callbackType.exec then
    return { kind = "exec", id = native.add_exec_callback(lo, hi, fn) }
  elseif cbType == emu.callbackType.read then
    return { kind = "read", id = native.add_read_callback(lo, hi, fn) }
  elseif cbType == emu.callbackType.write then
    return { kind = "write", id = native.add_write_callback(lo, hi, fn) }
  end
  error("unknown callbackType: " .. tostring(cbType))
end

emu.removeMemoryCallback = function(handle, _cbType, _lo, _hi)
  -- Mesen's API takes the handle returned by addMemoryCallback.
  if type(handle) == "table" then
    if handle.kind == "exec"  then native.remove_exec_callback(handle.id)
    elseif handle.kind == "read"  then native.remove_read_callback(handle.id)
    elseif handle.kind == "write" then native.remove_write_callback(handle.id)
    end
  else
    -- Backwards-compat: bare exec id.
    native.remove_exec_callback(handle)
  end
end

-- =============================================================================
-- Bulk read / display message
-- =============================================================================
emu.read_range = native.read_range  -- snestest extension; CPU bus only

emu.displayMessage = function(category, msg)
  if msg == nil then msg = category; category = "info" end
  io.stderr:write("[" .. tostring(category) .. "] " .. tostring(msg) .. "\n")
end
