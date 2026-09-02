local helpers = dofile("tests/helpers.lua")
local eq = helpers.eq

local config = require("psql.config")
local history = require("psql.history")
local resolve = require("psql.resolve")

local original_picker
local original_dir
local tmpdir

-- Replaces the picker with one that answers each variable from a table.
local function stub_answers(answers)
	resolve.picker = function()
		return {
			variable = function(name, _, callback)
				callback(answers[name])
			end,
		}
	end
end

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			config.setup({
				connections = {
					local_db = { host = "localhost", port = 5432, database = "postgres", username = "dev" },
				},
				default = "local_db",
				variable_patterns = { ":(raw_data)", ":(period)" },
			})
			original_picker = resolve.picker
			original_dir = history.dir
			tmpdir = vim.fn.tempname()
			vim.fn.mkdir(tmpdir, "p")
			history.dir = function() return tmpdir end
		end,
		post_case = function()
			resolve.picker = original_picker
			history.dir = original_dir
			vim.fn.delete(tmpdir, "rf")
		end,
	},
})

T["returns an empty preamble synchronously when there is no variable"] = function()
	local called = false
	local got = "untouched"
	resolve.preamble("SELECT 1;", function(preamble)
		called = true
		got = preamble
	end)
	-- Synchronous on purpose: the query path must be unchanged for anyone
	-- not using variables.
	eq(called, true)
	eq(got, "")
end

T["asks for each detected variable"] = function()
	stub_answers({ raw_data = "public.events" })
	local got
	resolve.preamble("SELECT * FROM :raw_data;", function(preamble) got = preamble end)
	vim.wait(500, function() return got ~= nil end)
	eq(got, "\\set raw_data 'public.events'\n")
end

T["chains several variables in order"] = function()
	stub_answers({ raw_data = "public.events", period = "2026-01" })
	local got
	resolve.preamble("SELECT * FROM :raw_data WHERE p = :period;", function(p) got = p end)
	vim.wait(500, function() return got ~= nil end)
	eq(got, "\\set raw_data 'public.events'\n\\set period '2026-01'\n")
end

T["cancels everything when a prompt is dismissed"] = function()
	stub_answers({ raw_data = "public.events", period = nil })
	local called = false
	local got = "untouched"
	resolve.preamble("SELECT * FROM :raw_data WHERE p = :period;", function(p)
		called = true
		got = p
	end)
	vim.wait(500, function() return called end)
	eq(got, nil)
end

T["records an accepted value in the history"] = function()
	stub_answers({ raw_data = "public.events" })
	local got
	resolve.preamble("SELECT * FROM :raw_data;", function(p) got = p end)
	vim.wait(500, function() return got ~= nil end)
	eq(history.values("local_db", "raw_data"), { "public.events" })
end

return T
