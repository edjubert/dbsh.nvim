local helpers = dofile("tests/helpers.lua")
local eq, expect_match = helpers.eq, helpers.expect_match
local credentials = require("dbsh.credentials")
local mongo = require("dbsh.backends.mongo")

local function profile(overrides)
	local connection = {
		type = "mongo", srv = true, host = "cluster0.example.mongodb.net", username = "analyst",
		database = "analytics", auth_source = "admin", tls = true,
		proxy = { host = "127.0.0.1", port = 1080 },
		password_command = { "password-command", "--profile", "mongo" },
	}
	for key, value in pairs(overrides or {}) do connection[key] = value == vim.NIL and nil or value end
	return connection
end

local T = MiniTest.new_set({
	hooks = {
		pre_case = function() credentials.clear() end,
		post_case = function() credentials.clear() end,
	},
})

T["validates secure Mongo profiles"] = function()
	eq(mongo.validate(profile()), true)
	local valid, err = mongo.validate(profile({ proxy = vim.NIL }))
	eq(valid, nil)
	expect_match(err, "ssh %-D")
end

T["builds a safely encoded URI"] = function()
	local uri = mongo.uri(profile({ username = "a/b" }), "p@ss:w/rd?")
	expect_match(uri, "^mongodb%+srv://a%%2Fb:p%%40ss%%3Aw%%2Frd%%3F@")
	expect_match(uri, "proxyHost=127%.0%.0%.1")
end

T["never puts the password in argv or environment"] = function()
	local argv = mongo.argv(profile(), "/dev/stdin", "pretty", { password = "s3cr3t" })
	eq(table.concat(argv, " "):find("s3cr3t"), nil)
	eq(mongo.env(profile(), {}, { password = "s3cr3t" }), {})
end

T["declares the Mongo runtime contract"] = function()
	eq(mongo.script_delivery, "stdin")
	eq(mongo.tabular, false)
	eq(mongo.contexts, {})
	eq(mongo.catalogs, {})
	eq(mongo.is_authentication_error("Authentication failed", ""), true)
end

return T
