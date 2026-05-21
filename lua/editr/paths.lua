local state = require("editr.state")

local M = {}

function M.normalize_remote_path(path)
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
	for part in M.normalize_remote_path(path):gmatch("[^/]+") do
		parts[#parts + 1] = part
	end
	return parts
end

function M.remote_relative_path(root, path)
	root = M.normalize_remote_path(root)
	path = M.normalize_remote_path(path)
	if path == root then
		return ""
	end
	local prefix = root .. "/"
	if vim.startswith(path, prefix) then
		return path:sub(#prefix + 1)
	end
	return nil
end

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

function M.infer_primary_remote_path(path)
	if not state.context then
		return M.normalize_remote_path(path)
	end
	path = M.normalize_remote_path(path)
	local root = M.normalize_remote_path(state.context.remote_path)
	if M.remote_relative_path(root, path) then
		return path
	end

	for _, alias in ipairs(state.context.remote_path_aliases or {}) do
		local relative = M.remote_relative_path(alias, path)
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

function M.is_ignored_remote_path(remote_path)
	if not state.context then
		return false
	end
	remote_path = M.infer_primary_remote_path(remote_path)
	local relative = M.remote_relative_path(state.context.remote_path, remote_path)
	if not relative or relative == "" then
		return false
	end
	for _, pattern in ipairs(state.context.ignore_patterns or {}) do
		if pattern_matches_path(pattern, relative) then
			return true
		end
	end
	return false
end

function M.clean_relative_path(path)
	path = tostring(path or ""):gsub("^%./", ""):gsub("/+", "/")
	if path == "" or path == "." then
		return nil
	end
	if path:sub(1, 1) == "/" then
		return M.normalize_remote_path(path)
	end
	return path
end

function M.join_remote_path(root, path)
	path = M.clean_relative_path(path)
	if not path then
		return nil
	end
	if path:sub(1, 1) == "/" then
		return M.normalize_remote_path(path)
	end
	root = M.normalize_remote_path(root)
	return root == "/" and ("/" .. path) or (root .. "/" .. path)
end

function M.canola_url(path)
	return "canola-ssh://" .. state.context.host .. "/" .. M.normalize_remote_path(path)
end

function M.oil_url(path)
	return "oil-ssh://" .. state.context.host .. "/" .. M.normalize_remote_path(path)
end

function M.parse_remote_url(url)
	local scheme, remote = tostring(url or ""):match("^([%w%+%-%.]+://)(.+)$")
	if scheme ~= "canola-ssh://" and scheme ~= "oil-ssh://" and scheme ~= "ssh://" and scheme ~= "scp://" then
		return nil
	end
	local host, path = remote:match("^([^/]+)(/.*)$")
	if not host then
		return nil
	end
	return host, M.normalize_remote_path(path)
end

function M.local_path_for_remote(remote_path)
	local root = M.normalize_remote_path(state.context.remote_path)
	remote_path = M.infer_primary_remote_path(remote_path)
	if remote_path == root then
		return state.context.local_path
	end
	local prefix = root .. "/"
	if not vim.startswith(remote_path, prefix) then
		return nil
	end
	local relative = remote_path:sub(#prefix + 1)
	return vim.fs.joinpath(state.context.local_path, relative)
end

function M.remote_path_for_input(value)
	local host, remote_path = M.parse_remote_url(value)
	if host == state.context.host and remote_path then
		return remote_path
	end
	local local_root = vim.fn.fnamemodify(state.context.local_path, ":p"):gsub("/+$", "")
	local local_path = vim.fn.fnamemodify(value, ":p"):gsub("/+$", "")
	if local_path == local_root then
		return state.context.remote_path
	end
	local prefix = local_root .. "/"
	if vim.startswith(local_path, prefix) then
		return M.join_remote_path(state.context.remote_path, local_path:sub(#prefix + 1))
	end
	return value
end

return M
