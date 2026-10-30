-- loops v0.0.1 by loopmasta

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
local RING = 9.5         -- a duration from here on: the note rings out fully

-- the voices: notes (1 or 2), gap (s before the 2nd), len (s), offset (s), vel
-- (0..1), pan, duration (s), life (place in the lifespan range), seed (noise),
-- passes; while playing last (time of the last note), cur (this pass's length),
-- next (its time)
local voices = {}

-- what the controls set (not params: E1 lifespan, E2 voices, E3 variety, K2 a new seed)
local active_voices = 6  -- E2: how many voices play
local life = 0.33        -- E1: the lifespan range, 0 (1-10 passes) .. 1 (20-30); 0.33: about 12
local variety = 0        -- E3: how different the loops are (speed, duration, lifespan)
local seed = 1           -- K2: a new random one, a new set of loops

local rand               -- the set's random numbers (rebirths draw from them too)
local slot_speed = {}    -- each slot's speed factor for variety (kept over rebirths)
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

-- smooth noise (1D gradient noise, like Perlin's): -1..1, changing slowly and
-- organically as x moves; `seed` gives each loop its own curve
local function noise(x, seed)
  local function grad(i)
    local h = math.sin(i * 127.1 + seed * 311.7) * 43758.5453
    return (h - math.floor(h)) * 2 - 1
  end
  local i = math.floor(x)
  local f = x - i
  local fade = f * f * f * (f * (f * 6 - 15) + 10)
  local a, b = grad(i) * f, grad(i + 1) * (f - 1)
  return (a + (b - a) * fade) * 2
end

-- log-random between lo and hi (each step in between equally likely)
local function log_random(r, lo, hi)
  return math.exp(math.log(lo) + r.f() * (math.log(hi) - math.log(lo)))
end

-- a new loop: a note (sometimes two), a length that doesn't line up with the
-- others, a level, a duration, a lifespan, its own noise curves
local function make_voice(notes, taken)
  local r = rand
  local len
  repeat len = math.floor((15 + r.f() * 20) * 10) / 10 until good_length(len, taken)
  local k = r.int(1, #notes)
  local v = {notes = {notes[k]}, len = len, offset = r.f() * 8, vel = 0.35 + r.f() * 0.25}
  if r.f() < 0.3 then
    -- now and then a second note: a step or two above or below, a moment later
    local j = util.clamp(k + ({-2, -1, 1, 2})[r.int(1, 4)], 1, #notes)
    v.notes[2] = notes[j]
    v.gap = 0.4 + r.f() * 0.8
  end
  v.pan = (r.f() - 0.5) * 1.2
  v.duration = log_random(r, 0.4, 6)   -- its own duration, reached at full variety
  v.life = r.f()                       -- its place in the lifespan range (0 = shortest, 1 = longest)
  v.seed = r.f() * 1000                -- its noise curves
  v.passes = 0
  return v
end

-- the lengths of all voices but `skip`, so a new one doesn't line up with them
local function lengths(skip)
  local t = {}
  for i, v in ipairs(voices) do if i ~= skip then t[#t + 1] = v.len end end
  return t
end

-- a new set of loops
local function new_loops()
  rand = rng(seed)
  local notes = scale_notes()
  voices = {}
  for i = 1, MAX_VOICES do voices[i] = make_voice(notes, lengths()) end
  -- each slot's speed factor for `variety`: spread evenly (log scale, a little
  -- jitter) from 4x faster to 3x slower and shuffled, so at full variety the loops
  -- always range from fast to slow and no two are alike
  local lo, hi = math.log(0.25), math.log(3)
  for k = 1, MAX_VOICES do
    slot_speed[k] = math.exp(lo + (k - 1 + 0.2 + 0.6 * rand.f()) / MAX_VOICES * (hi - lo))
  end
  for k = MAX_VOICES, 2, -1 do
    local j = rand.int(1, k)
    slot_speed[k], slot_speed[j] = slot_speed[j], slot_speed[k]
  end
end

-- the level of a note: the voice's own level, its own slow drift (noise, about a
-- minute), the whole piece breathing (about 2 minutes) and a little variation
-- every time, together a factor around 1, times VELOCITY. with the sampled Rhodes
-- the level also sets the timbre (soft = warm, loud = bark)
local function dynamics(v)
  local t = util.time()
  local voice = v.vel / 0.475 -- the voice's level, around 1
  local own = 0.75 + 0.25 * noise(t / 45, v.seed)
  local piece = 0.85 + 0.2 * math.sin(2 * math.pi * t / 127)
  local each = 0.85 + 0.3 * math.random()
  return util.clamp(VELOCITY * voice * own * piece * each / 0.75, 0.05, 1)
end

-- how long a voice's notes sound: ringing out at variety 0, moving towards its own
-- duration as variety goes to 1 (0 = ring out)
local function duration(v)
  local d = 10 * (v.duration / 10) ^ variety
  return d >= RING and 0 or d
end

-- how many passes a voice lasts: `lifespan` (E1) sets the range, from 1-10
-- passes (0) to 20-30 (1); each voice has its place in it, spread out by variety
-- (0: all in the middle, 1: the whole range)
local function lifespan_range()
  local x = life
  return 1 + 19 * x, 10 + 20 * x
end

local function lifespan(v)
  local lo, hi = lifespan_range()
  local place = 0.5 + (v.life - 0.5) * variety
  return math.max(1, lo + place * (hi - lo))
end

-- a voice's loop length now: its length, moved towards its slot's speed factor
-- as variety goes to 1, drifting slowly (noise) more the higher the variety
local function length(i, v)
  local drift = 1 + 0.12 * variety * noise(util.time() / 60, v.seed + 7)
  return util.clamp(v.len * slot_speed[i] ^ variety * drift, 3, 90)
end

-- how much of a voice is left: 1 when new, fading to 0 over its lifespan
local function left(v) return math.max(0, 1 - v.passes / lifespan(v)) end

local function play_voice(v)
  local vel = dynamics(v)
  local gain = left(v)   -- fading out: quieter only, the timbre (velocity layer) stays
  engine.note(v.notes[1], vel, v.pan, duration(v), gain)
  v.last = util.time()
  if v.notes[2] then
    clock.run(function()
      clock.sleep(v.gap)
      -- not after a stop in the meantime
      if running then
        engine.note(v.notes[2], vel * (0.75 + 0.2 * math.random()), v.pan, duration(v), gain)
      end
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
  for i = 1, MAX_VOICES do
    voices[i].last, voices[i].next, voices[i].cur = nil, nil, nil
    clocks[#clocks + 1] = clock.run(function()
      clock.sleep(voices[i].offset)
      while true do
        local v = voices[i]
        if i <= active_voices then
          play_voice(v)
          -- disintegration: each pass a little quieter; gone, it's reborn with new values
          v.passes = v.passes + 1
          if left(v) <= 0 then
            voices[i] = make_voice(scale_notes(), lengths(i))
            v = voices[i]
          end
        end
        -- the length is read for every pass, so variety changes apply smoothly
        v.cur = length(i, v)
        v.next = util.time() + v.cur
        clock.sleep(v.cur)
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
  params:add_control("vibrato", "vibrato", controlspec.new(0, 1, "lin", 0, 0.5, ""))
  params:set_action("vibrato", function(x) engine.vibrato(x) end)
  params:add_control("vibrato_rate", "vibrato rate", controlspec.new(1, 10, "exp", 0, 2.5, "Hz"))
  params:set_action("vibrato_rate", function(x) engine.vibrato_rate(x) end)
  params:add_control("tape", "tape", controlspec.new(0, 1, "lin", 0, 0.4, ""))
  params:set_action("tape", function(x) engine.tape(x) end)
  params:add_control("tape_time", "tape time", controlspec.new(0.1, 2.5, "exp", 0, 0.85, "s"))
  params:set_action("tape_time", function(x) engine.tape_time(x) end)
  params:add_control("tape_feedback", "tape feedback", controlspec.new(0, 0.95, "lin", 0, 0.6, ""))
  params:set_action("tape_feedback", function(x) engine.tape_feedback(x) end)
  params:add_control("tape_wear", "tape wear", controlspec.new(0, 1, "lin", 0, 0.5, ""))
  params:set_action("tape_wear", function(x) engine.tape_wear(x) end)
end

-- norns ---------------------------------------------------------------------------

function init()
  math.randomseed(os.time())
  seed = math.random(1, 999999)
  add_params()
  params:bang() -- the key and scale actions make the first set of loops
  -- call redraw through a function: norns swaps the global redraw while it loads
  redraw_metro = metro.init(function() redraw() end, 1 / 30)
  redraw_metro:start()
end

function key(n, z)
  if z == 0 then return end
  if n == 3 then
    if running then stop(); show("stop") else start(); show("start") end
  elseif n == 2 then
    seed = math.random(1, 999999)
    renew()
    show("reset")
  end
end

function enc(n, d)
  if n == 1 then
    life = util.clamp(life + d / 100, 0, 1)
    local lo, hi = lifespan_range()
    show(string.format("lifespan %d-%d", math.floor(lo + 0.5), math.floor(hi + 0.5)))
  elseif n == 2 then
    active_voices = util.clamp(active_voices + d, 1, MAX_VOICES)
    show(active_voices .. " voices")
  elseif n == 3 then
    variety = util.clamp(variety + d / 100, 0, 1)
    show("variety " .. math.floor(variety * 100 + 0.5) .. "%")
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
    local active = i <= active_voices
    local lit = (v.last and (now - v.last) < FLASH) and (1 - (now - v.last) / FLASH) or 0
    -- disintegration on screen: the circle darkens as the voice fades; reborn,
    -- it's back at full brightness
    local fade = active and left(v) or 1
    local radius = 12
    screen.level(active and math.max(1, math.floor((3 + 12 * lit) * (0.15 + 0.85 * fade) + 0.5)) or 1)
    circle(cx, cy, radius)
    if active then
      screen.level(math.max(1, math.floor((lit > 0 and 15 or 5) * (0.15 + 0.85 * fade) + 0.5)))
      screen.move(cx - math.floor(screen.text_extents(note_name(v.notes[1])) / 2), cy + 3)
      screen.text(note_name(v.notes[1]))
      if running and v.next and v.cur then
        local phase = util.clamp(1 - (v.next - now) / v.cur, 0, 1)
        local a = phase * 2 * math.pi - math.pi / 2
        screen.level(math.max(2, math.floor(12 * (0.15 + 0.85 * fade) + 0.5)))
        screen.rect(math.floor(cx + math.cos(a) * radius) - 1, math.floor(cy + math.sin(a) * radius) - 1, 3, 3)
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
