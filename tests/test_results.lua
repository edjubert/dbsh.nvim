local helpers = dofile("tests/helpers.lua")
local eq = helpers.eq

local config = require("dbsh.config")
local context = require("dbsh.context")
local results = require("dbsh.results")

local snapshots = {}

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			config.setup({
				connections = {
					local_db = { host = "localhost", port = 5432, database = "postgres", username = "dev" },
					staging = { host = "db.example.com", port = 5432, database = "app", username = "readonly" },
				},
				default = "local_db",
			})
			context.setup()
			local other = vim.api.nvim_create_buf(false, true)
			assert(context.bind(other, "staging", "test"))
			snapshots = {
				a = context.snapshot(0),
				b = context.snapshot(other),
			}
		end,
		post_case = function()
			for _, snapshot in pairs(snapshots) do
				local buf = results.find_buf(snapshot)
				if buf ~= nil then
					vim.api.nvim_buf_delete(buf, { force = true })
				end
			end
			snapshots = {}
		end,
	},
})

T["creates a session-scoped scratch buffer"] = function()
	local buf = results.open(snapshots.a)
	eq(vim.api.nvim_buf_is_valid(buf), true)
	eq(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t"):find("__DBSH__", 1, true) ~= nil, true)
	eq(vim.bo[buf].buftype, "nofile")
	eq(vim.bo[buf].filetype, "sql")
	eq(results.context_snapshot(buf).id, snapshots.a.id)
end

T["disables wrapping so wide tables scroll horizontally"] = function()
	local _, win = results.open(snapshots.a)
	eq(vim.wo[win].wrap, false)
	eq(vim.wo[win].sidescrolloff, 0)
end

T["reuses one buffer per context and keeps contexts distinct"] = function()
	local first = results.open(snapshots.a)
	local second = results.open(snapshots.a)
	local other = results.open(snapshots.b)
	eq(first, second)
	eq(first == other, false)
end

T["renders independent output in each result buffer"] = function()
	local a = results.render(snapshots.a, "SELECT 1;", "one")
	local b = results.render(snapshots.b, "SELECT 2;", "two")

	eq(vim.api.nvim_buf_get_lines(a, 0, -1, true), { "SELECT 1;", "", "one" })
	eq(vim.api.nvim_buf_get_lines(b, 0, -1, true), { "SELECT 2;", "", "two" })
end

T["shows a running placeholder without replacing another session"] = function()
	results.render(snapshots.b, "SELECT 2;", "two")
	local a = results.running(snapshots.a, "SELECT 1;")

	eq(vim.api.nvim_buf_get_lines(a, 0, -1, true), { "# Running...", "SELECT 1;", "" })
	local b = assert(results.find_buf(snapshots.b))
	eq(vim.api.nvim_buf_get_lines(b, 0, -1, true), { "SELECT 2;", "", "two" })
end

T["makes every result buffer read only while still rendering"] = function()
	local a = results.render(snapshots.a, "SELECT a\nFROM t;", "one")
	local b = results.render(snapshots.b, "SELECT 2;", "two")

	eq(vim.api.nvim_buf_get_lines(a, 0, -1, true), { "SELECT a", "FROM t;", "", "one" })
	eq(vim.bo[a].modifiable, false)
	eq(vim.bo[b].modifiable, false)
end

T["only toggles and closes the requested session"] = function()
	local a = results.open(snapshots.a)
	local b = results.open(snapshots.b)

	eq(results.toggle(snapshots.a), true)
	eq(results.find_win(a), nil)
	eq(results.find_win(b) ~= nil, true)

results.close(snapshots.b)
	eq(results.find_win(b), nil)
	eq(vim.api.nvim_buf_is_valid(a), true)
	eq(vim.api.nvim_buf_is_valid(b), true)
end

T["reports no result for a session that has none"] = function()
	eq(results.toggle(snapshots.a), false)
end

T["opens the requested split only once per session"] = function()
	local first = select(2, results.open(snapshots.a, { split = "vertical" }))
	local second = select(2, results.open(snapshots.a, { split = "horizontal" }))
	eq(first, second)
end

T["keeps two sessions on one connection in separate buffers"] = function()
	-- A new scratchpad and the fallback context share a connection but not an
	-- id: one buffer name for both would raise E95 on the second one.
	local fresh = vim.api.nvim_create_buf(false, true)
	assert(context.bind(fresh, "local_db", "test"))
	snapshots.c = context.snapshot(fresh)

	local a = results.open(snapshots.a)
	local c = results.open(snapshots.c)

	eq(snapshots.c.connection_name, snapshots.a.connection_name)
	eq(snapshots.c.id == snapshots.a.id, false)
	eq(a == c, false)
	eq(vim.api.nvim_buf_is_valid(c), true)
end

T["recovers its buffer after the module state is lost"] = function()
	-- Reloading the plugin empties state.buffers, but its buffers outlive it.
	local first = results.open(snapshots.a)
	package.loaded["dbsh.results"] = nil
	local reloaded = require("dbsh.results")
	package.loaded["dbsh.results"] = results

	eq(reloaded.find_buf(snapshots.a), first)
	eq(reloaded.open(snapshots.a), first)
end

T["leaves no buffer behind when a session cannot be named"] = function()
	local before = #vim.api.nvim_list_bufs()
	local taken = { id = snapshots.a.id .. ":clash", connection_name = "local_db" }
	local clash = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(
		clash,
		vim.fs.joinpath(vim.fn.getcwd(), "__DBSH__ local_db #" .. vim.fn.sha256(taken.id):sub(1, 8))
	)

	eq(pcall(results.open, taken), false)
	-- The clash buffer above, and nothing else: no half-built leftover.
	eq(#vim.api.nvim_list_bufs(), before + 1)
	vim.api.nvim_buf_delete(clash, { force = true })
end

T["opens a floating window when asked"] = function()
	local _, win = results.open(snapshots.a, { split = "float" })
	eq(vim.api.nvim_win_get_config(win).relative, "editor")
end

return T
