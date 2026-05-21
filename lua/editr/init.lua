local state = require("editr.state")
local commands = require("editr.commands")
local context = require("editr.context")
local explorer = require("editr.explorer")
local hydrate = require("editr.hydrate")
local pickers = require("editr.pickers")

local M = {}

function M.setup(opts)
	state.reset(opts)
	context.load()
	commands.setup()
	hydrate.setup_autocmds()
end

M.open_remote_path = hydrate.open_remote_path
M.files = pickers.files
M.grep = pickers.grep
M.explorer = explorer.explorer
M.oil = explorer.oil
M.canola_select = explorer.canola_select
M.info = context.info
M.context = context.context
M.is_active = context.is_active

return M
