local helpers = dofile("tests/helpers.lua")
local eq, expect_match = helpers.eq, helpers.expect_match

local pickers = require("psql.telescope.pickers")

local T = MiniTest.new_set()

T["labels every supported relkind"] = function()
	eq(pickers.kind_label("r"), "table")
	eq(pickers.kind_label("v"), "view")
	eq(pickers.kind_label("m"), "matview")
	eq(pickers.kind_label("p"), "partitioned")
end

T["falls back to the raw relkind when unknown"] = function()
	eq(pickers.kind_label("x"), "x")
end

T["formats a table entry as schema.name with its kind"] = function()
	local entry = pickers.format_table_entry({ schema = "analytics", name = "events", kind = "v" })
	eq(entry.ordinal, "analytics.events")
	expect_match(entry.display, "analytics%.events")
	expect_match(entry.display, "view")
	eq(entry.value.name, "events")
end

T["reports a clear error when telescope is unavailable"] = function()
	local original = pickers._telescope
	pickers._telescope = function() return nil end

	local notified
	local original_notify = vim.notify
	vim.notify = function(msg) notified = msg end

	pickers.connections()

	vim.notify = original_notify
	pickers._telescope = original

	expect_match(notified, "telescope")
end

T["falls back to an input prompt when telescope is unavailable"] = function()
	local original_telescope = pickers._telescope
	local original_input = vim.ui.input
	pickers._telescope = function() return nil end

	local asked
	vim.ui.input = function(opts, cb)
		asked = opts
		cb("public.events")
	end

	local got
	pickers.variable("raw_data", { "analytics.events" }, function(value) got = value end)

	vim.ui.input = original_input
	pickers._telescope = original_telescope

	eq(got, "public.events")
	expect_match(asked.prompt, "raw_data")
	eq(asked.default, "analytics.events")
end

T["prefills the input with nothing when there is no history"] = function()
	local original_telescope = pickers._telescope
	local original_input = vim.ui.input
	pickers._telescope = function() return nil end

	local asked
	vim.ui.input = function(opts, cb)
		asked = opts
		cb(nil)
	end

	local got = "untouched"
	pickers.variable("raw_data", {}, function(value) got = value end)

	vim.ui.input = original_input
	pickers._telescope = original_telescope

	eq(asked.default, "")
	eq(got, nil)
end

T["reports a clear error path for every picker"] = function()
	-- variable() must never raise when telescope is missing, unlike the
	-- other pickers it degrades to a prompt rather than an error.
	local original = pickers._telescope
	pickers._telescope = function() return nil end
	local original_input = vim.ui.input
	vim.ui.input = function(_, cb) cb(nil) end

	local ok = pcall(pickers.variable, "raw_data", {}, function() end)

	vim.ui.input = original_input
	pickers._telescope = original
	eq(ok, true)
end

return T
