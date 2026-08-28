-- Minimal Neovim init used to run the test suite in headless mode.
-- Locates mini.test without depending on the user's plugin manager, and
-- vendors it into deps/ as a last resort so a fresh clone just works.

-- Never put a possibly-nil value inside a table literal walked by ipairs:
-- a nil at index 1 stops the iteration before the first real candidate.
local candidates = {
	vim.fn.stdpath("data") .. "/lazy/mini.test",
	vim.fn.stdpath("data") .. "/lazy/mini.nvim",
	vim.fn.stdpath("data") .. "/site/pack/vendor/start/mini.nvim",
	vim.fn.getcwd() .. "/deps/mini.test",
}

local from_env = os.getenv("MINI_TEST_DIR")
if from_env ~= nil and from_env ~= "" then
	table.insert(candidates, 1, from_env)
end

local mini_dir = nil
for _, dir in ipairs(candidates) do
	if vim.fn.isdirectory(dir) == 1 then
		mini_dir = dir
		break
	end
end

if mini_dir == nil then
	mini_dir = vim.fn.getcwd() .. "/deps/mini.test"
	vim.fn.mkdir(vim.fn.getcwd() .. "/deps", "p")
	local out = vim.fn.system({
		"git", "clone", "--filter=blob:none",
		"https://github.com/nvim-mini/mini.test", mini_dir,
	})
	if vim.v.shell_error ~= 0 then
		-- cquit, not error: a failing -u leaves headless nvim running forever
		-- because nothing ever reaches the command that would quit it.
		vim.api.nvim_err_writeln("failed to clone mini.test: " .. out)
		vim.cmd("cquit 1")
	end
end

vim.opt.runtimepath:append(mini_dir)
vim.opt.runtimepath:append(vim.fn.getcwd())

require("mini.test").setup()
