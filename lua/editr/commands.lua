local context = require("editr.context")
local explorer = require("editr.explorer")
local hydrate = require("editr.hydrate")
local paths = require("editr.paths")
local pickers = require("editr.pickers")

local M = {}

function M.setup()
	vim.api.nvim_create_user_command("EditrInfo", context.info, {})
	vim.api.nvim_create_user_command("EditrRemoteFiles", pickers.files, {})
	vim.api.nvim_create_user_command("EditrRemoteGrep", pickers.grep, {})
	vim.api.nvim_create_user_command("EditrCanola", explorer.explorer, {})
	vim.api.nvim_create_user_command("EditrOil", explorer.oil, {})
	vim.api.nvim_create_user_command("EditrHydrate", function(opts)
		if not context.ensure() then
			return
		end
		local remote_path = paths.remote_path_for_input(opts.args ~= "" and opts.args or vim.api.nvim_buf_get_name(0))
		hydrate.open_remote_path(remote_path, { policy = "hydrate" })
	end, { nargs = "?" })
end

return M
