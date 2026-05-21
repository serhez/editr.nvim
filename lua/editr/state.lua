local M = {}

M.defaults = {
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

M.config = vim.deepcopy(M.defaults)
M.context = nil
M.capabilities = nil
M.hydrated_buffers = {}

function M.reset(opts)
	M.config = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
	M.context = nil
	M.capabilities = nil
end

return M
