local helpers = dofile("tests/helpers.lua")
local eq = helpers.eq

local csv = require("psql.csv")

local T = MiniTest.new_set()

-- The rendering psql produces with linestyle unicode and border 2.
local TABLE_LINES = {
	"┌────┬───────┐",
	"│ id │ name  │",
	"├────┼───────┤",
	"│  1 │ alice │",
	"└────┴───────┘",
}

T["splits a rendered row into trimmed cells"] = function()
	local cells = csv.split_cells("│ id │ name  │")
	eq(#cells, 2)
	eq(cells[1].text, "id")
	eq(cells[2].text, "name")
end

T["reports the byte range of each cell"] = function()
	local cells = csv.split_cells("│ id │ name  │")
	eq(cells[1].from, 4)
	eq(cells[1].to, 7)
	eq(cells[2].from, 11)
	eq(cells[2].to, 17)
end

T["yields no cell for a frame line"] = function()
	eq(csv.split_cells("├────┼───────┤"), {})
	eq(csv.split_cells("SELECT 1;"), {})
end

T["keeps only the cells intersecting a column range"] = function()
	local cells = csv.split_cells("│ id │ name  │")
	local kept = csv.cells_in_range(cells, 11, 17)
	eq(#kept, 1)
	eq(kept[1].text, "name")
end

T["keeps both cells when the range straddles them"] = function()
	local cells = csv.split_cells("│ id │ name  │")
	eq(#csv.cells_in_range(cells, 6, 12), 2)
end

T["builds every column in linewise mode"] = function()
	eq(csv.rows_from_lines(TABLE_LINES, csv.LINEWISE), {
		{ "id", "name" },
		{ "1", "alice" },
	})
end

T["limits rows to the block columns in blockwise mode"] = function()
	eq(csv.rows_from_lines(TABLE_LINES, csv.BLOCKWISE, 11, 17), {
		{ "name" },
		{ "alice" },
	})
end

T["leaves a plain field untouched"] = function()
	eq(csv.escape_field("alice", ","), "alice")
end

T["quotes a field holding the delimiter"] = function()
	eq(csv.escape_field("a,b", ","), '"a,b"')
end

T["ignores a character that is not the delimiter"] = function()
	eq(csv.escape_field("a,b", ";"), "a,b")
end

T["doubles inner quotes"] = function()
	eq(csv.escape_field('say "hi"', ","), '"say ""hi"""')
end

T["joins rows and fields"] = function()
	eq(csv.to_csv({ { "id", "name" }, { "1", "alice" } }, ","), "id,name\n1,alice")
end

T["honours a custom delimiter"] = function()
	eq(csv.to_csv({ { "id", "name" } }, ";"), "id;name")
end

return T
