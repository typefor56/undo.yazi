--- @since 26.0
--- undo.yazi: one key to undo the last file operation.
---
--- A journal and an inverter, nothing more. yazi broadcasts its own operations
--- over DDS, so `setup()` records them, `u` applies the inverse of the newest
--- record and `<C-r>` applies it again. Every operation it can undo is broadcast, including the copying
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

-- every directory above a path, nearest first, ending at the root. Used to find
-- the trash of the filesystem the path lives on.
local function ancestors(path)
	local list, p = {}, dirname(path)
	while true do
		list[#list + 1] = p == "" and "/" or p
		if p == "" or p == "/" then
			return list
		end
		p = dirname(p)
	end
end

M.enc, M.dec, M.encode, M.decode, M.twos, M.cap, M.MAX = enc, dec, encode, decode, twos, cap, MAX
M.ancestors = ancestors

-- ---------------------------------------------------------------------------
-- Where things live
-- ---------------------------------------------------------------------------

local HOME = os.getenv("HOME") or ""
local STATE = (os.getenv("XDG_STATE_HOME") or HOME .. "/.local/state") .. "/yazi"
local LOG = STATE .. "/undo.log"
local REDO = STATE .. "/undo-redo.log"
local PURGATORY = STATE .. "/undo-purgatory"
local TRASH = (os.getenv("XDG_DATA_HOME") or HOME .. "/.local/share") .. "/Trash"

-- ---------------------------------------------------------------------------
-- The journal on disk. `io` is available in both the sync and the async VM, so
-- the DDS recorders append directly rather than buffering.
--
-- Two files, the way an editor does it: LOG holds what `u` can still undo, REDO
-- holds what `u` has already undone and `<C-r>` can put back. A new operation
-- clears REDO, because there is no longer a future to return to.
-- ---------------------------------------------------------------------------

local function read_lines(path)
	local lines = {}
	local f = io.open(path, "r")
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

local function write_lines(path, lines)
	local f = io.open(path, "w")
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

local function push(path, line)
	local f = io.open(path, "a")
	if not f then
		return false
	end
	f:write(line, "\n")
	f:close()
	return true
end

-- what the DDS recorders call: a real operation, so the redo side is dropped
local function append(action, paths)
	write_lines(REDO, {})
	return push(LOG, encode(action, paths, os.time()))
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

local cwd = ya.sync(function() return tostring(cx.active.current.cwd) end)

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

-- ---------------------------------------------------------------------------
-- The trash, by hand. Lua can read and delete trash entries through `fs.trash`
-- but cannot create one, and a plugin package ships only its `.lua` files and
-- `assets/`, so a helper script is not an option: findings item 14. All of this
-- runs in the async entry, where `fs` exists.
-- ---------------------------------------------------------------------------

local function read_file(path)
	local f = io.open(path, "r")
	if not f then
		return nil
	end
	local body = f:read("a")
	f:close()
	return body
end

-- nothing at this path, not even a broken symlink
local function free(path)
	return fs.cha(Url(path)) == nil
end

-- rename(2) cannot cross filesystems and a trash or a purgatory can easily be
-- on another one, so `mv` is the fallback for exactly that case
local function move(from, to)
	if fs.rename(Url(from), Url(to)) then
		return true
	end
	local out = Command("mv"):arg({ "-n", "--", from, to }):stderr(Command.PIPED):output()
	return out ~= nil and out.status.success and free(from)
end

-- A file deleted from another filesystem does not go to the home trash. It goes
-- to that filesystem's own trash, at the top of the mount, findings item 16.
-- So `/tmp/x` on a tmpfs lands in `/tmp/.Trash-1000`, and looking only in
-- `~/.local/share/Trash` finds nothing at all.
local UID
local function uid()
	if not UID then
		UID = ya.uid and ya.uid() or (fs.cha(Url(HOME)) or {}).uid
	end
	return UID
end

-- the home trash, then every volume trash above `path`, nearest mount first.
-- `top` is the directory a relative `Path=` in that trash resolves against.
local function trashes_of(path)
	local found = { { dir = TRASH, top = "/" } }
	local u = uid()
	for _, anc in ipairs(u and ancestors(path) or {}) do
		local base = anc == "/" and "" or anc
		for _, dir in ipairs { base .. "/.Trash-" .. u, base .. "/.Trash/" .. u } do
			if fs.cha(Url(dir)) then
				found[#found + 1] = { dir = dir, top = anc }
			end
		end
	end
	return found
end

-- where a path should be trashed to: its own volume's trash when there is one,
-- otherwise the home trash, which costs a copy across the two filesystems
local function trash_for(path)
	local list = trashes_of(path)
	return list[2] or list[1]
end

-- newest record per original path, skipping the orphans whose file is gone
local function trash_index(dirs)
	local idx = {}
	for _, t in ipairs(dirs) do
		for _, f in ipairs(fs.read_dir(Url(t.dir .. "/info"), { resolve = true }) or {}) do
			local base = f.name:match("^(.*)%.trashinfo$")
			local src = base and t.dir .. "/files/" .. base
			if src and not free(src) then
				local orig
				for line in (read_file(tostring(f.url)) or ""):gmatch("[^\r\n]+") do
					orig = orig or line:match("^Path=(.*)$")
				end
				orig = orig and dec(orig)
				-- a volume trash may record a path relative to its own mount
				if orig and orig:sub(1, 1) ~= "/" then
					orig = (t.top == "/" and "" or t.top) .. "/" .. orig
				end
				local mtime = f.cha.mtime or 0
				if orig and (not idx[orig] or idx[orig].mtime < mtime) then
					idx[orig] = { info = tostring(f.url), src = src, mtime = mtime }
				end
			end
		end
	end
	return idx
end

-- put these exact paths back where their records say they came from
local function trash_restore(paths)
	local dirs, seen = {}, {}
	for _, path in ipairs(paths) do
		for _, t in ipairs(trashes_of(path)) do
			if not seen[t.dir] then
				seen[t.dir] = true
				dirs[#dirs + 1] = t
			end
		end
	end

	local idx = trash_index(dirs)
	local plan = {}
	for _, path in ipairs(paths) do
		if not idx[path] then
			return nil, "not in the trash: " .. tilde(path)
		elseif not free(path) then
			return nil, "occupied: " .. tilde(path)
		end
		plan[#plan + 1] = { e = idx[path], to = path }
	end

	for _, step in ipairs(plan) do
		fs.create("dir_all", Url(dirname(step.to)))
		if not move(step.e.src, step.to) then
			return nil, "could not move it back to " .. tilde(step.to)
		end
		fs.remove("file", Url(step.e.info))
	end
	return #plan
end

-- send paths to the trash, which is how undoing a copy stays undoable
local function trash_put(paths)
	for _, path in ipairs(paths) do
		if free(path) then
			return nil, "gone: " .. tilde(path)
		end
	end
	local stamp = os.date("%Y-%m-%dT%H:%M:%S")
	for _, path in ipairs(paths) do
		local dir = trash_for(path).dir
		fs.create("dir_all", Url(dir .. "/files"))
		fs.create("dir_all", Url(dir .. "/info"))

		local name, n = basename(path), 1
		while not (free(dir .. "/files/" .. name) and free(dir .. "/info/" .. name .. ".trashinfo")) do
			name, n = basename(path) .. "." .. n, n + 1
		end

		-- the record is written first and taken back if the move fails, because a
		-- record with no file beside it hangs yazi's trash listing forever,
		-- findings item 6
		local info = dir .. "/info/" .. name .. ".trashinfo"
		local body = string.format("[Trash Info]\nPath=%s\nDeletionDate=%s\n", enc(path), stamp)
		if not fs.write(Url(info), body) then
			return nil, "cannot write the trash record for " .. tilde(path)
		elseif not move(path, dir .. "/files/" .. name) then
			fs.remove("file", Url(info))
			return nil, "could not move it to the trash: " .. tilde(path)
		end
	end
	return #paths
end

-- park the records whose file is gone, findings item 6
local function trash_orphans(where)
	local n = 0
	for _, t in ipairs(trashes_of(where)) do
		local park = t.dir .. "/orphaned-info"
		for _, f in ipairs(fs.read_dir(Url(t.dir .. "/info"), { resolve = true }) or {}) do
			local base = f.name:match("^(.*)%.trashinfo$")
			if base and free(t.dir .. "/files/" .. base) then
				fs.create("dir_all", Url(park))
				if move(tostring(f.url), park .. "/" .. f.name) then
					n = n + 1
				end
			end
		end
	end
	return n
end

-- ---------------------------------------------------------------------------
-- The purgatory
-- ---------------------------------------------------------------------------

local function size_of(url, cha)
	cha = cha or fs.cha(url)
	if not cha then
		return 0
	elseif not cha.is_dir then
		return cha.len or 0
	end
	local total = 0
	for _, f in ipairs(fs.read_dir(url, { resolve = true }) or {}) do
		total = total + size_of(f.url, f.cha)
	end
	return total
end

-- oldest first, by age then by size, both limits off when not positive
local function prune(days, gb)
	local entries = fs.read_dir(Url(PURGATORY), { resolve = true })
	if not entries then
		return
	end

	local held, total = {}, 0
	for _, f in ipairs(entries) do
		local size = size_of(f.url, f.cha)
		held[#held + 1] = { url = f.url, mtime = f.cha.mtime or 0, is_dir = f.cha.is_dir, size = size }
		total = total + size
	end
	table.sort(held, function(a, b) return a.mtime < b.mtime end)

	local cutoff = days > 0 and os.time() - days * 86400 or -1
	local max = gb > 0 and gb * 1024 * 1024 * 1024 or math.huge
	for _, e in ipairs(held) do
		if e.mtime < cutoff or total > max then
			fs.remove(e.is_dir and "dir_all" or "file", e.url)
			total = total - e.size
		end
	end
end

-- ---------------------------------------------------------------------------
-- The inverters
-- ---------------------------------------------------------------------------

-- delete: the paths are where the files were when they were trashed
local function undo_delete(rec)
	local n, err = trash_restore(rec.paths)
	if not n then
		return false, err
	end
	return true, string.format("%s restored to %s", n == 1 and "1 file" or n .. " files", tilde(dirname(rec.paths[1])))
end

-- cut, rename, bulk and purge are all a pair of paths, so undoing and redoing
-- them is the same walk in opposite directions
local function move_pairs(pairs_, forward)
	local src, dst = forward and "from" or "to", forward and "to" or "from"
	for _, p in ipairs(pairs_) do
		if free(p[src]) then
			return false, "gone: " .. tilde(p[src])
		elseif not free(p[dst]) then
			return false, "occupied: " .. tilde(p[dst])
		end
	end
	for _, p in ipairs(pairs_) do
		fs.create("dir_all", Url(dirname(p[dst])))
		if not move(p[src], p[dst]) then
			return false, "could not move it to " .. tilde(p[dst])
		end
	end
	return true
end

local function undo_move(rec)
	local pairs_ = twos(rec)
	local ok, err = move_pairs(pairs_, false)
	if not ok then
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

	local targets = {}
	for _, p in ipairs(pairs_) do
		targets[#targets + 1] = p.to
	end
	local n, err = trash_put(targets)
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

-- Redoing is the record read the other way round. Nothing here asks, because
-- none of it destroys anything the trash does not already hold.

local function redo_delete(rec)
	local n, err = trash_put(rec.paths)
	if not n then
		return false, err
	end
	return true, string.format("%s back in the trash", n == 1 and "1 file" or n .. " files")
end

local function redo_move(rec)
	local pairs_ = twos(rec)
	local ok, err = move_pairs(pairs_, true)
	if not ok then
		return false, err
	end
	if #pairs_ == 1 then
		return true, "moved again to " .. tilde(pairs_[1].to)
	end
	return true, string.format("%d items moved again to %s", #pairs_, tilde(dirname(pairs_[1].to)))
end

-- undoing a copy trashed the copies, so redoing it pulls them back out
local function redo_copy(rec)
	local targets = {}
	for _, p in ipairs(twos(rec)) do
		targets[#targets + 1] = p.to
	end
	local n, err = trash_restore(targets)
	if not n then
		return false, err
	end
	return true, string.format("%d copies restored", n)
end

local REPLAY = {
	delete = redo_delete,
	cut = redo_move,
	rename = redo_move,
	bulk = redo_move,
	purge = redo_move,
	copy = redo_copy,
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

-- pop the newest record a table knows how to apply, dropping unreadable lines
local function newest(path, known)
	local lines = read_lines(path)
	while #lines > 0 do
		local line = lines[#lines]
		local rec = decode(line)
		if rec and known[rec.action] then
			return rec, line, lines
		end
		table.remove(lines) -- a line we cannot read is not worth keeping
	end
	return nil, nil, lines
end

function M.undo()
	local rec, line, lines = newest(LOG, INVERT)
	if not rec then
		write_lines(LOG, lines)
		return notify("undo [action: none]", "Nothing to undo", "warn")
	end

	local ok, msg = INVERT[rec.action](rec)
	if ok == nil then
		return cancel(rec.action, msg) -- the user declined the prompt
	elseif not ok then
		return refuse(rec.action, msg) -- refused, and nothing was touched
	end

	table.remove(lines)
	write_lines(LOG, lines)
	push(REDO, line)
	done(rec.action, msg)
	ya.emit("refresh", {})
end

function M.redo()
	local rec, line, lines = newest(REDO, REPLAY)
	if not rec then
		write_lines(REDO, lines)
		return notify("redo [action: none]", "Nothing to redo", "warn")
	end

	local ok, msg = REPLAY[rec.action](rec)
	if not ok then
		return notify("redo [action: " .. rec.action .. "]", msg, "warn")
	end

	table.remove(lines)
	write_lines(REDO, lines)
	push(LOG, line)
	notify("redo [action: " .. rec.action .. "]", msg, "info")
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

	fs.create("dir_all", Url(PURGATORY))
	local stamp, paths = os.time(), {}
	for i, p in ipairs(sel) do
		local staged = string.format("%s/%d-%d-%s", PURGATORY, stamp, i, basename(p))
		if not move(p, staged) then
			return notify("undo [action: purge]", "could not stage " .. tilde(p), "error")
		end
		paths[#paths + 1] = p
		paths[#paths + 1] = staged
	end

	append("purge", paths)
	prune(opts.purgatory_max_days or 30, opts.purgatory_max_gb or 1)
	notify(
		"staged [action: purge]",
		string.format("%d item(s) held in the purgatory, `u` brings them back", #sel),
		"info"
	)
	ya.emit("refresh", {})
end

-- README troubleshooting: an orphaned .trashinfo hangs the trash listing
-- forever, findings item 6
function M.clean_trash()
	local n, err = trash_orphans(cwd())
	if not n then
		return notify("undo [action: clean-trash]", err, "error")
	end
	notify("undo [action: clean-trash]", n .. " orphaned record(s) parked in Trash/orphaned-info", "info")
end

function M:setup(opts)
	opts = opts or {}
	set_opts(opts)
	os.execute("mkdir -p '" .. STATE:gsub("'", "'\\''") .. "'")
	write_lines(LOG, read_lines(LOG)) -- apply the cap once per start

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
	if args[1] == "redo" then
		return M.redo()
	elseif args[1] == "purge" then
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
