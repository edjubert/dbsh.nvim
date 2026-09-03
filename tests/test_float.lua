local helpers = dofile("tests/helpers.lua")
local eq = helpers.eq

local float = require("psql.float")

local T = MiniTest.new_set({
	hooks = {
		post_case = function()
			for _, win in ipairs(vim.api.nvim_list_wins()) do
				local config = vim.api.nvim_win_get_config(win)
				if config.relative ~= "" then
					pcall(vim.api.nvim_win_close, win, true)
				end
			end
		end,
	},
})

T["converts telescope borderchars into nvim_open_win order"] = function()
	-- telescope order: top, right, bottom, left, tl, tr, br, bl.
	local borderchars = { "1", "2", "3", "4", "5", "6", "7", "8" }
	local border = float.border_from_telescope(borderchars)
	eq(border, { "5", "1", "6", "2", "7", "3", "8", "4" })
end

T["falls back to rounded border on malformed borderchars"] = function()
	eq(float.border_from_telescope(nil), "rounded")
	eq(float.border_from_telescope({ "1", "2" }), "rounded")
end

T["falls back to sane defaults when telescope is not installed"] = function()
	-- The test environment never has telescope on the runtimepath.
	local style = float.style()
	eq(style.border, "rounded")
	eq(style.winblend, 0)
	eq(style.width, 0.8)
	eq(style.height, 0.8)
end

T["opens a centered floating window"] = function()
	local buf = vim.api.nvim_create_buf(false, true)
	local win = float.open(buf)
	local config = vim.api.nvim_win_get_config(win)
	eq(config.relative, "editor")
	eq(vim.api.nvim_win_get_buf(win), buf)
end

T["focuses the window by default"] = function()
	local buf = vim.api.nvim_create_buf(false, true)
	local win = float.open(buf)
	eq(vim.api.nvim_get_current_win(), win)
end

T["does not steal focus when asked not to"] = function()
	local before = vim.api.nvim_get_current_win()
	local buf = vim.api.nvim_create_buf(false, true)
	float.open(buf, { focus = false })
	eq(vim.api.nvim_get_current_win(), before)
end

T["q closes the floating window"] = function()
	local buf = vim.api.nvim_create_buf(false, true)
	local win = float.open(buf)
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("q", true, true, true), "x", false)
	eq(vim.api.nvim_win_is_valid(win), false)
end

return T
