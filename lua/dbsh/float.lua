-- Floating window for the result buffer, styled after the user's telescope
-- config so it matches the pickers already used elsewhere in the plugin.

local M = {}

local DEFAULT_BORDER = "rounded"
local DEFAULT_WINBLEND = 0
local DEFAULT_WIDTH = 0.8
local DEFAULT_HEIGHT = 0.8

-- telescope orders borderchars top/right/bottom/left/tl/tr/br/bl.
-- nvim_open_win wants them tl/top/tr/right/br/bottom/bl/left.
function M.border_from_telescope(borderchars)
	if type(borderchars) ~= "table" or #borderchars < 8 then
		return DEFAULT_BORDER
	end
	local top, right, bottom, left, tl, tr, br, bl = unpack(borderchars)
	return { tl, top, tr, right, br, bottom, bl, left }
end

-- telescope's layout_config allows a function or a table with padding, which
-- this plugin does not reimplement: only a plain scalar ratio is honoured.
local function ratio(value, default)
	if type(value) == "number" then
		return value
	end
	return default
end

-- Reads border, winblend and width/height ratios from telescope's config
-- when available, falling back to sane defaults otherwise.
function M.style()
	local ok, tconf = pcall(require, "telescope.config")
	if not ok then
		return {
			border = DEFAULT_BORDER,
			winblend = DEFAULT_WINBLEND,
			width = DEFAULT_WIDTH,
			height = DEFAULT_HEIGHT,
		}
	end

	local values = tconf.values
	local layout = values.layout_config or {}
	return {
		border = M.border_from_telescope(values.borderchars),
		-- winblend can be a function in some telescope themes; only a
		-- plain number is usable as a window option value here.
		winblend = ratio(values.winblend, DEFAULT_WINBLEND),
		width = ratio(layout.width, DEFAULT_WIDTH),
		height = ratio(layout.height, DEFAULT_HEIGHT),
	}
end

-- opts: { focus = boolean? }. Opens buf in a centered float and returns the
-- window. q and <Esc> close the window (buffer and content survive).
function M.open(buf, opts)
	opts = opts or {}
	local style = M.style()

	local columns = vim.o.columns
	local lines = vim.o.lines
	local width = math.floor(columns * style.width)
	local height = math.floor(lines * style.height)

	local win = vim.api.nvim_open_win(buf, opts.focus ~= false, {
		relative = "editor",
		style = "minimal",
		border = style.border,
		width = width,
		height = height,
		row = math.floor((lines - height) / 2),
		col = math.floor((columns - width) / 2),
	})
	vim.wo[win].winblend = style.winblend

	local function close()
		pcall(vim.keymap.del, "n", "q", { buffer = buf })
		pcall(vim.keymap.del, "n", "<Esc>", { buffer = buf })
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, false)
		end
	end
	vim.keymap.set("n", "q", close, { buffer = buf, nowait = true })
	vim.keymap.set("n", "<Esc>", close, { buffer = buf, nowait = true })

	return win
end

return M
