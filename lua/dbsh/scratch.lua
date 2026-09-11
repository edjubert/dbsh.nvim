-- Persistent SQL scratchpad, one file per connection.
-- A real file on disk, not a scratch buffer, so LSP and formatting work.

local context = require("dbsh.context")

local M = {}

function M.dir()
	return vim.fs.joinpath(vim.fn.stdpath("data"), "dbsh")
end

function M.path(name)
	return vim.fs.joinpath(M.dir(), (name or "default") .. ".sql")
end

function M.open()
	local name = context.snapshot(0).connection_name or "default"
	-- "p" makes mkdir idempotent: no error when the directory already exists.
	vim.fn.mkdir(M.dir(), "p")

	local path = M.path(name)
	vim.cmd("edit " .. vim.fn.fnameescape(path))
	vim.bo.filetype = "sql"
	return path
end

return M
