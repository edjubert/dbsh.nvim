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

return T
