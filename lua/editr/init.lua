local M = {}

local defaults = {
	editr_bin = "editr",
	integrations = {
		canola = true,
		oil = true,
		snacks = true,
	},
	remote_open_policy = "auto_under_limit",
	max_auto_hydrate_size = "25 MB",
	hydration_mode = "live",
	flush_on_write = true,
	low_level_intercept = false,
	ssh_args = {},
}

local config = vim.deepcopy(defaults)
local context
local capabilities
local hydrated_buffers = {}

local MATCH_SEP = "@@EDITR_MATCH@@"

local function notify(message, level)
	vim.notify(message, level or vim.log.levels.INFO, { title = "editr" })
end

local function shellescape(value)
	return vim.fn.shellescape(tostring(value or ""))
end

local function shell_join(args)
	local quoted = {}
	for _, arg in ipairs(args) do
		quoted[#quoted + 1] = shellescape(arg)
	end
	return table.concat(quoted, " ")
end

local function normalize_remote_path(path)
	path = tostring(path or ""):gsub("/+", "/")
	if path == "" then
		return "/"
	end
	if path:sub(1, 1) ~= "/" then
		path = "/" .. path
	end
	return path ~= "/" and path:gsub("/+$", "") or path
end

local function split_remote_path(path)
	local parts = {}
	for part in normalize_remote_path(path):gmatch("[^/]+") do
		parts[#parts + 1] = part
	end
	return parts
end

local function remote_relative_path(root, path)
	root = normalize_remote_path(root)
	path = normalize_remote_path(path)
	if path == root then
		return ""
	end
	local prefix = root .. "/"
	if vim.startswith(path, prefix) then
		return path:sub(#prefix + 1)
	end
	return nil
end

local infer_primary_remote_path

local lua_pattern_magic = {
	["^"] = true,
	["$"] = true,
	["("] = true,
	[")"] = true,
	["%"] = true,
	["."] = true,
	["["] = true,
	["]"] = true,
	["+"] = true,
	["-"] = true,
}

local function glob_to_lua_pattern(glob)
	local pattern = "^"
	local index = 1
	while index <= #glob do
		local char = glob:sub(index, index)
		if char == "*" then
			pattern = pattern .. ".*"
		elseif char == "?" then
			pattern = pattern .. "."
		elseif lua_pattern_magic[char] then
			pattern = pattern .. "%" .. char
		else
			pattern = pattern .. char
		end
		index = index + 1
	end
	return pattern .. "$"
end

local function path_components(path)
	local components = {}
	for component in tostring(path or ""):gmatch("[^/]+") do
		components[#components + 1] = component
	end
	return components
end

local function pattern_matches_path(pattern, relative)
	pattern = tostring(pattern or ""):gsub("^/+", "")
	if pattern == "" then
		return false
	end
	relative = tostring(relative or ""):gsub("^/+", "")
	if pattern:sub(-1) == "/" then
		local directory = pattern:gsub("/+$", "")
		return relative == directory or vim.startswith(relative, directory .. "/") or relative:find("/" .. directory .. "/", 1, true) ~= nil
	end
	if pattern:find("/", 1, true) then
		return relative:match(glob_to_lua_pattern(pattern)) ~= nil
	end
	for _, component in ipairs(path_components(relative)) do
		if component:match(glob_to_lua_pattern(pattern)) then
			return true
		end
	end
	return false
end

local function is_ignored_remote_path(remote_path)
	if not context then
		return false
	end
	remote_path = infer_primary_remote_path(remote_path)
	local relative = remote_relative_path(context.remote_path, remote_path)
	if not relative or relative == "" then
		return false
	end
	for _, pattern in ipairs(context.ignore_patterns or {}) do
		if pattern_matches_path(pattern, relative) then
			return true
		end
	end
	return false
end

infer_primary_remote_path = function(path)
	if not context then
		return normalize_remote_path(path)
	end
	path = normalize_remote_path(path)
	local root = normalize_remote_path(context.remote_path)
	if remote_relative_path(root, path) then
		return path
	end

	for _, alias in ipairs(context.remote_path_aliases or {}) do
		local relative = remote_relative_path(alias, path)
		if relative then
			return relative == "" and root or (root .. "/" .. relative)
		end
	end

	local root_parts = split_remote_path(root)
	local path_parts = split_remote_path(path)
	local best_relative_start
	for root_start = 1, #root_parts do
		local suffix_len = #root_parts - root_start + 1
		if suffix_len >= 2 and suffix_len < #path_parts then
			for path_start = 1, #path_parts - suffix_len + 1 do
				local matched = true
				for offset = 0, suffix_len - 1 do
					if root_parts[root_start + offset] ~= path_parts[path_start + offset] then
						matched = false
						break
					end
				end
				if matched then
					best_relative_start = path_start + suffix_len
					break
				end
			end
			if best_relative_start then
				break
			end
		end
	end
	if best_relative_start then
		local relative = table.concat(path_parts, "/", best_relative_start)
		return relative == "" and root or (root .. "/" .. relative)
	end

	return path
end

local function clean_relative_path(path)
	path = tostring(path or ""):gsub("^%./", ""):gsub("/+", "/")
	if path == "" or path == "." then
		return nil
	end
	if path:sub(1, 1) == "/" then
		return normalize_remote_path(path)
	end
	return path
end

local function join_remote_path(root, path)
	path = clean_relative_path(path)
	if not path then
		return nil
	end
	if path:sub(1, 1) == "/" then
		return normalize_remote_path(path)
	end
	root = normalize_remote_path(root)
	return root == "/" and ("/" .. path) or (root .. "/" .. path)
end

local function canola_url(path)
	return "canola-ssh://" .. context.host .. "/" .. normalize_remote_path(path)
end

local function oil_url(path)
	return "oil-ssh://" .. context.host .. "/" .. normalize_remote_path(path)
end

local function parse_remote_url(url)
	local scheme, remote = tostring(url or ""):match("^([%w%+%-%.]+://)(.+)$")
	if scheme ~= "canola-ssh://" and scheme ~= "oil-ssh://" and scheme ~= "ssh://" and scheme ~= "scp://" then
		return nil
	end
	local host, path = remote:match("^([^/]+)(/.*)$")
	if not host then
		return nil
	end
	return host, normalize_remote_path(path)
end

local function parse_json(data)
	if vim.json and vim.json.decode then
		return vim.json.decode(data)
	end
	return vim.fn.json_decode(data)
end

local function system_async(args, callback)
	if vim.system then
		vim.system(args, { text = true }, function(result)
			vim.schedule(function()
				callback(result.code, result.stdout or "", result.stderr or "")
			end)
		end)
		return
	end

	vim.fn.jobstart(args, {
		stdout_buffered = true,
		stderr_buffered = true,
		on_exit = function(_, code)
			callback(code, "", "")
		end,
	})
end

local function system_sync(args)
	if vim.system then
		local result = vim.system(args, { text = true }):wait()
		return result.code, result.stdout or "", result.stderr or ""
	end
	local output = vim.fn.system(args)
	return vim.v.shell_error, output, ""
end

local function load_context()
	local path = vim.env.EDITR_CONTEXT
	if not path or path == "" then
		return nil
	end
	local ok, lines = pcall(vim.fn.readfile, path)
	if not ok then
		notify("Failed to read EDITR_CONTEXT: " .. path, vim.log.levels.WARN)
		return nil
	end
	local ok_json, decoded = pcall(parse_json, table.concat(lines, "\n"))
	if not ok_json then
		notify("Invalid EDITR_CONTEXT JSON: " .. path, vim.log.levels.WARN)
		return nil
	end
	return decoded
end

local function check_capabilities()
	local code, stdout = system_sync({ config.editr_bin, "capabilities", "--json" })
	if code ~= 0 then
		notify("editr binary is not available: " .. config.editr_bin, vim.log.levels.WARN)
		return nil
	end
	local ok, decoded = pcall(parse_json, stdout)
	if not ok then
		notify("editr capabilities output is not valid JSON", vim.log.levels.WARN)
		return nil
	end
	local features = {}
	for _, feature in ipairs(decoded.features or {}) do
		features[feature] = true
	end
	for _, required in ipairs({ "context-v1", "hydrate-v1", "list-json-v1", "watch-v1" }) do
		if not features[required] then
			notify("editr binary is missing required feature: " .. required, vim.log.levels.WARN)
			return nil
		end
	end
	return decoded
end

local function ensure_context()
	if context then
		return true
	end
	context = load_context()
	if not context then
		return false
	end
	capabilities = check_capabilities()
	return capabilities ~= nil
end

local function human_size(bytes)
	if not bytes then
		return "unknown size"
	end
	local units = {
		{ "GB", 1000000000 },
		{ "MB", 1000000 },
		{ "KB", 1000 },
	}
	for _, unit in ipairs(units) do
		if bytes >= unit[2] then
			return string.format("%.1f %s", bytes / unit[2], unit[1])
		end
	end
	return tostring(bytes) .. " B"
end

local function remote_available(kind)
	if kind == "canola" and config.integrations.canola then
		return pcall(require, "canola")
	end
	if kind == "oil" and config.integrations.oil then
		return pcall(require, "oil")
	end
	return false
end

local function remote_buffer_available()
	return remote_available("canola") or remote_available("oil")
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

local function open_path(path, opts)
	opts = opts or {}
	if opts.win and vim.api.nvim_win_is_valid(opts.win) then
		pcall(vim.api.nvim_set_current_win, opts.win)
	end
	vim.cmd(open_command(opts) .. " " .. vim.fn.fnameescape(path))
end

local function open_remote_buffer(remote_path, opts)
	if remote_available("canola") then
		open_path(canola_url(remote_path), opts)
		return true
	end
	if remote_available("oil") then
		open_path(oil_url(remote_path), opts)
		return true
	end
	notify("canola/oil is not available for remote buffer fallback", vim.log.levels.WARN)
	return false
end

local function open_local_file(path, pos, opts)
	open_path(path, opts)
	if pos and pos[1] then
		pcall(vim.api.nvim_win_set_cursor, 0, { pos[1], pos[2] or 0 })
		vim.cmd("normal! zzzv")
	end
end

local function local_path_for_remote(remote_path)
	local root = normalize_remote_path(context.remote_path)
	remote_path = infer_primary_remote_path(remote_path)
	if remote_path == root then
		return context.local_path
	end
	local prefix = root .. "/"
	if not vim.startswith(remote_path, prefix) then
		return nil
	end
	local relative = remote_path:sub(#prefix + 1)
	return vim.fs.joinpath(context.local_path, relative)
end

local function remote_path_for_input(value)
	local host, remote_path = parse_remote_url(value)
	if host == context.host and remote_path then
		return remote_path
	end
	local local_root = vim.fn.fnamemodify(context.local_path, ":p"):gsub("/+$", "")
	local local_path = vim.fn.fnamemodify(value, ":p"):gsub("/+$", "")
	if local_path == local_root then
		return context.remote_path
	end
	local prefix = local_root .. "/"
	if vim.startswith(local_path, prefix) then
		return join_remote_path(context.remote_path, local_path:sub(#prefix + 1))
	end
	return value
end

local function hydrate_args(remote_path, opts)
	opts = opts or {}
	local args = {
		config.editr_bin,
		"hydrate",
		"--context",
		context.context_file,
		"--remote-path",
		remote_path,
		"--mode",
		opts.mode or config.hydration_mode,
		"--max-size",
		config.max_auto_hydrate_size,
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
	system_async(hydrate_args(remote_path, opts), function(code, stdout, stderr)
		if code ~= 0 then
			notify(vim.trim(stderr ~= "" and stderr or stdout), vim.log.levels.ERROR)
			callback(nil)
			return
		end
		local ok, decoded = pcall(parse_json, stdout)
		if not ok then
			notify("editr hydrate returned invalid JSON", vim.log.levels.ERROR)
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
	hydrated_buffers[bufnr] = session_name
	vim.b[bufnr].editr_hydration_session = session_name
end

local function hydrate_and_open(remote_path, opts)
	opts = opts or {}
	hydrate(remote_path, { allow_large = opts.allow_large, allow_existing = true }, function(result)
		if not result then
			return
		end
		open_local_file(result.local_path, opts.pos, opts)
		remember_hydration(vim.api.nvim_get_current_buf(), result.session_name)
	end)
end

local function prompt_hydration(remote_path, check, opts)
	opts = opts or {}
	local choices = {
		("Hydrate into mirror (%s)"):format(human_size(check.size_bytes)),
	}
	if opts.existing_local_path then
		choices[#choices + 1] = "Open existing mirror copy"
	end
	if remote_buffer_available() then
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
			open_local_file(opts.existing_local_path, opts.pos, opts)
			return
		end
		if choice:match("^Open remote") then
			open_remote_buffer(remote_path, opts)
			return
		end
		hydrate_and_open(remote_path, vim.tbl_extend("force", opts, { allow_large = true }))
	end)
end

function M.open_remote_path(remote_path, opts)
	if not ensure_context() then
		return false
	end
	opts = opts or {}
	remote_path = infer_primary_remote_path(remote_path)
	local local_path = local_path_for_remote(remote_path)
	local local_exists = local_path and vim.uv.fs_stat(local_path) ~= nil
	if local_exists and not opts.check_existing then
		open_local_file(local_path, opts.pos, opts)
		return true
	end
	hydrate(remote_path, { check = true }, function(check)
		if not check then
			return
		end
		local policy = opts.policy or config.remote_open_policy
		if policy == "remote" then
			open_remote_buffer(remote_path, opts)
		elseif policy == "hydrate" then
			hydrate_and_open(remote_path, vim.tbl_extend("force", opts, { allow_large = true }))
		elseif policy == "auto_under_limit" and not check.over_limit then
			notify(("Hydrating %s (%s)"):format(remote_path, human_size(check.size_bytes)))
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

local function ssh_args(command)
	local args = {}
	vim.list_extend(args, config.ssh_args or {})
	args[#args + 1] = context.host
	args[#args + 1] = command
	return args
end

local function files_command(root)
	local quoted_root = shellescape(root)
	return table.concat({
		"cd " .. quoted_root .. " 2>/dev/null || exit 1",
		"if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then git ls-files --cached -z -- .; git ls-files --others --exclude-standard -z -- . ':(exclude).[^/]*' ':(exclude)**/.[^/]*'",
		"elif command -v fd >/dev/null 2>&1; then fd --type f --type l --color never -E .git -0 .",
		"elif command -v fdfind >/dev/null 2>&1; then fdfind --type f --type l --color never -E .git -0 .",
		"elif command -v rg >/dev/null 2>&1; then rg --files --no-messages --color never -g '!.git' -0",
		"else find . -type f -not -path '*/.git/*' -print0; fi",
	}, "; ")
end

local function grep_command(root, query, extra_args)
	local rg_args = {
		"rg",
		"--color=never",
		"--no-heading",
		"--with-filename",
		"--line-number",
		"--column",
		"--smart-case",
		"--max-columns=500",
		"--max-columns-preview",
		"--glob=!.git",
		"--no-hidden",
		"-0",
	}
	vim.list_extend(rg_args, extra_args or {})
	vim.list_extend(rg_args, { "--", query })

	local smart_case = tostring(query or ""):lower() == tostring(query or "")
	local git_args = {
		"git",
		"grep",
		"-n",
		"--column",
		"-I",
		"--no-color",
		"-E",
		"--untracked",
		"--exclude-standard",
	}
	if smart_case then
		git_args[#git_args + 1] = "-i"
	end
	vim.list_extend(git_args, { "-e", query, "--", ".", ":(exclude).[^/]*", ":(exclude)**/.[^/]*" })

	local find_grep_args = {
		"find",
		".",
		"-type",
		"f",
		"-not",
		"-path",
		"*/.git/*",
		"-not",
		"-path",
		"*/.*/*",
		"-exec",
		"grep",
		"-n",
		"-I",
		"-E",
		"-H",
	}
	if smart_case then
		find_grep_args[#find_grep_args + 1] = "-i"
	end
	vim.list_extend(find_grep_args, { "--", query, "{}", "+" })

	return table.concat({
		"cd " .. shellescape(root) .. " 2>/dev/null || exit 1",
		table.concat({
			"if command -v rg >/dev/null 2>&1; then " .. shell_join(rg_args) .. ";",
			"elif command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then "
				.. shell_join(git_args)
				.. ";",
			"elif command -v find >/dev/null 2>&1 && command -v grep >/dev/null 2>&1; then "
				.. shell_join(find_grep_args)
				.. ";",
			"else printf '%s\\n' 'editr.nvim: rg, git grep, find, and grep were not found' >&2; exit 127;",
			"fi",
		}, " "),
		"code=$?; if [ \"$code\" -eq 1 ]; then exit 0; fi; exit \"$code\"",
	}, "; ")
end

local function parse_grep_item(text)
	local file_sep = text:find("\0", 1, true)
	if file_sep then
		local rel = clean_relative_path(text:sub(1, file_sep - 1))
		local rest = text:sub(file_sep + 1)
		local line_number, col, line_text = rest:match("^(%d+):(%d+):(.*)$")
		return rel, line_number, col, line_text, rest
	end

	local rel, line_number, col, line_text = text:match("^(.-):(%d+):(%d+):(.*)$")
	if rel then
		return clean_relative_path(rel), line_number, col, line_text, ("%s:%s:%s"):format(line_number, col, line_text)
	end

	rel, line_number, line_text = text:match("^(.-):(%d+):(.*)$")
	if rel then
		return clean_relative_path(rel), line_number, "1", line_text, ("%s:%s"):format(line_number, line_text)
	end

	return nil
end

local function picker_confirm(picker)
	local items = picker:selected({ fallback = true })
	picker:close()
	for _, item in ipairs(items) do
		M.open_remote_path(item.remote_path, { pos = item.pos })
	end
end

function M.files()
	if not ensure_context() then
		return false
	end
	if not config.integrations.snacks then
		return false
	end
	local ok, snacks = pcall(require, "snacks")
	if not ok then
		return false
	end
	snacks.picker({
		title = "editr Remote Files: " .. context.target,
		finder = function(_, ctx)
			return require("snacks.picker.source.proc").proc(
				ctx:opts({
					cmd = "ssh",
					args = ssh_args(files_command(context.remote_path)),
					sep = "\0",
					notify = true,
					transform = function(item)
						local rel = clean_relative_path(item.text)
						local remote_path = rel and join_remote_path(context.remote_path, rel)
						if not remote_path then
							return false
						end
						item.text = rel
						item.file = rel
						item.display_file = rel
						item.remote_path = remote_path
					end,
				}),
				ctx
			)
		end,
		format = require("snacks.picker.format").filename,
		confirm = picker_confirm,
		live = false,
		show_empty = true,
	})
	return true
end

function M.grep()
	if not ensure_context() then
		return false
	end
	if not config.integrations.snacks then
		return false
	end
	local ok, snacks = pcall(require, "snacks")
	if not ok then
		return false
	end
	snacks.picker({
		title = "editr Remote Grep: " .. context.target,
		finder = function(_, ctx)
			local query = ((ctx or {}).filter or {}).search or ""
			if query == "" then
				return function() end
			end
			local pattern, extra_args = require("snacks.picker.util").parse(query)
			if pattern == "" then
				return function() end
			end
			return require("snacks.picker.source.proc").proc(
				ctx:opts({
					cmd = "ssh",
					args = ssh_args(grep_command(context.remote_path, pattern, extra_args)),
					notify = true,
					transform = function(item)
						local rel, line_number, col, text, rest = parse_grep_item(item.text)
						local remote_path = rel and join_remote_path(context.remote_path, rel)
						if not (line_number and col and text and remote_path) then
							return false
						end
						item.text = rel .. ":" .. rest:gsub(MATCH_SEP, "")
						item.file = rel
						item.display_file = rel
						item.remote_path = remote_path
						item.pos = { tonumber(line_number), tonumber(col) - 1 }
						item.line = text:gsub(MATCH_SEP, "")
					end,
				}),
				ctx
			)
		end,
		format = require("snacks.picker.format").filename,
		confirm = picker_confirm,
		live = true,
	})
	return true
end

function M.explorer()
	if not ensure_context() then
		return false
	end
	if not remote_available("canola") then
		notify("canola is not available", vim.log.levels.WARN)
		return false
	end
	local ok, canola = pcall(require, "canola")
	if ok and type(canola.open) == "function" then
		canola.open(canola_url(context.remote_path))
	else
		vim.cmd.edit(vim.fn.fnameescape(canola_url(context.remote_path)))
	end
	return true
end

function M.oil()
	if not ensure_context() then
		return false
	end
	if not remote_available("oil") then
		notify("oil is not available", vim.log.levels.WARN)
		return false
	end
	vim.cmd.edit(vim.fn.fnameescape(oil_url(context.remote_path)))
	return true
end

function M.canola_select(opts)
	if not ensure_context() then
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
	local host, path = parse_remote_url(url)
	if not host or host ~= context.host then
		return false
	end
	local remote_path = join_remote_path(path, entry.name)
	if not remote_path then
		return false
	end
	if opts.close and type(canola.close) == "function" then
		pcall(canola.close, { exit_if_last_buf = false })
	end
	if entry.type == "directory" then
		if type(canola.open) == "function" then
			canola.open(canola_url(remote_path))
		else
			open_path(canola_url(remote_path), opts)
		end
		else
			M.open_remote_path(
				remote_path,
				vim.tbl_extend("force", opts, { check_existing = opts.check_existing or is_ignored_remote_path(remote_path) })
			)
		end
	return true
end

function M.info()
	if not ensure_context() then
		notify("Not inside an editr session", vim.log.levels.INFO)
		return
	end
	print(vim.inspect({
		context = context,
		capabilities = capabilities,
		config = config,
	}))
end

local function stop_hydration(session_name)
	if not session_name or session_name == "" then
		return
	end
	system_async({ config.editr_bin, "stop", session_name }, function() end)
end

local function flush_hydration(session_name)
	if not session_name or session_name == "" then
		return
	end
	system_async({ config.editr_bin, "flush", session_name }, function() end)
end

local function setup_autocmds()
	local group = vim.api.nvim_create_augroup("editr.nvim", { clear = true })
	vim.api.nvim_create_autocmd("BufWritePost", {
		group = group,
		callback = function(args)
			if config.flush_on_write then
				flush_hydration(hydrated_buffers[args.buf])
			end
		end,
	})
	vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
		group = group,
		callback = function(args)
			local session_name = hydrated_buffers[args.buf]
			hydrated_buffers[args.buf] = nil
			stop_hydration(session_name)
		end,
	})
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = group,
		callback = function()
			for _, session_name in pairs(hydrated_buffers) do
				stop_hydration(session_name)
			end
		end,
	})
end

local function setup_commands()
	vim.api.nvim_create_user_command("EditrInfo", M.info, {})
	vim.api.nvim_create_user_command("EditrRemoteFiles", M.files, {})
	vim.api.nvim_create_user_command("EditrRemoteGrep", M.grep, {})
	vim.api.nvim_create_user_command("EditrCanola", M.explorer, {})
	vim.api.nvim_create_user_command("EditrOil", M.oil, {})
	vim.api.nvim_create_user_command("EditrHydrate", function(opts)
		if not ensure_context() then
			return
		end
		local remote_path = remote_path_for_input(opts.args ~= "" and opts.args or vim.api.nvim_buf_get_name(0))
		M.open_remote_path(remote_path, { policy = "hydrate" })
	end, { nargs = "?" })
end

function M.setup(opts)
	config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
	context = load_context()
	if context then
		capabilities = check_capabilities()
	end
	setup_commands()
	setup_autocmds()
end

function M.context()
	return context
end

function M.is_active()
	return context ~= nil
end

return M
