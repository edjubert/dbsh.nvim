local helpers = dofile("tests/helpers.lua")
local eq = helpers.eq

local history = require("psql.history")

-- Redirects the store into a throwaway directory for the whole file, so the
-- tests never touch the real stdpath("data").
local original_dir
local tmpdir

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			original_dir = history.dir
			tmpdir = vim.fn.tempname()
			vim.fn.mkdir(tmpdir, "p")
			history.dir = function() return tmpdir end
		end,
		post_case = function()
			history.dir = original_dir
			vim.fn.delete(tmpdir, "rf")
		end,
	},
})

T["stores one file per connection"] = function()
	eq(history.path("local_db"), vim.fs.joinpath(tmpdir, "local_db.json"))
end

T["falls back to a default name"] = function()
	eq(history.path(nil), vim.fs.joinpath(tmpdir, "default.json"))
end

T["loads an empty store when nothing was written"] = function()
	eq(history.load("local_db"), {})
	eq(history.values("local_db", "raw_data"), {})
end

T["records a value and reads it back"] = function()
	history.record("local_db", "raw_data", "public.events")
	eq(history.values("local_db", "raw_data"), { "public.events" })
end

T["puts the most recent value first and deduplicates"] = function()
	history.record("local_db", "raw_data", "public.events")
	history.record("local_db", "raw_data", "analytics.events")
	history.record("local_db", "raw_data", "public.events")
	eq(history.values("local_db", "raw_data"), { "public.events", "analytics.events" })
end

T["keeps connections apart"] = function()
	history.record("local_db", "raw_data", "public.events")
	history.record("staging", "raw_data", "analytics.events")
	eq(history.values("local_db", "raw_data"), { "public.events" })
	eq(history.values("staging", "raw_data"), { "analytics.events" })
end

T["survives a corrupted store"] = function()
	vim.fn.writefile({ "{ not json" }, history.path("local_db"))
	eq(history.load("local_db"), {})
end

return T
