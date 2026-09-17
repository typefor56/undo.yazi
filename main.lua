--- @since 26.0
--- undo.yazi: one key to undo the last file operation.
---
--- A journal and an inverter, nothing more. yazi broadcasts its own operations
--- over DDS, so `setup()` records them and `u` applies the inverse of the newest
--- record. Every operation it can undo is broadcast, including the copying
--- paste, so no key but `D` is ever wrapped.
---
--- The entry is deliberately NOT `--- @sync entry`: it needs `fs.*` and
--- `ya.confirm`, which are async only, and reaches `cx.*` through `ya.sync`
--- closures instead. See docs/findings.md item 1.

local M = {}

local MAX = 200 -- records kept in the journal

-- ---------------------------------------------------------------------------
-- Pure helpers. Nothing below here until "yazi glue" touches a yazi global, so
-- tests/check.lua can load this file with a plain lua interpreter.
-- ---------------------------------------------------------------------------

-- Paths are percent encoded in the journal. That is the same coding the trash
-- records use (findings item 7) and it keeps a tab or a newline in a filename
-- from breaking the line format.
local function enc(s)
	return (tostring(s):gsub("[^%w%-%./_~]", function(c) return string.format("%%%02X", c:byte()) end))
end

local function dec(s)
	return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function encode(action, paths, time)
	local out = { action, tostring(time) }
	for _, p in ipairs(paths) do
		out[#out + 1] = enc(p)
	end
	return table.concat(out, "\t")
end

local function decode(line)
	local f = {}
	for field in line:gmatch("[^\t]+") do
		f[#f + 1] = field
	end
	if #f < 3 then
		return nil
	end
	local paths = {}
	for i = 3, #f do
		paths[#paths + 1] = dec(f[i])
	end
	return { action = f[1], time = tonumber(f[2]) or 0, paths = paths }
end

-- Every record but `delete` stores from,to pairs: where it was, where it went.
local function twos(rec)
	local t = {}
	for i = 1, #rec.paths - 1, 2 do
		t[#t + 1] = { from = rec.paths[i], to = rec.paths[i + 1] }
	end
	return t
end

local function cap(lines)
	local n = #lines
	return n <= MAX and lines or table.move(lines, n - MAX + 1, n, 1, {})
end

local function tilde(p)
	local home = os.getenv("HOME")
	return home and p:sub(1, #home) == home and "~" .. p:sub(#home + 1) or p
end

local function dirname(p)
	return p:match("^(.*)/[^/]+$") or p
end

local function basename(p)
	return p:match("[^/]+$") or p
end

M.enc, M.dec, M.encode, M.decode, M.twos, M.cap, M.MAX = enc, dec, encode, decode, twos, cap, MAX

-- ---------------------------------------------------------------------------
-- Where things live
-- ---------------------------------------------------------------------------

local HOME = os.getenv("HOME") or ""
local STATE = (os.getenv("XDG_STATE_HOME") or HOME .. "/.local/state") .. "/yazi"
local LOG = STATE .. "/undo.log"
local PURGATORY = STATE .. "/undo-purgatory"
local CONFIG = os.getenv("YAZI_CONFIG_HOME") or (os.getenv("XDG_CONFIG_HOME") or HOME .. "/.config") .. "/yazi"
local SH = CONFIG .. "/plugins/undo.yazi/trash.sh"

-- ---------------------------------------------------------------------------
-- The journal on disk. `io` is available in both the sync and the async VM, so
-- the DDS recorders append directly rather than buffering.
-- ---------------------------------------------------------------------------

local function read_lines()
	local lines = {}
	local f = io.open(LOG, "r")
	if not f then
		return lines
	end
	for line in f:lines() do
		if line ~= "" then
			lines[#lines + 1] = line
		end
	end
	f:close()
	return lines
end

local function write_lines(lines)
	local f = io.open(LOG, "w")
	if not f then
		return false
	end
	lines = cap(lines)
	for _, l in ipairs(lines) do
		f:write(l, "\n")
	end
	f:close()
	return true
end

local function append(action, paths)
	local f = io.open(LOG, "a")
	if not f then
		return false
	end
	f:write(encode(action, paths, os.time()), "\n")
	f:close()
	return true
end

-- ---------------------------------------------------------------------------
-- yazi glue
-- ---------------------------------------------------------------------------

local set_opts = ya.sync(function(st, opts) st.opts = opts end)
local get_opts = ya.sync(function(st) return st.opts or {} end)

-- nil unless the current tab is inside trash://
local trash_selection = ya.sync(function()
	if not tostring(cx.active.current.cwd):find("^trash://") then
		return nil
	end
	local urls = {}
	for _, u in pairs(cx.active.selected) do
		urls[#urls + 1] = tostring(u)
	end
	if #urls == 0 then
		local h = cx.active.current.hovered
		if h then
			urls[1] = tostring(h.url)
		end
	end
	return urls
end)

local selection = ya.sync(function()
	local urls = {}
	for _, u in pairs(cx.active.selected) do
		urls[#urls + 1] = tostring(u)
	end
	if #urls == 0 then
		local h = cx.active.current.hovered
		if h then
			urls[1] = tostring(h.url)
		end
	end
	return urls
end)

local function notify(title, content, level)
	ya.notify { title = title, content = content, level = level or "info", timeout = 4 }
end

local function done(action, content) notify("undo [action: " .. action .. "]", content, "info") end
local function refuse(action, content) notify("undo [action: " .. action .. "]", content, "warn") end
local function cancel(action, content) notify("cancel [action: " .. action .. "]", content, "warn") end

-- Runs trash.sh. Returns the trimmed stdout, or nil plus the reason it refused.
local function sh(args)
	local out, err = Command("bash"):arg(SH):arg(args):stdout(Command.PIPED):stderr(Command.PIPED):output()
	if not out then
		return nil, "cannot run trash.sh: " .. tostring(err)
	end
	local trim = function(s) return (s or ""):gsub("%s+$", "") end
	if not out.status.success then
		local why = trim(out.stderr)
		return nil, why ~= "" and why or "trash.sh failed"
	end
	return trim(out.stdout)
end

-- ---------------------------------------------------------------------------
-- The inverters
-- ---------------------------------------------------------------------------

-- delete: the paths are where the files were when they were trashed
local function undo_delete(rec)
	local args = { "restore" }
	for _, p in ipairs(rec.paths) do
		args[#args + 1] = p
	end
	local n, err = sh(args)
	if not n then
		return false, err
	end
	return true, string.format("%s restored to %s", n == "1" and "1 file" or n .. " files", tilde(dirname(rec.paths[1])))
end

-- cut, rename, bulk and purge all invert the same way: move `to` back to `from`
local function undo_move(rec)
	local args = { "move" }
	local pairs_ = twos(rec)
	for _, p in ipairs(pairs_) do
		args[#args + 1] = p.to
		args[#args + 1] = p.from
	end
	local n, err = sh(args)
	if not n then
		return false, err
	end
	if #pairs_ == 1 then
		return true, "moved back to " .. tilde(pairs_[1].from)
	end
	return true, string.format("%d items moved back to %s", #pairs_, tilde(dirname(pairs_[1].from)))
end

-- copy is the only undo that removes data, so it verifies, asks, and routes the
-- copies through the trash rather than unlinking them
local function undo_copy(rec)
	local pairs_ = twos(rec)
	for _, p in ipairs(pairs_) do
		local src = fs.cha(Url(p.from))
		local dst = fs.cha(Url(p.to))
		-- a copy carries its source's size and modification time, so the pair
		-- still matching is what says this really is the file the paste made
		if not dst then
			return false, "a copy is already gone: " .. tilde(p.to)
		elseif not src then
			return false, "the original is gone, so the copy is the only one left: " .. tilde(p.from)
		elseif not dst.is_dir and src.len ~= dst.len then
			return false, "no longer a copy of the original: " .. tilde(p.to)
		elseif src.mtime and dst.mtime and math.abs(src.mtime - dst.mtime) > 2 then
			return false, "changed since the paste: " .. tilde(p.to)
		end
	end

	local ok = ya.confirm {
		pos = { "center", w = 70, h = 10 },
		title = "Undo copy?",
		body = ui.Text(string.format(
			"%d copied item(s) in %s will be moved to the trash.\nThe originals are left alone.",
			#pairs_,
			tilde(dirname(pairs_[1].to))
		)),
	}
	if not ok then
		return nil, "nothing changed"
	end

	local args = { "trash" }
	for _, p in ipairs(pairs_) do
		args[#args + 1] = p.to
	end
	local n, err = sh(args)
	if not n then
		return false, err
	end
	return true, string.format("%s copies moved to the trash", n)
end

local INVERT = {
	delete = undo_delete,
	cut = undo_move,
	rename = undo_move,
	bulk = undo_move,
	purge = undo_move,
	copy = undo_copy,
}

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------

-- inside trash://, `u` restores what is hovered or selected instead of
-- consulting the journal. Restoring always goes through the trash API, never
-- through yank and paste, findings item 5.
local function restore_hovered(urls)
	if #urls == 0 then
		return refuse("delete", "Nothing hovered")
	end
	local args = { "pub", "trash-restore", "--list" }
	for _, u in ipairs(urls) do
		args[#args + 1] = u
	end
	local out, err = Command("ya"):arg(args):stderr(Command.PIPED):output()
	if not out or not out.status.success then
		return notify("undo [action: delete]", "ya pub failed: " .. tostring(out and out.stderr or err), "error")
	end
	done("delete", string.format("%d item(s) restored", #urls))
	ya.emit("refresh", {})
end

function M.undo()
	local lines = read_lines()
	local rec
	while #lines > 0 do
		rec = decode(lines[#lines])
		if rec and INVERT[rec.action] then
			break
		end
		table.remove(lines) -- a line we cannot read is not worth keeping
		rec = nil
	end
	if not rec then
		write_lines(lines)
		return notify("undo [action: none]", "Nothing to undo", "warn")
	end

	local ok, msg = INVERT[rec.action](rec)
	if ok == nil then
		return cancel(rec.action, msg) -- the user declined the prompt
	elseif not ok then
		return refuse(rec.action, msg) -- refused, and nothing was touched
	end

	table.remove(lines)
	write_lines(lines)
	done(rec.action, msg)
	ya.emit("refresh", {})
end

-- `D` wrapper. Without `purgatory = true` it is a plain permanent delete, so
-- binding it changes nothing until the option is on.
function M.purge(args)
	local opts = get_opts()
	if not opts.purgatory then
		return ya.emit("remove", { permanently = true, force = args.force, hovered = args.hovered })
	end

	local sel = selection()
	if #sel == 0 then
		return refuse("purge", "Nothing selected")
	end

	local stamp = os.time()
	local paths, move = {}, { "move" }
	for i, p in ipairs(sel) do
		local staged = string.format("%s/%d-%d-%s", PURGATORY, stamp, i, basename(p))
		paths[#paths + 1] = p
		paths[#paths + 1] = staged
		move[#move + 1] = p
		move[#move + 1] = staged
	end

	local n, err = sh(move)
	if not n then
		return notify("undo [action: purge]", err, "error")
	end
	append("purge", paths)
	sh { "prune", PURGATORY, tostring(opts.purgatory_max_days or 30), tostring(opts.purgatory_max_gb or 1) }
	notify("staged [action: purge]", string.format("%s item(s) held in the purgatory, `u` brings them back", n), "info")
	ya.emit("refresh", {})
end

-- README troubleshooting: an orphaned .trashinfo hangs the trash listing
-- forever, findings item 6
function M.clean_trash()
	local n, err = sh { "orphans" }
	if not n then
		return notify("undo [action: clean-trash]", err, "error")
	end
	notify("undo [action: clean-trash]", n .. " orphaned record(s) parked in Trash/orphaned-info", "info")
end

function M:setup(opts)
	opts = opts or {}
	set_opts(opts)
	os.execute("mkdir -p '" .. STATE:gsub("'", "'\\''") .. "'")
	write_lines(read_lines()) -- apply the cap once per start

	ps.sub("trash", function(body)
		local paths = {}
		for _, u in pairs(body.urls or {}) do
			paths[#paths + 1] = tostring(u)
		end
		if #paths > 0 then
			append("delete", paths)
		end
	end)

	ps.sub("move", function(body)
		local paths = {}
		for _, it in pairs(body.items or {}) do
			paths[#paths + 1] = tostring(it.from)
			paths[#paths + 1] = tostring(it.to)
		end
		if #paths > 0 then
			append("cut", paths)
		end
	end)

	ps.sub("rename", function(body)
		if body.from and body.to then
			append("rename", { tostring(body.from), tostring(body.to) })
		end
	end)

	-- the kind is `bulk-rename`, not `bulk`: docs/findings.md item 11
	ps.sub("bulk-rename", function(body)
		local paths = {}
		for from, to in pairs(body) do
			paths[#paths + 1] = tostring(from)
			paths[#paths + 1] = tostring(to)
		end
		if #paths > 0 then
			append("bulk", paths)
		end
	end)

	-- a copying paste lands here, with the names yazi actually created:
	-- docs/findings.md item 12
	ps.sub("duplicate", function(body)
		if opts.copy_undo == false then
			return
		end
		local paths = {}
		for _, it in pairs(body.items or {}) do
			paths[#paths + 1] = tostring(it.from)
			paths[#paths + 1] = tostring(it.to)
		end
		if #paths > 0 then
			append("copy", paths)
		end
	end)
end

function M:entry(job)
	local args = job.args or {}
	if args[1] == "purge" then
		return M.purge(args)
	elseif args[1] == "clean-trash" then
		return M.clean_trash()
	end

	local urls = trash_selection()
	if urls then
		return restore_hovered(urls)
	end
	return M.undo()
end

return M
