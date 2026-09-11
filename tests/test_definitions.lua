local helpers = dofile("tests/helpers.lua")
local eq, expect_match = helpers.eq, helpers.expect_match

local config = require("dbsh.config")
local context = require("dbsh.context")
local definitions = require("dbsh.definitions")
local exec = require("dbsh.exec")

local original_runner
local snapshots = {}

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			config.setup({
				connections = {
					local_db = {
						host = "localhost",
						port = 5432,
						database = "postgres",
						username = "dev",
						password = "not-in-a-definition-key",
					},
					staging = {
						host = "db.example.com",
						port = 5432,
						database = "app",
						username = "readonly",
					},
				},
				default = "local_db",
			})
			context.setup()
			local other = vim.api.nvim_create_buf(false, true)
			assert(context.bind(other, "staging", "test"))
			snapshots = { a = context.snapshot(0), b = context.snapshot(other) }
			original_runner = exec.runner
		end,
		post_case = function()
			exec.runner = original_runner
			exec.slots = {}
			definitions._reset()
			snapshots = {}
		end,
	},
})

local function relation(oid, name)
	return {
		kind = "relation",
		oid = tostring(oid),
		schema = "public",
		name = name or "users",
		relkind = "r",
	}
end

local function successful_runner(output)
	exec.runner = function(_, _, callback)
		vim.schedule(function()
			callback({ code = 0, stdout = output or "CREATE TABLE users ();", stderr = "" })
		end)
		return { kill = function() end }
	end
end

T["uses a public definition identity without secrets or query text"] = function()
	local key = definitions.key(snapshots.a, relation(42))
	expect_match(key, "postgres")
	expect_match(key, "42")
	eq(key:find("not%-in%-a%-definition%-key"), nil)
	eq(key:find("password"), nil)
	eq(key:find("SELECT"), nil)
end

T["reuses one definition buffer for one object identity"] = function()
	successful_runner()
	local first = assert(definitions.open(snapshots.a, relation(42)))
	local second = assert(definitions.open(snapshots.a, relation(42)))

	eq(first.bufnr, second.bufnr)
	eq(#definitions.list(snapshots.a), 1)
end

T["keeps an opened definition visible when a different object opens"] = function()
	successful_runner()
	local first = assert(definitions.open(snapshots.a, relation(42, "users")))
	vim.wait(500, function() return vim.api.nvim_buf_line_count(first.bufnr) > 0 end)
	local previous = vim.api.nvim_buf_get_lines(first.bufnr, 0, -1, true)
	local second = assert(definitions.open(snapshots.a, relation(43, "orders")))

	eq(first.bufnr == second.bufnr, false)
	eq(definitions.find_win(first.bufnr) ~= nil, true)
	eq(vim.api.nvim_get_current_buf(), second.bufnr)
	eq(vim.api.nvim_buf_get_lines(first.bufnr, 0, -1, true), previous)
end

T["creates a read-only SQL scratch buffer"] = function()
	successful_runner()
	local record = assert(definitions.open(snapshots.a, relation(42)))

	eq(vim.bo[record.bufnr].buftype, "nofile")
	eq(vim.bo[record.bufnr].bufhidden, "hide")
	eq(vim.bo[record.bufnr].swapfile, false)
	eq(vim.bo[record.bufnr].filetype, "sql")
	eq(vim.bo[record.bufnr].modifiable, false)
end

T["filters definitions by the active session"] = function()
	successful_runner()
	assert(definitions.open(snapshots.a, relation(42)))
	assert(definitions.open(snapshots.b, relation(43)))

	eq(#definitions.list(snapshots.a), 1)
	eq(#definitions.list(snapshots.b), 1)
	eq(definitions.list(snapshots.a)[1].object.oid, "42")
end

T["refreshes against the stored snapshot after the source buffer changes context"] = function()
	local calls = {}
	exec.runner = function(argv, _, callback)
		table.insert(calls, vim.deepcopy(argv))
		vim.schedule(function()
			callback({ code = 0, stdout = "CREATE TABLE users ();", stderr = "" })
		end)
		return { kill = function() end }
	end
	local record = assert(definitions.open(snapshots.a, relation(42)))
	assert(context.bind(snapshots.a.bufnr, "staging", "test"))

	assert(definitions.refresh(record.bufnr))
	vim.wait(500, function() return #calls == 2 end)

	local argv = calls[2]
	eq(argv[1], "pg_dump")
	eq(argv[vim.tbl_contains(argv, "-d") and vim.fn.index(argv, "-d") + 2 or 0], "postgres")
end

T["toggles the current definition and closes only the active session definitions"] = function()
	successful_runner()
	local a = assert(definitions.open(snapshots.a, relation(42)))
	local b = assert(definitions.open(snapshots.b, relation(43)))

	eq(definitions.toggle(snapshots.a), true)
	eq(definitions.find_win(a.bufnr), nil)
	eq(definitions.find_win(b.bufnr) ~= nil, true)
	eq(definitions.toggle(snapshots.a), true)
	eq(definitions.find_win(a.bufnr) ~= nil, true)

	definitions.close(snapshots.a)
	eq(definitions.find_win(a.bufnr), nil)
	eq(definitions.find_win(b.bufnr) ~= nil, true)
end

return T
