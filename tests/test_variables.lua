local helpers = dofile("tests/helpers.lua")
local eq = helpers.eq

local variables = require("psql.variables")

local T = MiniTest.new_set()

T["finds a declared variable"] = function()
	eq(variables.detect("SELECT * FROM :raw_data;", { ":(raw_data)" }), { "raw_data" })
end

T["reports a variable only once"] = function()
	local sql = "SELECT * FROM :raw_data JOIN :raw_data USING (id);"
	eq(variables.detect(sql, { ":(raw_data)" }), { "raw_data" })
end

T["keeps the order the variables appear in"] = function()
	local sql = "SELECT * FROM :second JOIN :first USING (id);"
	eq(variables.detect(sql, { ":(second)", ":(first)" }), { "second", "first" })
end

T["finds nothing without a pattern"] = function()
	eq(variables.detect("SELECT * FROM :raw_data;", {}), {})
	eq(variables.detect("SELECT * FROM :raw_data;", nil), {})
end

T["finds every name matched by a wide pattern"] = function()
	eq(
		variables.detect("SELECT :a FROM :b;", { ":([%w_]+)" }),
		{ "a", "b" }
	)
end

T["leaves a plain value untouched"] = function()
	eq(variables.escape_value("public.events"), "public.events")
end

T["escapes a single quote"] = function()
	eq(variables.escape_value("it's"), "it\\'s")
end

T["escapes a backslash before the quotes"] = function()
	eq(variables.escape_value("a\\b"), "a\\\\b")
end

T["builds a set directive"] = function()
	eq(variables.set_command("raw_data", "public.events"), "\\set raw_data 'public.events'")
end

T["builds an empty preamble when there is no variable"] = function()
	eq(variables.preamble({}, {}), "")
end

T["builds one directive per variable, in order"] = function()
	eq(
		variables.preamble({ "a", "b" }, { a = "1", b = "2" }),
		"\\set a '1'\n\\set b '2'\n"
	)
end

return T
