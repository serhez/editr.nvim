local M = {}
local unpack = table.unpack or unpack

local function notify_error(err)
	vim.notify(tostring(err), vim.log.levels.ERROR, { title = "editr router" })
end

function M.first(handlers, ...)
	for _, handler in ipairs(handlers or {}) do
		if type(handler) == "function" then
			local ok, handled = pcall(handler, ...)
			if not ok then
				notify_error(handled)
				return true
			end
			if handled then
				return true
			end
		end
	end
	return false
end

function M.map(handlers, fallback)
	return function(...)
		if M.first(handlers, ...) then
			return
		end
		if type(fallback) == "function" then
			fallback(...)
		end
	end
end

function M.editr(method, ...)
	local args = { ... }
	return function()
		local ok, editr = pcall(require, "editr")
		if not ok or type(editr.is_active) ~= "function" or not editr.is_active() then
			return false
		end
		if type(editr[method]) ~= "function" then
			return false
		end
		return editr[method](unpack(args)) ~= false
	end
end

function M.module(module_name, method, opts)
	opts = opts or {}
	return function()
		if type(opts.when) == "function" and not opts.when() then
			return false
		end
		local ok, module = pcall(require, module_name)
		if not ok or type(module[method]) ~= "function" then
			return false
		end
		local result = module[method](unpack(opts.args or {}))
		return result ~= false
	end
end

return M
