-- Query-backed CSV views. The original result buffer stays available, and the
-- source query/context live on the derived buffer rather than in global state.
local config = require("dbsh.config")
local context = require("dbsh.context")
local exec = require("dbsh.exec")
local float = require("dbsh.float")

local M = {}

function M.source(bufnr)
	if bufnr == nil or bufnr == 0 then bufnr = vim.api.nvim_get_current_buf() end
	if not vim.api.nvim_buf_is_valid(bufnr) then return nil end
	local ok, source = pcall(vim.api.nvim_buf_get_var, bufnr, "dbsh_csv_source")
	return ok and source or nil
end

function M.context_snapshot(bufnr)
	local source = M.source(bufnr)
	return source and source.snapshot or nil
end

local function set_lines(buf, text)
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, "\n", { plain = true }))
	vim.bo[buf].modifiable = false
end

-- Validate dependencies before resolving variables, opening a window or
-- executing anything. Requiring csvview also supports module-based lazy loading.
function M.prepare(snapshot)
	local backend, err = context.backend(snapshot)
	if backend == nil then return nil, err end
	if backend.csv_mode == nil then return nil, "CSV view is not available for " .. backend.name end
	local ok, viewer = pcall(require, "csvview")
	if not ok or type(viewer) ~= "table" or type(viewer.enable) ~= "function" then
		return nil, "DbCSVView requires hat0uma/csvview.nvim"
	end
	return { backend = backend, viewer = viewer }
end

function M.run(query, snapshot, preamble, prepared)
	local backend, viewer = prepared.backend, prepared.viewer
	local delimiter = backend.csv_delimiter or config.options().csv_delimiter
	local csv_query = backend.csv_query and backend.csv_query(query, delimiter) or query
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(buf, string.format(
		"__DBSH_CSV__ %s #%d.csv", snapshot.connection_name or snapshot.id, buf
	))
	vim.b[buf].dbsh_csv_source = { query = query, snapshot = vim.deepcopy(snapshot) }
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	local win
	local split = config.options().results_split
	if split == "float" then
		win = float.open(buf, { focus = true })
	else
		vim.cmd(split == "vertical" and "vsplit" or "split")
		win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(win, buf)
	end
	vim.wo[win].wrap = false
	set_lines(buf, "Loading CSV...")

	local function fail(message)
		set_lines(buf, message)
		vim.notify("dbsh.nvim: " .. message, vim.log.levels.ERROR)
	end
	exec.run((preamble or "") .. csv_query, {
		context = snapshot,
		mode = backend.csv_mode,
		progress = {
			summary = query, label = "loading CSV",
			window = function()
				return vim.api.nvim_win_is_valid(win) and win or nil
			end,
		},
	}, function(code, stdout, stderr)
		if not vim.api.nvim_buf_is_valid(buf) then return end
		if code ~= 0 then
			fail(stderr ~= "" and stderr or "CSV query exited with code " .. tostring(code))
			return
		end
		local output, err = stdout, nil
		if backend.csv_output then output, err = backend.csv_output(stdout, delimiter) end
		if output == nil then fail(err or "could not convert result to CSV"); return end
		if vim.trim(output) == "" then fail("no result to display as CSV"); return end
		set_lines(buf, output:gsub("\n$", ""))
		vim.bo[buf].filetype = "csv"
		-- Explicit parser settings override personal comment prefixes and
		-- sniffing, so data starting with # or // is still a normal row.
		local ok = pcall(viewer.enable, buf, {
			parser = { delimiter = delimiter, quote_char = '"', comments = {}, comment_lines = 0 },
			view = { header_lnum = 1, display_mode = "border" },
		})
		if not ok then
			vim.notify("dbsh.nvim: could not enable CSVView; the CSV buffer is available", vim.log.levels.WARN)
		end
	end)
	return buf
end

return M
