-- CSV file export.
-- The file is written by Neovim, not by the server: the backend only says
-- which query makes its CLI print CSV on stdout, and we save what comes back.

local config = require("dbsh.config")
local exec = require("dbsh.exec")

local M = {}

-- Returns the path untouched when free, otherwise inserts _1, _2, ...
-- before the extension until an unused name shows up.
function M.free_path(path)
	if vim.fn.filereadable(path) == 0 then
		return path
	end

	local dir = vim.fn.fnamemodify(path, ":h")
	local stem = vim.fn.fnamemodify(path, ":t:r")
	local ext = vim.fn.fnamemodify(path, ":e")

	local n = 0
	local candidate = path
	while vim.fn.filereadable(candidate) == 1 do
		n = n + 1
		candidate = vim.fs.joinpath(dir, string.format("%s_%d.%s", stem, n, ext))
	end
	return candidate
end

-- <dir>/<date>_<base>.csv, made unique when already taken.
function M.default_path(dir, base, date)
	return M.free_path(vim.fs.joinpath(dir, string.format("%s_%s.csv", date, base)))
end

function M.write(path, contents)
	local fd, err = io.open(path, "w")
	if fd == nil then
		return nil, err
	end
	fd:write(contents)
	fd:close()
	return path, nil
end

-- preamble holds the backend directives declaring the query variables; they
-- must run before the export query, never inside it. callback(path, err)
function M.run(sql, path, preamble, callback)
	local backend, err = config.backend()
	if backend == nil then
		callback(nil, err)
		return
	end

	local query = backend.export_query(sql, config.options().csv_delimiter)
	-- Raw mode: no decoration, so stdout is the CSV itself.
	exec.run((preamble or "") .. query, { mode = "raw" }, function(code, stdout, stderr)
		if code ~= 0 then
			callback(nil, stderr ~= "" and stderr or "the query exited with code " .. tostring(code))
			return
		end
		callback(M.write(path, stdout))
	end)
end

return M
