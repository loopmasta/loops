-- loops v0.0.1 by loopmasta
-- phasing loops, after Eno
--
-- each voice repeats a note
-- on its own loop length
--
-- K3 play / stop, K2 new loops
-- E2 voices, E3 space

engine.name = 'Loops'

local MAX_VOICES = 8
local NOTE_NAMES = {"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"}
local SCALES = {
  {name = "major pent", iv = {0, 2, 4, 7, 9}},
  {name = "lydian", iv = {0, 2, 4, 6, 7, 9, 11}},
  {name = "major", iv = {0, 2, 4, 5, 7, 9, 11}},
  {name = "dorian", iv = {0, 2, 3, 5, 7, 9, 10}},
  {name = "minor pent", iv = {0, 3, 5, 7, 10}},
}
local LOW, HIGH = 53, 81 -- the notes' register: F3 .. A5
local FLASH = 1.5        -- seconds a circle stays lit after its note
local VELOCITY = 0.5     -- the notes' middle level (the dynamics spread around it)

local voices = {}        -- {notes = {...}, len = s, offset = s, vel = 0..1, started, last}
local running = false
local clocks = {}
local message, message_until = nil, 0
local redraw_metro

-- random numbers from a seed (the same seed gives the same loops)
local function rng(seed)
  local s = (math.floor(seed) * 7919 + 104729) % 2147483646 + 1
  local r = {}
  function r.f() s = (s * 16807) % 2147483647; return (s - 1) / 2147483646 end
  for _ = 1, 12 do r.f() end
  function r.int(a, b) return a + math.floor(r.f() * (b - a + 1)) end
  return r
end

local function show(text) message, message_until = text, util.time() + 2 end

-- the scale's notes in the register
local function scale_notes()
  local root = params:get("root") - 1
  local iv = SCALES[params:get("scale")].iv
  local t = {}
  for n = LOW, HIGH do
    for _, i in ipairs(iv) do
      if (n - root) % 12 == i then t[#t + 1] = n end
    end
  end
  return t
end

-- loop lengths that don't line up: none within a second of another, none close
-- to a simple multiple of another
local function good_length(len, taken)
  for _, l in ipairs(taken) do
    if math.abs(len - l) < 1 then return false end
    local ratio = math.max(len, l) / math.min(len, l)
    if math.abs(ratio - math.floor(ratio + 0.5)) < 0.06 then return false end
  end
  return true
end

-- a new set of loops: for each voice a note (sometimes two), a length, an offset
local function new_loops()
  local r = rng(params:get("seed"))
  local notes = scale_notes()
  local taken = {}
  voices = {}
  for i = 1, MAX_VOICES do
    local len
    repeat len = math.floor((15 + r.f() * 20) * 10) / 10 until good_length(len, taken)
    taken[#taken + 1] = len
    local k = r.int(1, #notes)
    local v = {notes = {notes[k]}, len = len, offset = r.f() * 8, vel = 0.35 + r.f() * 0.25}
    if r.f() < 0.3 then
      -- now and then a second note: a step or two above or below, a moment later
      local j = util.clamp(k + ({-2, -1, 1, 2})[r.int(1, 4)], 1, #notes)
      v.notes[2] = notes[j]
      v.gap = 0.4 + r.f() * 0.8
    end
    v.pan = (r.f() - 0.5) * 1.2
    -- its own slow swell: a period of 40-90 s, a random phase
    v.swell_period = 40 + r.f() * 50
    v.swell_phase = r.f() * 2 * math.pi
    voices[i] = v
  end
end

-- the level of a note: the voice's own level, its slow swell (40-90 s), the
-- whole piece breathing (about 2 minutes) and a little variation every time,
-- together a factor around 1. `dynamics` scales how far it strays from 1
-- (0 = every note the same, 1 = as is, 2 = exaggerated) around VELOCITY. with the sampled Rhodes the level also sets the timbre (soft = warm,
-- loud = bark)
local function dynamics(v)
  local t = util.time()
  local voice = v.vel / 0.475 -- the voice's level, around 1
  local own = 0.75 + 0.25 * math.sin(2 * math.pi * t / v.swell_period + v.swell_phase)
  local piece = 0.85 + 0.2 * math.sin(2 * math.pi * t / 127)
  local each = 0.85 + 0.3 * math.random()
  local f = voice * own * piece * each / 0.75 -- around 1
  local range = params:get("dynamics")
  return util.clamp(VELOCITY * (1 + (f - 1) * range), 0.05, 1)
end

local function play_voice(v)
  local vel = dynamics(v)
  engine.note(v.notes[1], vel, v.pan, 0, 0) -- 0: the note rings out fully
  v.last = util.time()
  if v.notes[2] then
    clock.run(function()
      clock.sleep(v.gap)
      engine.note(v.notes[2], vel * (0.75 + 0.2 * math.random()), v.pan, 0, 0)
    end)
  end
end

local function stop()
  for _, c in ipairs(clocks) do clock.cancel(c) end
  clocks = {}
  running = false
end

local function start()
  stop()
  running = true
  for i, v in ipairs(voices) do
    v.started = util.time() + v.offset
    v.last = nil
    clocks[#clocks + 1] = clock.run(function()
      clock.sleep(v.offset)
      while true do
        if i <= params:get("voices") then play_voice(v) end
        clock.sleep(v.len)
      end
    end)
  end
end

local function renew()
  local was = running
  stop()
  new_loops()
  if was then start() end
end

-- params ------------------------------------------------------------------------

local function add_params()
  params:add_separator("loops", "loops")
  params:add_option("root", "key", NOTE_NAMES, 6) -- F
  params:set_action("root", function() renew() end)
  local names = {}
  for i, s in ipairs(SCALES) do names[i] = s.name end
  params:add_option("scale", "scale", names, 1)
  params:set_action("scale", function() renew() end)
  params:add_number("voices", "voices", 1, MAX_VOICES, 6)
  params:add_number("seed", "seed", 1, 9999, 1)
  params:set_action("seed", function() renew() end)
  params:add_control("vibrato", "vibrato", controlspec.new(0, 1, "lin", 0, 0.5, ""))
  params:set_action("vibrato", function(x) engine.vibrato(x) end)
  params:add_control("vibrato_rate", "vibrato rate", controlspec.new(1, 10, "exp", 0, 2.5, "Hz"))
  params:set_action("vibrato_rate", function(x) engine.vibrato_rate(x) end)
  params:add_control("dynamics", "dynamics", controlspec.new(0, 2, "lin", 0, 1, ""))
  params:add_control("tape", "tape", controlspec.new(0, 1, "lin", 0, 0.4, ""))
  params:set_action("tape", function(x) engine.tape(x) end)
  params:add_control("tape_time", "tape time", controlspec.new(0.1, 2.5, "exp", 0, 0.85, "s"))
  params:set_action("tape_time", function(x) engine.tape_time(x) end)
  params:add_control("tape_feedback", "tape feedback", controlspec.new(0, 0.95, "lin", 0, 0.6, ""))
  params:set_action("tape_feedback", function(x) engine.tape_feedback(x) end)
  params:add_control("tape_wear", "tape wear", controlspec.new(0, 1, "lin", 0, 0.5, ""))
  params:set_action("tape_wear", function(x) engine.tape_wear(x) end)
  params:add_control("space", "space", controlspec.new(0, 1, "lin", 0, 0.8, ""))
  params:set_action("space", function(x) engine.space(x) end)
end

-- norns ---------------------------------------------------------------------------

function init()
  add_params()
  params:bang()
  new_loops()
  -- call redraw through a function: norns swaps the global redraw while it loads
  redraw_metro = metro.init(function() redraw() end, 1 / 30)
  redraw_metro:start()
end

function key(n, z)
  if z == 0 then return end
  if n == 3 then
    if running then stop() else start() end
  elseif n == 2 then
    params:set("seed", params:get("seed") % 9999 + 1)
    show("loops #" .. params:get("seed"))
  end
end

function enc(n, d)
  if n == 2 then
    params:delta("voices", d)
    show(params:get("voices") .. " voices")
  elseif n == 3 then
    params:delta("space", d)
    show("space " .. math.floor(params:get("space") * 100 + 0.5) .. "%")
  end
end

-- screen ------------------------------------------------------------------------

local function circle(cx, cy, r)
  local x, y, d = r, 0, 1 - r
  while x >= y do
    for _, p in ipairs({{x, y}, {y, x}, {-y, x}, {-x, y}, {-x, -y}, {-y, -x}, {y, -x}, {x, -y}}) do
      screen.pixel(cx + p[1], cy + p[2])
    end
    y = y + 1
    if d < 0 then d = d + 2 * y + 1 else x = x - 1; d = d + 2 * (y - x) + 1 end
  end
  screen.fill()
end

local function note_name(n) return NOTE_NAMES[n % 12 + 1] .. (math.floor(n / 12) - 1) end

-- one circle per voice (4 x 2), a dot going round at the voice's speed; the
-- circle lights up when its note plays
function redraw()
  screen.clear()
  screen.font_face(1)
  screen.font_size(8)
  local now = util.time()
  for i, v in ipairs(voices) do
    local cx = ((i - 1) % 4) * 32 + 16
    local cy = (i <= 4) and 16 or 47
    local active = i <= params:get("voices")
    local lit = (v.last and (now - v.last) < FLASH) and (1 - (now - v.last) / FLASH) or 0
    screen.level(active and math.floor(3 + 12 * lit + 0.5) or 1)
    circle(cx, cy, 12)
    if active then
      screen.level(active and (lit > 0 and 15 or 5) or 1)
      screen.move(cx - math.floor(screen.text_extents(note_name(v.notes[1])) / 2), cy + 3)
      screen.text(note_name(v.notes[1]))
      if running and v.started and now >= v.started then
        local phase = ((now - v.started) % v.len) / v.len
        local a = phase * 2 * math.pi - math.pi / 2
        screen.level(12)
        screen.rect(math.floor(cx + math.cos(a) * 12) - 1, math.floor(cy + math.sin(a) * 12) - 1, 3, 3)
        screen.fill()
      end
    end
  end
  if message and now < message_until then
    local w = screen.text_extents(message)
    screen.level(0)
    screen.rect(64 - w / 2 - 4, 26, w + 8, 11)
    screen.fill()
    screen.level(15)
    screen.move(64 - math.floor(w / 2), 34)
    screen.text(message)
  end
  screen.update()
end

function cleanup()
  stop()
end
