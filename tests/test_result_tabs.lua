local helpers = dofile("tests/helpers.lua")
local eq, expect_match = helpers.eq, helpers.expect_match

local config = require("dbsh.config")
local context = require("dbsh.context")
local results = require("dbsh.results")

local snapshot

local function headers(buf)
	local found = {}
	for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, true)) do
		if line:match("^%-%- query #") then
			table.insert(found, i)
		end
	end
	return found
end

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			config.setup({
				connections = {
					local_db = { host = "localhost", port = 5432, database = "postgres", username = "dev" },
				},
				default = "local_db",
				results_mode = "tabs",
			})
			context.setup()
			snapshot = context.snapshot(0)
		end,
		post_case = function()
			local buf = results.find_buf(snapshot)
			if buf ~= nil then
				vim.api.nvim_buf_delete(buf, { force = true })
			end
			snapshot = nil
		end,
	},
})

T["appends one section per query instead of overwriting"] = function()
	local buf = results.running(snapshot, "SELECT 1;")
	results.render(snapshot, "SELECT 1;", "one")
	results.running(snapshot, "SELECT 2;")
	results.render(snapshot, "SELECT 2;", "two")

	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, true)
	eq(#headers(buf), 2)
	expect_match(lines[1], "^%-%- query #1")
	eq(lines[2], "SELECT 1;")
	eq(lines[4], "one")
	expect_match(lines[5], "^%-%- query #2")
	eq(lines[6], "SELECT 2;")
	eq(lines[8], "two")
end

T["replaces only the running placeholder of the latest section"] = function()
	local buf = results.running(snapshot, "SELECT 1;")
	results.running(snapshot, "SELECT 2;")
	results.render(snapshot, "SELECT 2;", "two")

	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, true)
	-- The first query was superseded: its exec slot was cancelled and its
	-- callback never fires, so the placeholder is rewritten on the next run.
	eq(lines[4], "# Cancelled")
	eq(lines[8], "two")
	eq(vim.tbl_contains(lines, "# Running..."), false)
end

T["render without a preceding running appends a whole section"] = function()
	local buf = results.render(snapshot, "SELECT 1;", "one")
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, true)
	expect_match(lines[1], "^%-%- query #1")
	eq(lines, { lines[1], "SELECT 1;", "", "one" })
end

T["keeps the context snapshot available from the tab buffer"] = function()
	local buf = results.running(snapshot, "SELECT 1;")
	eq(results.context_snapshot(buf).id, snapshot.id)
	eq(vim.b[buf].dbsh_result_query, "SELECT 1;")
end

T["numbers sections across runs of one session"] = function()
	local buf = results.running(snapshot, "SELECT 1;")
	results.render(snapshot, "SELECT 1;", "one")
	results.running(snapshot, "SELECT 2;")
	results.render(snapshot, "SELECT 2;", "two")
	results.running(snapshot, "SELECT 3;")
	results.render(snapshot, "SELECT 3;", "three")
	local heads = headers(buf)
	eq(#heads, 3)
	expect_match(vim.api.nvim_buf_get_lines(buf, heads[3] - 1, heads[3], true)[1], "query #3")
end

T["folds every section and leaves only the newest one open"] = function()
	local buf = results.running(snapshot, "SELECT 1;")
	results.render(snapshot, "SELECT 1;", "one")
	results.running(snapshot, "SELECT 2;")
	results.render(snapshot, "SELECT 2;", "two")

	local win = assert(results.find_win(buf))
	vim.api.nvim_set_current_win(win)
	local heads = headers(buf)
	eq(#heads, 2)
	-- Older tab collapsed to its header line.
	eq(vim.fn.foldclosed(heads[1]), heads[1])
	eq(vim.fn.foldclosedend(heads[1]), heads[2] - 1)
	-- Newest tab open and revealed.
	eq(vim.fn.foldclosed(heads[2]), -1)
	eq(vim.api.nvim_win_get_cursor(win)[1], heads[2])
end

T["still opens the result window without stealing focus in a split"] = function()
	local before = vim.api.nvim_get_current_win()
	results.running(snapshot, "SELECT 1;", { split = "horizontal" })
	eq(vim.api.nvim_get_current_win(), before)
	results.render(snapshot, "SELECT 1;", "one", { split = "horizontal" })
	eq(vim.api.nvim_get_current_win(), before)
end

T["replace mode keeps overwriting the single section"] = function()
	config.setup({
		connections = { local_db = { host = "localhost", port = 5432, database = "postgres", username = "dev" } },
		default = "local_db",
		results_mode = "replace",
	})
	local buf = results.running(snapshot, "SELECT 1;")
	results.render(snapshot, "SELECT 1;", "one")
	results.running(snapshot, "SELECT 2;")
	results.render(snapshot, "SELECT 2;", "two")
	eq(vim.api.nvim_buf_get_lines(buf, 0, -1, true), { "SELECT 2;", "", "two" })
end

return T
