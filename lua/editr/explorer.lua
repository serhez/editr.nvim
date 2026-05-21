local state = require("editr.state")
local util = require("editr.util")
local context = require("editr.context")
local paths = require("editr.paths")
local hydrate = require("editr.hydrate")

local M = {}

function M.explorer()
	if not context.ensure() then
		return false
	end
	if not hydrate.remote_available("canola") then
		util.notify("canola is not available", vim.log.levels.WARN)
		return false
	end
	local ok, canola = pcall(require, "canola")
	if ok and type(canola.open) == "function" then
		canola.open(paths.canola_url(state.context.remote_path))
	else
		vim.cmd.edit(vim.fn.fnameescape(paths.canola_url(state.context.remote_path)))
	end
	return true
end

function M.oil()
	if not context.ensure() then
		return false
	end
	if not hydrate.remote_available("oil") then
		util.notify("oil is not available", vim.log.levels.WARN)
		return false
	end
	vim.cmd.edit(vim.fn.fnameescape(paths.oil_url(state.context.remote_path)))
	return true
end

function M.canola_select(opts)
	if not context.ensure() then
		return false
	end
	opts = opts or {}
	local ok, canola = pcall(require, "canola")
	if not ok then
		return false
	end
	local entry = canola.get_cursor_entry()
	local url
	if type(canola.get_current_url) == "function" then
		url = canola.get_current_url(0)
	end
	if not url and type(canola.get_current_dir) == "function" then
		url = canola.get_current_dir()
	end
	if not entry or not url then
		return false
	end
	local host, path = paths.parse_remote_url(url)
	if not host or host ~= state.context.host then
		return false
	end
	local remote_path = paths.join_remote_path(path, entry.name)
	if not remote_path then
		return false
	end
	if opts.close and type(canola.close) == "function" then
		pcall(canola.close, { exit_if_last_buf = false })
	end
	if entry.type == "directory" then
		if type(canola.open) == "function" then
			canola.open(paths.canola_url(remote_path))
		else
			hydrate.open_path(paths.canola_url(remote_path), opts)
		end
	else
		hydrate.open_remote_path(
			remote_path,
			vim.tbl_extend("force", opts, { check_existing = opts.check_existing or paths.is_ignored_remote_path(remote_path) })
		)
	end
	return true
end

return M
