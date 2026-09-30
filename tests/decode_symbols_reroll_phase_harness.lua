-- Offline harness: NoBrainer Decode Symbols smart reroll, measured start phase vs uniform phase.
-- Loads the real NoBrainer_decode_symbols_reroll.lua twice: as shipped ("measured") and with
-- MEASURED_PHASE_MAX patched below zero so no phase is ever recorded ("uniform", the pre-3.1.7
-- valuation). Both drive the same client flow for identical boards:
--   start -> evaluate -> cancel_pending -> cancel input -> stop -> reinteract -> restart
--   -> predicted fast sync -> evaluate ...
-- Phases follow the 1.13.0 Flight-recorder measurement (2026-09-30, km_station, ~45 ms RTT):
-- first evaluation at 6-7 ticks of 52 Hz (0.115/0.135 s), predicted restarts at ~0 s.
-- Realized time = retry cost per reroll + board_cost of the accepted board at its real phase.
-- Run from the NoBrainer mod root:
--   ..\..\..\tools\luajit\luajit.exe tests\decode_symbols_reroll_phase_harness.lua [TRIALS] [SEED] [RETRY_S]
local TRIALS, SEED, RETRY = tonumber(arg[1] or "20000"), tonumber(arg[2] or "1"), tonumber(arg[3] or "0.22")
-- NB_RANDOM_PHASE=1 replays the 1.12.x behaviour (start phase uniform over the period) to check
-- that the measured-phase path falls back instead of acting on a stale phase.
local RANDOM_PHASE = os.getenv("NB_RANDOM_PHASE") == "1"
-- NB_COLD_START=1 reloads both modules before every trial: every terminal is the first one after
-- a game start, before any start phase has been measured.
local COLD_START = os.getenv("NB_COLD_START") == "1"
local MODULE = os.getenv("NB_REROLL_MODULE") or "scripts/mods/NoBrainer/NoBrainer_decode_symbols_reroll.lua"

-- Deterministic stand-in for the engine's math.next_random(seed, a[, b]).
math.next_random = function(seed, a, b)
  seed = (seed * 1103515245 + 12345) % 2147483648
  if b then return seed, a + seed % (b - a + 1) end
  return seed, 1 + seed % a
end
table.clear = function(t) for k in pairs(t) do t[k] = nil end end

local function server_board(seed) -- mirrors MinigameDecodeSymbols board generation used by the mod
  local symbols = {}
  for i = 1, 28 do symbols[i] = i end
  for i = 28, 2, -1 do local swap; seed, swap = math.next_random(seed, i); symbols[swap], symbols[i] = symbols[i], symbols[swap] end
  local targets, prev = {}, nil
  for s = 1, 4 do
    local t
    if prev then seed, t = math.next_random(seed, 1, 6); if prev <= t then t = t + 1 end
    else seed, t = math.next_random(seed, 1, 7) end
    targets[s], prev = t, t
  end
  return { symbols = symbols, targets = targets, post_seed = seed }
end

-- Copy of the module's board_cost (PRESS_LEAD 0.095, PRESS_GRACE 0.06, edge margin 0.03, client
-- startup_safe). Needed because an accepted reroll_limit board has no current_cost; every other
-- evaluation asserts that this copy matches the module's own value.
local function board_cost(targets, initial_ready)
  local sweep, period, margin, ready_delay = 2, 4, 2 / 6, 0.2
  local function next_periodic(at, phase) if at <= phase then return phase end return phase + math.ceil((at - phase) / period) * period end
  local ready_time, start_ready = initial_ready, initial_ready
  for stage = 1, #targets do
    local center = (targets[stage] - 1) * margin
    local press_time
    if stage == 1 then
      local phase = initial_ready % period
      local cursor = phase > sweep and period - phase or phase
      if margin * 0.5 - math.abs(cursor - center) >= 0.03 then press_time = ready_time end
    end
    if not press_time then
      local f, r = next_periodic(ready_time - 0.06, center), next_periodic(ready_time - 0.06, period - center)
      press_time = math.max(math.min(f, r) - 0.095, ready_time)
    end
    if stage == #targets then return press_time - start_ready end
    ready_time = press_time + ready_delay
  end
end

local source = assert(io.open(MODULE, "rb")):read("*a")
-- Engine stubs are globals shared by both loaded variants, so they share one terminal/player.
local terminal, player_unit = {}, {}
local function load_variant(uniform)
  local text = source
  if uniform then
    local patched, n = text:gsub("local MEASURED_PHASE_MAX = 0%.5", "local MEASURED_PHASE_MAX = -1")
    assert(n == 1, "MEASURED_PHASE_MAX not found")
    text = patched
  end
  local now, hooks, regs = 100, {}, {}
  local mod = {}
  function mod:hook(c, m, f) hooks[c .. "." .. m] = f end
  function mod:hook_safe() end
  function mod:hook_require() end
  function mod._reg(ev, cb) regs[ev] = regs[ev] or {}; regs[ev][#regs[ev] + 1] = cb end
  mod._S = function() return true end
  mod._time = function() return now end
  mod._ds_network_rtt = function() return 0.045 end
  mod._ds_stage_ready_delay = function() return 0.2 end
  _G.get_mod = function() return mod end
  _G.Unit = { alive = function() return true end }
  _G.Managers = { ui = { view_active = function() return false end },
    player = { local_player_safe = function() return { player_unit = player_unit } end } }
  _G.ScriptUnit = { has_extension = function(_, name)
    if name == "interactor_system" then
      return { is_interacting = function() return false end, target_unit = function() return terminal end,
        can_interact = function() return true end }
    end
    return { interaction_allowed = function() return true end }
  end }
  assert(loadstring(text, "=reroll"))()
  -- Register the extension's initial seed exactly as the MinigameSystem hooks do.
  local system, extension = {}, {}
  hooks["MinigameSystem.init"](function() end, system, nil, { level_seed = 5000 })
  hooks["MinigameSystem.on_add_extension"](function() return extension end, system)
  return {
    mod = mod, terminal = terminal, extension = extension,
    set_now = function(t) now = t end,
  }
end

local function run_trial(v, first_index, first_phase, fast_phase, offsets)
  local mod = v.mod
  local seed = 5000
  for _ = 1, first_index do seed = server_board(seed).post_seed end
  local mg = { _is_server = false, _stage_amount = 4, _decode_symbols_items_per_stage = 7,
    _decode_symbols_sweep_duration = 2, _current_stage = 1, _current_state = "gameplay",
    _minigame_unit = v.terminal, _minigame_extension = v.extension }
  local t, retries, previous_start, first_snap = 1000, 0, nil, nil
  local attempts_seen = 0
  v.set_now(t)
  mod._ds_reroll_start(mg)
  for attempt = 0, 3 do
    local board = server_board(seed)
    seed = board.post_seed
    mg._symbols, mg._decode_targets = board.symbols, board.targets
    -- 1.13.0: start == receipt, evaluated after a short sync delay. 1.12.x (NB_RANDOM_PHASE):
    -- same evaluation delay, but the start time itself is offset by a random part of the period.
    local delay = attempt == 0 and first_phase or fast_phase
    local offset = RANDOM_PHASE and offsets[attempt + 1] or 0
    mg._decode_start_time = t - offset
    local phase = delay + offset
    if attempt > 0 then
      mod._ds_reroll_predicted_sync_ready(mg, previous_start)
    end
    previous_start = mg._decode_start_time
    v.set_now(t + delay)
    local reroll = mod._ds_reroll_evaluate(mg, t + delay, true)
    local snap = mod._ds_reroll_snapshot()
    first_snap = first_snap or snap
    assert(snap.attempts == attempts_seen or snap.decision_reason == "reroll_limit", "reroll chain was reset")
    local cost = board_cost(board.targets, phase)
    if snap.current_cost then
      assert(math.abs(snap.current_cost - cost) < 1e-9, "board_cost copy drifted from module")
    end
    if not reroll then
      return retries * RETRY + cost, snap, first_snap
    end
    assert(snap.phase == "cancel_pending", snap.phase)
    retries = retries + 1
    attempts_seen = attempts_seen + 1
    mod._ds_reroll_input("action_two_pressed", false, "input_service")
    mod._ds_reroll_stop(mg, nil)
    mod._ds_reroll_input("interact_pressed", false, "input_service")
    t = t + delay + RETRY
    v.set_now(t)
    mod._ds_reroll_start(mg)
  end
  error("more rerolls than MAX_REROLLS")
end

local variants = { measured = load_variant(false), uniform = load_variant(true) }
local totals = { measured = 0, uniform = 0 }
local stats = { exact = 0, reroll_m = 0, reroll_u = 0, differs = 0, reconstructed = 0 }
math.randomseed(SEED)
for i = 1, TRIALS do
  local first_index = math.random(0, 40)
  local first_phase = math.random() < 0.5 and 6 / 52 or 7 / 52
  local fast_phase = math.random() * 0.006
  local offsets = { math.random() * 4, math.random() * 4, math.random() * 4, math.random() * 4 }
  if COLD_START then variants = { measured = load_variant(false), uniform = load_variant(true) } end
  local m, sm, fm = run_trial(variants.measured, first_index, first_phase, fast_phase, offsets)
  local u, su, fu = run_trial(variants.uniform, first_index, first_phase, fast_phase, offsets)
  -- The measured phase needs two in-bound evaluations, so only a warmed-up first decision uses it.
  assert(RANDOM_PHASE or COLD_START or i == 1 or fm.next_phase ~= nil, "measured variant did not use a measured phase")
  assert(fu.next_phase == nil, "uniform variant recorded a phase")
  if fm.seed_status == "reconstructed" then stats.reconstructed = stats.reconstructed + 1 end
  totals.measured, totals.uniform = totals.measured + m, totals.uniform + u
  if fm.decision_mode == "exact" then stats.exact = stats.exact + 1 end
  if m ~= u then stats.differs = stats.differs + 1 end
end
print(string.format("trials=%d retry=%.2fs  uniform=%.3fs  measured=%.3fs  saving=%.3fs/terminal  first decision exact=%.1f%% reconstructed=%.1f%%  outcome differs=%.1f%%",
  TRIALS, RETRY, totals.uniform / TRIALS, totals.measured / TRIALS, (totals.uniform - totals.measured) / TRIALS,
  100 * stats.exact / TRIALS, 100 * stats.reconstructed / TRIALS, 100 * stats.differs / TRIALS))
