local state = require("editr.state")
local util = require("editr.util")
local context = require("editr.context")
local paths = require("editr.paths")

local M = {}

function M.remote_available(kind)
	if kind == "canola" and state.config.integrations.canola then
		return pcall(require, "canola")
	end
	if kind == "oil" and state.config.integrations.oil then
		return pcall(require, "oil")
	end
	return false
end

function M.remote_buffer_available()
	return M.remote_available("canola") or M.remote_available("oil")
end

local function open_command(opts)
	opts = opts or {}
	if opts.open_cmd then
		return opts.open_cmd
	end
	if opts.cmd then
		return opts.cmd
	end
	if opts.vertical then
		return "vsplit"
	end
	if opts.horizontal then
		return "split"
	end
	return "edit"
end

function M.open_path(path, opts)
	opts = opts or {}
	if opts.win and vim.api.nvim_win_is_valid(opts.win) then
		pcall(vim.api.nvim_set_current_win, opts.win)
	end
	vim.cmd(open_command(opts) .. " " .. vim.fn.fnameescape(path))
end

function M.open_remote_buffer(remote_path, opts)
	if M.remote_available("canola") then
		M.open_path(paths.canola_url(remote_path), opts)
		return true
	end
	if M.remote_available("oil") then
		M.open_path(paths.oil_url(remote_path), opts)
		return true
	end
	util.notify("canola/oil is not available for remote buffer fallback", vim.log.levels.WARN)
	return false
end

function M.open_local_file(path, pos, opts)
	M.open_path(path, opts)
	if pos and pos[1] then
		pcall(vim.api.nvim_win_set_cursor, 0, { pos[1], pos[2] or 0 })
		vim.cmd("normal! zzzv")
	end
end

local function hydrate_args(remote_path, opts)
	opts = opts or {}
	local args = {
		state.config.editr_bin,
		"hydrate",
		"--context",
		state.context.context_file,
		"--remote-path",
		remote_path,
		"--mode",
		opts.mode or state.config.hydration_mode,
		"--max-size",
		state.config.max_auto_hydrate_size,
		"--owner-pid",
		tostring(vim.uv.os_getpid()),
		"--json",
	}
	if opts.check then
		args[#args + 1] = "--check"
	end
	if opts.allow_large then
		args[#args + 1] = "--allow-large"
	end
	if opts.allow_existing then
		args[#args + 1] = "--allow-existing"
	end
	return args
end

local function hydrate(remote_path, opts, callback)
	util.system_async(hydrate_args(remote_path, opts), function(code, stdout, stderr)
		if code ~= 0 then
			util.notify(vim.trim(stderr ~= "" and stderr or stdout), vim.log.levels.ERROR)
			callback(nil)
			return
		end
		local ok, decoded = pcall(util.parse_json, stdout)
		if not ok then
			util.notify("editr hydrate returned invalid JSON", vim.log.levels.ERROR)
			callback(nil)
			return
		end
		callback(decoded)
	end)
end

local function remember_hydration(bufnr, session_name)
	if not session_name or session_name == "" then
		return
	end
	state.hydrated_buffers[bufnr] = session_name
	vim.b[bufnr].editr_hydration_session = session_name
end

local function hydrate_and_open(remote_path, opts)
	opts = opts or {}
	hydrate(remote_path, { allow_large = opts.allow_large, allow_existing = true }, function(result)
		if not result then
			return
		end
		M.open_local_file(result.local_path, opts.pos, opts)
		remember_hydration(vim.api.nvim_get_current_buf(), result.session_name)
	end)
end

local function prompt_hydration(remote_path, check, opts)
	opts = opts or {}
	local choices = {
		("Hydrate into mirror (%s)"):format(util.human_size(check.size_bytes)),
	}
	if opts.existing_local_path then
		choices[#choices + 1] = "Open existing mirror copy"
	end
	if M.remote_buffer_available() then
		choices[#choices + 1] = "Open remote buffer"
	end
	choices[#choices + 1] = "Cancel"

	vim.ui.select(choices, {
		prompt = "Open " .. remote_path,
	}, function(choice)
		if not choice or choice == "Cancel" then
			return
		end
		if choice == "Open existing mirror copy" then
			M.open_local_file(opts.existing_local_path, opts.pos, opts)
			return
		end
		if choice:match("^Open remote") then
			M.open_remote_buffer(remote_path, opts)
			return
		end
		hydrate_and_open(remote_path, vim.tbl_extend("force", opts, { allow_large = true }))
	end)
end

function M.open_remote_path(remote_path, opts)
	if not context.ensure() then
		return false
	end
	opts = opts or {}
	remote_path = paths.infer_primary_remote_path(remote_path)
	local local_path = paths.local_path_for_remote(remote_path)
	local local_exists = local_path and vim.uv.fs_stat(local_path) ~= nil
	if local_exists and not opts.check_existing then
		M.open_local_file(local_path, opts.pos, opts)
		return true
	end
	hydrate(remote_path, { check = true }, function(check)
		if not check then
			return
		end
		local policy = opts.policy or state.config.remote_open_policy
		if policy == "remote" then
			M.open_remote_buffer(remote_path, opts)
		elseif policy == "hydrate" then
			hydrate_and_open(remote_path, vim.tbl_extend("force", opts, { allow_large = true }))
		elseif policy == "auto_under_limit" and not check.over_limit then
			util.notify(("Hydrating %s (%s)"):format(remote_path, util.human_size(check.size_bytes)))
			hydrate_and_open(remote_path, opts)
		else
			prompt_hydration(
				remote_path,
				check,
				vim.tbl_extend("force", opts, { existing_local_path = local_exists and local_path or nil })
			)
		end
	end)
	return true
end

local function stop_hydration(session_name)
	if not session_name or session_name == "" then
		return
	end
	util.system_async({ state.config.editr_bin, "stop", session_name }, function() end)
end

local function flush_hydration(session_name)
	if not session_name or session_name == "" then
		return
	end
	util.system_async({ state.config.editr_bin, "flush", session_name }, function() end)
end

function M.setup_autocmds()
	local group = vim.api.nvim_create_augroup("editr.nvim", { clear = true })
	vim.api.nvim_create_autocmd("BufWritePost", {
		group = group,
		callback = function(args)
			if state.config.flush_on_write then
				flush_hydration(state.hydrated_buffers[args.buf])
			end
		end,
	})
	vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
		group = group,
		callback = function(args)
			local session_name = state.hydrated_buffers[args.buf]
			state.hydrated_buffers[args.buf] = nil
			stop_hydration(session_name)
		end,
	})
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = group,
		callback = function()
			for _, session_name in pairs(state.hydrated_buffers) do
				stop_hydration(session_name)
			end
		end,
	})
end

return M
