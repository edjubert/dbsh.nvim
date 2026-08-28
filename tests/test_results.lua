local helpers = dofile("tests/helpers.lua")
local eq = helpers.eq

local results = require("psql.results")

local T = MiniTest.new_set({
	hooks = {
		post_case = function()
			local buf = results.find_buf()
			if buf ~= nil then
				vim.api.nvim_buf_delete(buf, { force = true })
			end
		end,
	},
})

T["creates a scratch buffer named __SQL__"] = function()
	local buf = results.open()
	eq(vim.api.nvim_buf_is_valid(buf), true)
	eq(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t"), "__SQL__")
	eq(vim.bo[buf].buftype, "nofile")
	eq(vim.bo[buf].filetype, "sql")
end

T["disables wrapping so wide tables scroll horizontally"] = function()
	local _, win = results.open()
	eq(vim.wo[win].wrap, false)
	eq(vim.wo[win].sidescrolloff, 0)
end

T["reuses the same buffer across calls"] = function()
	local first = results.open()
	local second = results.open()
	eq(first, second)
end

T["renders the query followed by the output"] = function()
	local buf = results.render("SELECT 1;", "one\ntwo")
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, true)
	eq(lines, { "SELECT 1;", "", "one", "two" })
end

T["shows a running placeholder"] = function()
	local buf = results.running("SELECT 1;")
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, true)
	eq(lines[1], "# Running...")
	eq(lines[2], "SELECT 1;")
end

T["replaces previous content on the next render"] = function()
	results.render("SELECT 1;", "one")
	local buf = results.render("SELECT 2;", "two")
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, true)
	eq(lines, { "SELECT 2;", "", "two" })
end

return T
