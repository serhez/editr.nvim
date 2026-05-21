local state = require("editr.state")
local util = require("editr.util")

local M = {}

local function load_context()
	local path = vim.env.EDITR_CONTEXT
	if not path or path == "" then
		return nil
	end
	local ok, lines = pcall(vim.fn.readfile, path)
	if not ok then
		util.notify("Failed to read EDITR_CONTEXT: " .. path, vim.log.levels.WARN)
		return nil
	end
	local ok_json, decoded = pcall(util.parse_json, table.concat(lines, "\n"))
	if not ok_json then
		util.notify("Invalid EDITR_CONTEXT JSON: " .. path, vim.log.levels.WARN)
		return nil
	end
	return decoded
end

local function check_capabilities()
	local code, stdout = util.system_sync({ state.config.editr_bin, "capabilities", "--json" })
	if code ~= 0 then
		util.notify("editr binary is not available: " .. state.config.editr_bin, vim.log.levels.WARN)
		return nil
	end
	local ok, decoded = pcall(util.parse_json, stdout)
	if not ok then
		util.notify("editr capabilities output is not valid JSON", vim.log.levels.WARN)
		return nil
	end
	local features = {}
	for _, feature in ipairs(decoded.features or {}) do
		features[feature] = true
	end
	for _, required in ipairs({ "context-v1", "hydrate-v1", "list-json-v1", "watch-v1" }) do
		if not features[required] then
			util.notify("editr binary is missing required feature: " .. required, vim.log.levels.WARN)
			return nil
		end
	end
	return decoded
end

function M.load()
	state.context = load_context()
	if state.context then
		state.capabilities = check_capabilities()
	end
	return state.context
end

function M.ensure()
	if state.context then
		return true
	end
	state.context = load_context()
	if not state.context then
		return false
	end
	state.capabilities = check_capabilities()
	return state.capabilities ~= nil
end

function M.info()
	if not M.ensure() then
		util.notify("Not inside an editr session", vim.log.levels.INFO)
		return
	end
	print(vim.inspect({
		context = state.context,
		capabilities = state.capabilities,
		config = state.config,
	}))
end

function M.context()
	return state.context
end

function M.is_active()
	return state.context ~= nil
end

return M
