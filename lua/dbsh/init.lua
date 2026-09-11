-- Public API and user commands for dbsh.nvim.

local config = require("dbsh.config")
local backends = require("dbsh.backends")
local context = require("dbsh.context")
local exec = require("dbsh.exec")
local results = require("dbsh.results")
local definitions = require("dbsh.definitions")
local csv = require("dbsh.csv")
local export = require("dbsh.export")
local resolve = require("dbsh.resolve")
local safety = require("dbsh.safety")
local lsp = require("dbsh.lsp")

local M = {}

local last_queries = {}

local function active_snapshot()
	return results.context_snapshot(0) or context.snapshot(0)
end

function M.last_query(bufnr_or_snapshot)
	local snapshot
	if type(bufnr_or_snapshot) == "table" then
		snapshot = bufnr_or_snapshot
	else
		snapshot = results.context_snapshot(bufnr_or_snapshot or 0)
			or context.snapshot(bufnr_or_snapshot or 0)
	end
	return last_queries[snapshot.id]
end

local function run_query(sql, snapshot)
	last_queries[snapshot.id] = sql
	resolve.preamble(sql, snapshot, function(preamble)
		if preamble == nil then
			return
		end

		local split_opts = { split = config.options().results_split }
		results.running(snapshot, sql, split_opts)
		exec.run(preamble .. sql, { context = snapshot }, function(code, stdout, stderr)
			local output = stdout
			if code ~= 0 then
				output = stderr ~= "" and stderr or stdout
			end
			results.render(snapshot, sql, output, split_opts)
			if code == 0 then
				lsp.invalidate(snapshot)
			end
		end)
	end)
end

function M.query(sql)
	sql = vim.trim(sql or "")
	if sql == "" then
		vim.notify("dbsh.nvim: query is empty", vim.log.levels.WARN)
		return
	end

	local snapshot = context.snapshot(0)
	local classification = safety.classify(sql)
	if config.options().safety.mode == "confirm" and classification.action == "confirm" then
		vim.ui.select({ "Run", "Cancel" }, {
			prompt = string.format("dbsh.nvim: confirm %s SQL: ", classification.reason),
		}, function(choice)
			if choice == "Run" then
				run_query(sql, snapshot)
			end
		end)
		return
	end
	run_query(sql, snapshot)
end

function M.query_current_line()
	local lnum = vim.api.nvim_win_get_cursor(0)[1]
	local line = vim.api.nvim_buf_get_lines(0, lnum - 1, lnum, false)[1]
	M.query(line)
end

function M.paragraph_range(lines, lnum)
	local start = lnum
	while start > 1 and vim.trim(lines[start - 1] or "") ~= "" do
		start = start - 1
	end

	local stop = lnum
	while stop < #lines and vim.trim(lines[stop + 1] or "") ~= "" do
		stop = stop + 1
	end

	return start, stop
end

function M.query_paragraph()
	local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
	local lnum = vim.api.nvim_win_get_cursor(0)[1]
	local start, stop = M.paragraph_range(lines, lnum)
	M.query(table.concat(vim.list_slice(lines, start, stop), "\n"))
end

function M.query_selection()
	local mode = vim.fn.mode()
	local region = vim.fn.getregion(vim.fn.getpos("v"), vim.fn.getpos("."), { type = mode })
	M.query(table.concat(region, "\n"))
end

function M.yank_cell()
	vim.api.nvim_feedkeys(
		vim.api.nvim_replace_termcodes("/<C-v>u2502<Esc>gemz", true, true, true), "n", false)
	vim.api.nvim_feedkeys(
		vim.api.nvim_replace_termcodes("?<C-v>u2502<CR>", true, true, true), "n", false)
	vim.api.nvim_feedkeys("llv`zy", "n", false)
end

function M.yank_registers(clipboard)
	local names = { '"' }
	for _, item in ipairs(vim.split(clipboard or "", ",", { plain = true })) do
		if item == "unnamedplus" then
			table.insert(names, "+")
		elseif item == "unnamed" then
			table.insert(names, "*")
		end
	end
	return names
end

function M.yank_csv()
	local mode = vim.fn.mode()
	if mode ~= csv.LINEWISE and mode ~= csv.BLOCKWISE then
		vim.notify(
			"dbsh.nvim: select lines with V or a block with <C-v> first",
			vim.log.levels.WARN
		)
		return
	end

	local from = vim.fn.getpos("v")
	local to = vim.fn.getpos(".")
	local lines = vim.api.nvim_buf_get_lines(
		0,
		math.min(from[2], to[2]) - 1,
		math.max(from[2], to[2]),
		false
	)

	local rows = csv.rows_from_lines(
		lines,
		mode,
		math.min(from[3], to[3]),
		math.max(from[3], to[3])
	)
	if #rows == 0 then
		vim.notify("dbsh.nvim: no table cell in the selection", vim.log.levels.WARN)
		return
	end

	local text = csv.to_csv(rows, config.options().csv_delimiter)
	for _, name in ipairs(M.yank_registers(vim.o.clipboard)) do
		vim.fn.setreg(name, text)
	end
	vim.notify(string.format("dbsh.nvim: yanked %d row(s) as CSV", #rows))
end

local function query_to_export(opts)
	local result_snapshot = results.context_snapshot(0)
	if result_snapshot ~= nil then
		return M.last_query(result_snapshot), result_snapshot
	end

	local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
	local start, stop
	if opts ~= nil and (opts.range or 0) > 0 then
		start, stop = opts.line1, opts.line2
	else
		start, stop = M.paragraph_range(lines, vim.api.nvim_win_get_cursor(0)[1])
	end
	return table.concat(vim.list_slice(lines, start, stop), "\n"), context.snapshot(0)
end

function M.export_csv(opts)
	local sql, snapshot = query_to_export(opts)
	sql = vim.trim(sql or "")
	if sql == "" then
		vim.notify("dbsh.nvim: nothing to export", vim.log.levels.WARN)
		return
	end

	resolve.preamble(sql, snapshot, function(preamble)
		if preamble == nil then
			return
		end

		local dir = config.options().export_dir
		vim.fn.mkdir(dir, "p")
		local suggestion = export.default_path(
			dir,
			snapshot.connection_name or "scratchpad",
			os.date("%Y%m%d")
		)

		vim.ui.input(
			{ prompt = "Export to: ", default = suggestion, completion = "file" },
			function(choice)
				if choice == nil or vim.trim(choice) == "" then
					return
				end
				local path = export.free_path(vim.trim(choice))
				export.run(sql, path, preamble, function(written, err)
					if err ~= nil then
						vim.notify("dbsh.nvim: " .. err, vim.log.levels.ERROR)
						return
					end
					vim.notify("dbsh.nvim: exported to " .. written)
				end, snapshot)
			end
		)
	end)
end

local function pickers()
	return require("dbsh.telescope.pickers")
end

local function contract_for(backend, kind, key)
	for _, definition in ipairs(backend[kind] or {}) do
		if definition.key == key then
			return definition
		end
	end
	return nil
end

local function dispatch_contract(kind, key, command_name)
	local backend, err = context.backend(context.snapshot(0))
	if backend == nil then
		vim.notify("dbsh.nvim: " .. err, vim.log.levels.WARN)
		return
	end
	if contract_for(backend, kind, key) == nil then
		vim.notify(
			string.format("dbsh.nvim: %s is not available for %s", command_name, backend.name),
			vim.log.levels.WARN
		)
		return
	end
	if kind == "contexts" then
		pickers().context(key)
	else
		pickers().catalog(key)
	end
end

local function declare_commands()
	local command = vim.api.nvim_create_user_command

	command("DbConnections", function() pickers().connections() end, {})
	command("DbGlobalConnection", function() pickers().global_connection() end, {})
	command("DbForgetConnection", function()
		local _, err = context.forget(0, "forget")
		if err ~= nil then
			vim.notify("dbsh.nvim: " .. err, vim.log.levels.WARN)
		end
	end, {})
	command("DbTemp", function() pickers().scratchpads() end, {})
	command("DbObjects", function() pickers().objects() end, {})
	command("DbDefinitions", function() pickers().definitions() end, {})
	command("DbToggleDefinition", function()
		if not definitions.toggle(active_snapshot()) then
			vim.notify("dbsh.nvim: no definition yet", vim.log.levels.WARN)
		end
	end, {})
	command("DbRefreshDefinition", function()
		local ok, err = definitions.refresh()
		if not ok then
			vim.notify("dbsh.nvim: " .. err, vim.log.levels.WARN)
		end
	end, {})
	command("DbCloseDefinitions", function()
		definitions.close(active_snapshot())
	end, {})
	command("DbCancel", function() exec.cancel("user", active_snapshot()) end, {})
	command("DbToggleResults", function()
		local ok = results.toggle(active_snapshot(), { split = config.options().results_split })
		if not ok then
			vim.notify("dbsh.nvim: no result yet", vim.log.levels.WARN)
		end
	end, {})
	command("DbExportCSV", function(opts) M.export_csv(opts) end, { range = true })

	command("DbInfo", function()
		local snapshot = context.snapshot(0)
		local connection = snapshot.connection
		if connection == nil or snapshot.connection_name == nil then
			vim.notify("dbsh.nvim: no current connection", vim.log.levels.WARN)
			return
		end
		vim.notify(string.format(
			"dbsh.nvim: %s -> %s@%s:%s/%s",
			snapshot.connection_name,
			connection.username,
			connection.host,
			tostring(connection.port),
			connection.database
		))
	end, {})

	local declared = {}
	for _, backend in ipairs(backends.all()) do
		for _, kind in ipairs({ "contexts", "catalogs" }) do
			for _, definition in ipairs(backend[kind] or {}) do
				local name = "Db" .. definition.command
				if not declared[name] then
					declared[name] = true
					local command_kind = kind
					local command_key = definition.key
					local command_name = name
					command(name, function()
						dispatch_contract(command_kind, command_key, command_name)
					end, {})
				end
			end
		end
	end
end

function M.setup(opts)
	config.setup(opts)
	context.setup()
	lsp.setup()
	last_queries = {}
	declare_commands()

	local group = vim.api.nvim_create_augroup("dbsh", { clear = true })
	vim.api.nvim_create_autocmd("User", {
		pattern = "DbshContextChanged",
		group = group,
		callback = function(args)
			local bufnr = args.data and args.data.bufnr or 0
			lsp.sync_external(context.snapshot(bufnr))
		end,
	})
	lsp.sync_external(context.snapshot(0))

	vim.api.nvim_create_autocmd("LspAttach", {
		group = group,
		callback = function(args)
			lsp.sync_external_client(
				vim.lsp.get_client_by_id(args.data.client_id),
				context.snapshot(args.buf)
			)
		end,
	})
end

return M
