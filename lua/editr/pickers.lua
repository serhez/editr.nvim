local state = require("editr.state")
local util = require("editr.util")
local context = require("editr.context")
local paths = require("editr.paths")
local hydrate = require("editr.hydrate")

local M = {}

local MATCH_SEP = "@@EDITR_MATCH@@"

local function ssh_args(command)
	local args = {}
	vim.list_extend(args, state.config.ssh_args or {})
	args[#args + 1] = state.context.host
	args[#args + 1] = command
	return args
end

local function files_command(root)
	local quoted_root = util.shellescape(root)
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
		"cd " .. util.shellescape(root) .. " 2>/dev/null || exit 1",
		table.concat({
			"if command -v rg >/dev/null 2>&1; then " .. util.shell_join(rg_args) .. ";",
			"elif command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then "
				.. util.shell_join(git_args)
				.. ";",
			"elif command -v find >/dev/null 2>&1 && command -v grep >/dev/null 2>&1; then "
				.. util.shell_join(find_grep_args)
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
		local rel = paths.clean_relative_path(text:sub(1, file_sep - 1))
		local rest = text:sub(file_sep + 1)
		local line_number, col, line_text = rest:match("^(%d+):(%d+):(.*)$")
		return rel, line_number, col, line_text, rest
	end

	local rel, line_number, col, line_text = text:match("^(.-):(%d+):(%d+):(.*)$")
	if rel then
		return paths.clean_relative_path(rel), line_number, col, line_text, ("%s:%s:%s"):format(line_number, col, line_text)
	end

	rel, line_number, line_text = text:match("^(.-):(%d+):(.*)$")
	if rel then
		return paths.clean_relative_path(rel), line_number, "1", line_text, ("%s:%s"):format(line_number, line_text)
	end

	return nil
end

local function picker_confirm(picker)
	local items = picker:selected({ fallback = true })
	picker:close()
	for _, item in ipairs(items) do
		hydrate.open_remote_path(item.remote_path, { pos = item.pos })
	end
end

function M.files()
	if not context.ensure() then
		return false
	end
	if not state.config.integrations.snacks then
		return false
	end
	local ok, snacks = pcall(require, "snacks")
	if not ok then
		return false
	end
	snacks.picker({
		title = "editr Remote Files: " .. state.context.target,
		finder = function(_, ctx)
			return require("snacks.picker.source.proc").proc(
				ctx:opts({
					cmd = "ssh",
					args = ssh_args(files_command(state.context.remote_path)),
					sep = "\0",
					notify = true,
					transform = function(item)
						local rel = paths.clean_relative_path(item.text)
						local remote_path = rel and paths.join_remote_path(state.context.remote_path, rel)
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
	if not context.ensure() then
		return false
	end
	if not state.config.integrations.snacks then
		return false
	end
	local ok, snacks = pcall(require, "snacks")
	if not ok then
		return false
	end
	snacks.picker({
		title = "editr Remote Grep: " .. state.context.target,
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
					args = ssh_args(grep_command(state.context.remote_path, pattern, extra_args)),
					notify = true,
					transform = function(item)
						local rel, line_number, col, text, rest = parse_grep_item(item.text)
						local remote_path = rel and paths.join_remote_path(state.context.remote_path, rel)
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

return M
