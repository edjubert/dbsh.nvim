-- CSV file export.
-- COPY ... TO STDOUT is used instead of the COPY meta-command: psql
-- meta-commands are line-oriented, which breaks on multi-line queries, and
-- COPY ... TO '<file>' would need a superuser right and write server side.
-- The file itself is therefore written by Neovim.

local config = require("psql.config")
local exec = require("psql.exec")

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

-- The inner query must not carry its trailing semicolon: COPY (SELECT 1;)
-- is a syntax error.
function M.copy_query(sql, delimiter)
	local inner = (vim.trim(sql):gsub(";%s*$", ""))
	return string.format(
		"COPY (%s) TO STDOUT WITH (FORMAT CSV, HEADER, DELIMITER '%s');",
		inner,
		delimiter
	)
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

-- callback(path, err)
function M.run(sql, path, callback)
	local query = M.copy_query(sql, config.options().csv_delimiter)
	-- Raw mode: no \timing, no decoration, so stdout is the CSV itself.
	exec.run(query, { raw = true }, function(code, stdout, stderr)
		if code ~= 0 then
			callback(nil, stderr ~= "" and stderr or "psql exited with code " .. tostring(code))
			return
		end
		callback(M.write(path, stdout))
	end)
end

return M
