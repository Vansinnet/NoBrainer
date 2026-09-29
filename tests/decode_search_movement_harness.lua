-- Offline harness: NoBrainer Decode Search movement vs native MinigameDecodeSearch.on_axis_set
-- (Darktide 1.13.0: 0.5 deadzone, 0.25 s repeat lock reset by neutral input, server-only moves,
-- cursor replicated by RPC). Models one-way latency rtt/2 both ways, lost direction commands
-- (drop) and spurious extra server steps (extra, overshoot).
-- Run from the NoBrainer mod root:
--   ..\..\..\tools\luajit\luajit.exe tests\decode_search_movement_harness.lua SEED RTT_S DROP EXTRA BOARDS [PACING] [host]
-- Example: ... 7 0.30 0 0.1 500   ->  rtt=300ms ... solved=500/500 avg=0.987s
local seed, rtt, drop_p, extra_p, n_boards = tonumber(arg[1]), tonumber(arg[2]), tonumber(arg[3]), tonumber(arg[4]), tonumber(arg[5])
math.randomseed(seed)
local STEP = 1/30
local BW, BH, CW, CH = 6, 4, 2, 2
local now = 100
function Vector3(x, y, z) return { x = x, y = y, z = z or 0 } end
table.clear = function(t) for k in pairs(t) do t[k] = nil end end
math.clamp = function(v, a, b) return math.max(a, math.min(b, v)) end
local Settings = { game_states = { gameplay = "gameplay", transition = "transition" }, types = { decode_search = "decode_search" },
  decode_search_board_width = BW, decode_search_board_height = BH, decode_search_cursor_width = CW, decode_search_cursor_height = CH }
local real_require = require
function require(p)
  if p:find("minigame_settings") then return Settings end
  if p:find("search_settings") then return { symbol_widget_size = {1,1} } end
  if p:find("ui_widget") then return {} end
  return real_require(p)
end
local hooks, regs = {}, {}
local mod = { _exp = { timer = 0 }, _exp_move_cooldown = 0, _exp_startup_delay = 0, _exp_press_until = 0, _exp_release_until = 0, _exp_submitted_until = 0 }
function mod:hook_safe(c, m, f) hooks[c .. "." .. m] = f end
function mod:hook(c, m, f) hooks[c .. "." .. m] = f end
function mod:hook_require() end
function mod._reg(ev, cb) regs[ev] = regs[ev] or {}; table.insert(regs[ev], cb) end
mod._S = function(k) return k == "enable_expedition_auto_solve" or k == "enable_matching" end
mod._time = function() return now end
local PACING = tonumber(arg[6] or "0"); mod._speed_pacing = function() return PACING end
mod._is_local_minigame_player = function() return true end
function get_mod() return mod end
Managers = { ui = { view_active = function() return true end }, connection = { host = function() return "host" end } }
Network = { ping = function() return rtt end }
Unit = { alive = function() return true end }
dofile(os.getenv("NB_SEARCH_MODULE") or "scripts/mods/NoBrainer/NoBrainer_minigame_decode_search.lua")

-- board
local function make_mg()
  local sym = {}
  for i = 1, BW * BH do sym[i] = math.random(1, 6) end
  local function window(x, y) return { sym[(y-1)*BW + x], sym[(y-1)*BW + x + 1], sym[y*BW + x], sym[y*BW + x + 1] } end
  local tx, ty = math.random(1, BW-CW+1), math.random(1, BH-CH+1)
  local mg = { _is_server = (arg[7] == "host"), _decode_targets = { window(tx, ty) }, _minigame_unit = {},
    server = { x = math.random(1, BW-CW+1), y = math.random(1, BH-CH+1), last_move = 0 } }
  mg.client = { x = mg.server.x, y = mg.server.y }
  function mg:cursor_position() return { x = self.client.x, y = self.client.y } end
  function mg:current_stage() return 1 end
  function mg:is_completed() return false end
  function mg:state() return "gameplay" end
  function mg.get_symbols_for_target(self, x, y) return window(x, y) end
  function mg:matches(x, y) local w, t = window(x, y), self._decode_targets[1]; for i=1,4 do if w[i] ~= t[i] then return false end end return true end
  return mg
end

local function on_axis_set(s, t, x, y) -- native 1.13.0 server logic
  y = -y
  local ax, ay = math.abs(x), math.abs(y)
  if ax < 0.5 and ay < 0.5 then s.last_move = 0
  elseif t > s.last_move + 0.25 then
    s.last_move = t
    if ax >= 0.5 then if x < 0 then if s.x > 1 then s.x = s.x - 1 end elseif s.x < BW-CW+1 then s.x = s.x + 1 end end
    if ay >= 0.5 then if y < 0 then if s.y > 1 then s.y = s.y - 1 end elseif s.y < BH-CH+1 then s.y = s.y + 1 end end
  end
end

local stats = { boards = 0, solved = 0, time = 0, max_time = 0, faults = 0 }
for b = 1, n_boards do
  local mg = make_mg()
  hooks["MinigameDecodeSearch.start"](mg, {})
  local lat = rtt / 2
  local up, down = {}, {}   -- queues of {at, ...}
  local frame, start = 0, now
  local done_at
  for k = 1, 30 * 20 do
    frame = frame + 1
    now = now + STEP
    for _, cb in ipairs(regs.update or {}) do cb(STEP) end
    -- deliver cursor RPCs to client
    while down[1] and down[1].at <= now do local m = table.remove(down, 1); mg.client.x, mg.client.y = m.x, m.y end
    -- client serializes a fixed frame
    local l = mod._exp_move_input("move_left", frame) or 0
    local r = mod._exp_move_input("move_right", frame) or 0
    local f = mod._exp_move_input("move_forward", frame) or 0
    local bk = mod._exp_move_input("move_backward", frame) or 0
    local ix, iy = r - l, f - bk
    if (ix ~= 0 or iy ~= 0) and math.random() < drop_p then ix, iy = 0, 0; stats.faults = stats.faults + 1 end
    up[#up+1] = { at = now + lat, x = ix, y = iy }
    -- server consumes inputs
    while up[1] and up[1].at <= now do
      local m = table.remove(up, 1)
      local s = mg.server
      local ox, oy = s.x, s.y
      on_axis_set(s, m.at, m.x, m.y)
      if (m.x ~= 0 or m.y ~= 0) and math.random() < extra_p then -- spurious extra step (overshoot)
        s.last_move = 0; on_axis_set(s, m.at + 0.001, m.x, m.y); stats.faults = stats.faults + 1
      end
      if s.x ~= ox or s.y ~= oy then down[#down+1] = { at = now + lat, x = s.x, y = s.y } end
    end
    local busy = mod._exp_pending_moves[1] ~= nil
    if not busy and mg.client.x == mg.server.x and mg.client.y == mg.server.y and mg:matches(mg.server.x, mg.server.y) and #down == 0 then
      -- hold still a few frames to prove it stays
      done_at = done_at or now
      if now - done_at > 0.5 then break end
    else
      done_at = nil
    end
  end
  stats.boards = stats.boards + 1
  if done_at then
    stats.solved = stats.solved + 1
    local dt = done_at - start
    stats.time = stats.time + dt; stats.max_time = math.max(stats.max_time, dt)
  end
  hooks["MinigameDecodeSearch.complete"](mg)
  now = now + 1
end
print(string.format("rtt=%.0fms drop=%.2f extra=%.2f solved=%d/%d avg=%.3fs max=%.3fs faults=%d", rtt*1000, drop_p, extra_p, stats.solved, stats.boards, stats.time/math.max(stats.solved,1), stats.max_time, stats.faults))
