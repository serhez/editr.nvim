local M = {}

function M.notify(message, level)
	vim.notify(message, level or vim.log.levels.INFO, { title = "editr" })
end

function M.shellescape(value)
	return vim.fn.shellescape(tostring(value or ""))
end

function M.shell_join(args)
	local quoted = {}
	for _, arg in ipairs(args) do
		quoted[#quoted + 1] = M.shellescape(arg)
	end
	return table.concat(quoted, " ")
end

function M.parse_json(data)
	if vim.json and vim.json.decode then
		return vim.json.decode(data)
	end
	return vim.fn.json_decode(data)
end

function M.system_async(args, callback)
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

function M.system_sync(args)
	if vim.system then
		local result = vim.system(args, { text = true }):wait()
		return result.code, result.stdout or "", result.stderr or ""
	end
	local output = vim.fn.system(args)
	return vim.v.shell_error, output, ""
end

function M.human_size(bytes)
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

return M
