--- REFERENCE ONLY, NOT THE IMPLEMENTATION.
--- The working prototype this plugin grows out of. Handles delete-to-trash only,
--- with no journal, so it cannot undo cut, copy or rename. Kept because the API
--- shapes here are proven to work: see docs/findings.md items 1 and 2.
---
--- @sync entry
--- `u` = undo the last delete.
---
--- Outside the trash it restores the most recently trashed entry to where it
--- was deleted from, so you never have to open trash:// to change your mind.
--- Inside trash:// it restores whatever is hovered/selected instead.
---
--- Note: cut+paste across trash:// silently yields a 0-byte file, so restoring
--- always goes through the trash API (or the freedesktop records) and never
--- through yank/paste.

local M = {}

local function notify(content, level)
	ya.notify { title = "Undo delete", content = content, level = level or "info", timeout = 4 }
end

local function in_trash()
	local cwd = cx.active.current.cwd
	return tostring(cwd):find("^trash://") ~= nil
end

-- inside trash://: hand the selected urls to the bundled trash plugin
local function restore_selected()
	local urls = {}
	for _, u in pairs(cx.active.selected) do urls[#urls + 1] = tostring(u) end
	if #urls == 0 then
		local h = cx.active.current.hovered
		if not h then return notify("Nothing hovered", "warn") end
		urls[1] = tostring(h.url)
	end

	local args = { "pub", "trash-restore", "--list" }
	for _, u in ipairs(urls) do args[#args + 1] = u end

	local out, err = Command("ya"):arg(args):output()
	if not out then return notify("ya pub failed: " .. tostring(err), "error") end
	notify(string.format("Restored %d item(s)", #urls))
	ya.emit("refresh", {})
end

-- anywhere else: pull the newest entry back out of the XDG trash
local function undo_last(n)
	local sh = os.getenv("HOME") .. "/.config/yazi/plugins/undo-delete.yazi/trash-undo.sh"
	local out, err = Command("bash"):arg({ sh, tostring(n) }):output()
	if not out then return notify("failed to run helper: " .. tostring(err), "error") end

	local msg = (out.stdout ~= "" and out.stdout or out.stderr):gsub("%s+$", "")
	if out.status.success then
		notify(msg)
		ya.emit("refresh", {})
	else
		notify(msg ~= "" and msg or "Nothing to restore", "warn")
	end
end

function M:entry(job)
	local n = tonumber(job.args and job.args[1]) or 1
	if in_trash() then restore_selected() else undo_last(n) end
end

return M
