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

T["makes the result buffer read only"] = function()
	local buf = results.open()
	eq(vim.bo[buf].modifiable, false)
end

T["still renders into the read only buffer"] = function()
	local buf = results.render("SELECT 1;", "one")
	eq(vim.api.nvim_buf_get_lines(buf, 0, -1, true), { "SELECT 1;", "", "one" })
	eq(vim.bo[buf].modifiable, false)
end

T["renders a multi line query"] = function()
	local buf = results.render("SELECT a\nFROM t;", "one")
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, true)
	eq(lines, { "SELECT a", "FROM t;", "", "one" })
end

T["shows a running placeholder for a multi line query"] = function()
	local buf = results.running("SELECT a\nFROM t;")
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, true)
	eq(lines, { "# Running...", "SELECT a", "FROM t;", "" })
end

T["opens a horizontal split by default"] = function()
	local before = vim.api.nvim_win_get_width(0)
	local _, win = results.open()
	-- A horizontal split keeps the full window width.
	eq(vim.api.nvim_win_get_width(win), before)
end

T["opens a vertical split on request"] = function()
	local before = vim.api.nvim_win_get_width(0)
	local _, win = results.open({ split = "vertical" })
	-- A vertical split narrows both windows.
	eq(vim.api.nvim_win_get_width(win) < before, true)
end

T["only splits once, regardless of the direction asked afterwards"] = function()
	local first = select(2, results.open({ split = "vertical" }))
	local second = select(2, results.open({ split = "horizontal" }))
	eq(first, second)
end

return T
