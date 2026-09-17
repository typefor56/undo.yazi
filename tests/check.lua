-- The one runnable check: the journal codec and the record inverter, the two
-- pieces that are wrong silently. Run it with `lua5.4 tests/check.lua`.
--
-- main.lua calls ya.sync at load time and nothing else, so a two line stand-in
-- for `ya` is enough to load it outside yazi.
_G.ya = { sync = function(f) return f end }
_G.ps = { sub = function() end }

local here = (arg[0]:match("^(.*)/") or ".")
local M = assert(loadfile(here .. "/../main.lua"))()

-- the codec survives what a filename can actually contain
for _, name in ipairs {
	"/home/u/plain.txt",
	"/home/u/mon fichier é.txt",
	"/home/u/tab\there.txt",
	"/home/u/new\nline.txt",
	"/home/u/100% sûr & done.txt",
	"/home/u/🙂.txt",
} do
	local round = M.dec(M.enc(name))
	assert(round == name, "codec lost " .. name .. " -> " .. round)
	assert(not M.enc(name):find("[\t\n]"), "encoded form still holds a separator: " .. name)
end

-- a record survives encode then decode, separators and all
local paths = { "/a/mon fichier é.txt", "/b/tab\there.txt" }
local line = M.encode("cut", paths, 1700000000)
assert(not line:find("\n"), "a record must be one line")
local rec = M.decode(line)
assert(rec.action == "cut" and rec.time == 1700000000, "header lost")
assert(rec.paths[1] == paths[1] and rec.paths[2] == paths[2], "paths lost")

-- garbage is rejected rather than half read
assert(M.decode("nonsense") == nil, "a short line must not decode")

-- from,to pairing, which every inverter but delete depends on
local two = M.twos { paths = { "/from/1", "/to/1", "/from/2", "/to/2" } }
assert(#two == 2, "expected 2 pairs, got " .. #two)
assert(two[1].from == "/from/1" and two[1].to == "/to/1", "pair 1 is crossed")
assert(two[2].from == "/from/2" and two[2].to == "/to/2", "pair 2 is crossed")
-- an odd trailing path is dropped, never paired with nil
assert(#M.twos { paths = { "/a", "/b", "/orphan" } } == 1, "an unpaired path must be dropped")

-- the cap keeps the newest records, not the oldest
local lines = {}
for i = 1, M.MAX + 5 do
	lines[i] = tostring(i)
end
local kept = M.cap(lines)
assert(#kept == M.MAX, "cap kept " .. #kept)
assert(kept[#kept] == tostring(M.MAX + 5), "cap dropped the newest record")
assert(kept[1] == "6", "cap kept the wrong window, starts at " .. kept[1])
assert(#M.cap { "a", "b" } == 2, "a short journal must pass through untouched")

print("ok")
