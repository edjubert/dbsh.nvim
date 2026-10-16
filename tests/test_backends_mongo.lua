local helpers = dofile("tests/helpers.lua")
local eq, expect_match = helpers.eq, helpers.expect_match
local credentials = require("dbsh.credentials")
local aws = require("dbsh.aws")
local mongo = require("dbsh.backends.mongo")

local function profile(overrides)
	local connection = {
		type = "mongo", srv = true, host = "cluster0.example.mongodb.net", username = "analyst",
		database = "analytics", auth_source = "admin", tls = true,
		proxy = { host = "127.0.0.1", port = 1080 },
		password_command = { "password-command", "--profile", "mongo" },
	}
	for key, value in pairs(overrides or {}) do
		if value == vim.NIL then connection[key] = nil else connection[key] = value end
	end
	return connection
end

local function aws_profile(overrides)
	local connection = {
		type = "mongo", srv = true, host = "cluster0.example.mongodb.net",
		username = "arn:aws:iam::123456789012:role/mongodb-read",
		database = "analytics", tls = true, auth = "aws",
		proxy = { host = "127.0.0.1", port = 1080 },
		aws_profile = "TestProfile",
		aws_account_id = "123456789012",
		aws_role_name = "mongodb-read",
	}
	for key, value in pairs(overrides or {}) do
		if value == vim.NIL then connection[key] = nil else connection[key] = value end
	end
	return connection
end

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			credentials.clear()
			aws.clear()
		end,
		post_case = function()
			credentials.clear()
			aws.clear()
		end,
	},
})

T["validates secure Mongo profiles"] = function()
	eq(mongo.validate(profile()), true)
	eq(mongo.validate(profile({ proxy = vim.NIL })), true)
	local valid, err = mongo.validate(profile({ proxy = { host = "localhost", port = 0 } }))
	eq(valid, nil)
	expect_match(err, "ssh %-D")
end

T["validates AWS Mongo profiles"] = function()
	eq(mongo.validate(aws_profile()), true)
	eq(mongo.validate(aws_profile({
		username = vim.NIL, aws_account_id = vim.NIL, aws_role_name = vim.NIL, proxy = vim.NIL,
	})), true)

	local valid, err = mongo.validate(aws_profile({ aws_profile = vim.NIL }))
	eq(valid, nil)
	expect_match(err, "aws_profile")

	valid, err = mongo.validate(aws_profile({ password_command = { "cmd" } }))
	eq(valid, nil)
	expect_match(err, "must not provide password_command")

	valid, err = mongo.validate(aws_profile({ auth = "oidc" }))
	eq(valid, nil)
	expect_match(err, "auth must be")
	valid, err = mongo.validate(aws_profile({ auth_source = "admin" }))
	eq(valid, nil)
	expect_match(err, "auth_source")
end

T["builds a safely encoded URI"] = function()
	local uri = mongo.uri(profile({ username = "a/b" }), "p@ss:w/rd?")
	expect_match(uri, "^mongodb%+srv://a%%2Fb:p%%40ss%%3Aw%%2Frd%%3F@")
	expect_match(uri, "proxyHost=127%.0%.0%.1")
end

T["builds a MONGODB-AWS URI without userinfo"] = function()
	local uri = mongo.uri(aws_profile(), nil)
	expect_match(uri, "^mongodb%+srv://cluster0%.example%.mongodb%.net/")
	eq(uri:find("arn", 1, true), nil)
	eq(uri:find("@", 1, true), nil)
	expect_match(uri, "authMechanism=MONGODB%-AWS")
	expect_match(uri, "authSource=%%24external")
end

T["supports direct Mongo connections without a proxy"] = function()
	local uri = mongo.uri(aws_profile({ proxy = vim.NIL }), nil)
	eq(uri:find("proxyHost", 1, true), nil)
	eq(uri:find("proxyPort", 1, true), nil)
end

T["builds a MONGODB-AWS URI with read preference"] = function()
	local uri = mongo.uri(aws_profile({ read_preference = "secondary" }), nil)
	expect_match(uri, "readPreference=secondary")
end

T["never puts the password in argv or environment"] = function()
	local argv = mongo.argv(profile(), "/dev/stdin", "pretty", { password = "s3cr3t" })
	eq(table.concat(argv, " "):find("s3cr3t"), nil)
	eq(mongo.env(profile(), {}, { password = "s3cr3t" }), {})
end

T["passes AWS credentials to mongosh environment"] = function()
	local runtime = {
		aws = {
			access_key_id = "AKIAEXAMPLE",
			secret_access_key = "secret",
			session_token = "token",
		},
	}
	local env = mongo.env(aws_profile(), {}, runtime)
	eq(env.AWS_ACCESS_KEY_ID, "AKIAEXAMPLE")
	eq(env.AWS_SECRET_ACCESS_KEY, "secret")
	eq(env.AWS_SESSION_TOKEN, "token")
	eq(env.AWS_PROFILE, nil)
	eq(mongo.argv(aws_profile(), "/dev/stdin"), {
		"env", "-u", "AWS_PROFILE", "-u", "AWS_DEFAULT_PROFILE",
		"mongosh", "--nodb", "--quiet", "--norc", "--file", "/dev/stdin",
	})
end

T["prepares AWS credentials through the selected CLI profile"] = function()
	local original = aws.runner
	local done, runtime, err
	aws.runner = function(argv, _, callback)
		eq(argv, {
			"aws", "configure", "export-credentials", "--profile", "TestProfile", "--format", "process",
		})
		callback({ code = 0, stdout = vim.json.encode({
			Version = 1, AccessKeyId = "private-key", SecretAccessKey = "private-secret",
			SessionToken = "private-token",
		}) })
		return { kill = function() end }
	end
	local ok, failure = pcall(function()
		mongo.prepare({ connection = aws_profile(), connection_name = "atlas" }, {}, function(r, e)
			runtime, err, done = r, e, true
		end)
		assert(vim.wait(500, function() return done end))
		eq(err, nil)
		eq(runtime.aws.access_key_id, "private-key")
		eq(aws._cache[runtime.credential_key] ~= nil, true)
		mongo.invalidate_credentials(aws_profile(), runtime.credential_key)
		eq(aws._cache[runtime.credential_key], nil)
	end)
	aws.runner = original
	assert(ok, failure)
end

T["does not pass AWS credentials for password auth"] = function()
	local env = mongo.env(profile(), {}, { password = "s3cr3t" })
	eq(env, {})
end

T["does not pass AWS credentials without runtime"] = function()
	local env = mongo.env(aws_profile(), {}, {})
	eq(env, {})
end

T["declares the Mongo runtime contract"] = function()
	eq(mongo.script_delivery, "stdin")
	eq(mongo.tabular, false)
	eq(vim.tbl_map(function(definition) return definition.command end, mongo.contexts), { "MongoDatabases" })
	eq(vim.tbl_map(function(definition) return definition.command end, mongo.catalogs), {
		"MongoCollections", "MongoIndexes", "MongoPreview",
	})
	eq(mongo.is_authentication_error("Authentication failed", ""), true)
	eq(mongo.is_authentication_error("", "MongoMissingCredentialsError: ..."), true)
end

T["composes pretty and raw mongosh scripts"] = function()
	local pretty = mongo.compose("db.users.find()", "pretty", profile(), { password = "s3cr3t" })
	expect_match(pretty, "Mongo%(")
	expect_match(pretty, "printjson%(")
	eq(pretty:find("EJSON.stringify", 1, true), nil)

	local raw = mongo.compose("db.users.find()", "raw", profile(), { password = "s3cr3t" })
	expect_match(raw, "EJSON%.stringify")
	expect_match(raw, "toArray")
end

T["executes asynchronous collection previews with a bounded result"] = function()
	if vim.fn.executable("node") == 0 then MiniTest.skip("Node.js is required to execute the generated JavaScript") end
	local name = 'branches."quoted"'
	local fixture = table.concat({
		"let db;",
		"const Mongo = async () => ({ getDB: () => ({ getCollection: name => {",
		"  if (name !== " .. vim.json.encode(name) .. ') throw new Error("wrong collection");',
		"  return { find: async (filter, projection, options = {}) => ({",
		"    toArray: async () => Array.from({ length: 25 }, (_, i) => ({ id: i })).slice(0, options.limit)",
		"  }) };",
		"} }) });",
		'const print = value => process.stdout.write(String(value) + "\\n");',
		"const printjson = value => print(JSON.stringify(value));",
		"const EJSON = { stringify: JSON.stringify };",
	}, "\n")
	for _, mode in ipairs({ "pretty", "raw" }) do
		local script = mongo.compose(mongo.preview_query({ name = name }, 3), mode, profile(), {})
		local result = vim.system({ "node" }, {
			text = true, stdin = fixture .. "\n" .. script, timeout = 5000,
		}):wait()
		eq(result.code, 0)
		eq(vim.json.decode(result.stdout), { { id = 0 }, { id = 1 }, { id = 2 } })
	end
end

T["composes AWS scripts without password in URI"] = function()
	local script = mongo.compose("db.users.find()", "pretty", aws_profile(), {
		aws = { access_key_id = "AKIA", secret_access_key = "s", session_token = "t" },
	})
	expect_match(script, "authMechanism=MONGODB%-AWS")
	eq(script:find("AKIA", 1, true), nil)
	eq(script:find("secret", 1, true), nil)
end

T["parses EJSON without echoing invalid output"] = function()
	local rows, err = mongo.parse_raw('[{"name":"ada"}]')
	eq(err, nil)
	eq(rows, { { name = "ada" } })
	rows, err = mongo.parse_raw("mongodb://analyst:s3cr3t@host")
	eq(rows, nil)
	expect_match(err, "could not be parsed")
	eq(err:find("s3cr3t", 1, true), nil)
end

T["classifies Mongo reads conservatively"] = function()
	eq(mongo.classify("db.users.find();"), { action = "run", reason = "read" })
	eq(mongo.classify("db.users.find().limit(1)").action, "run")
	eq(mongo.classify("db.users.deleteOne({})").action, "confirm")
	eq(mongo.classify("db.users.find().forEach(d => db.users.deleteOne(d))").action, "confirm")
	eq(mongo.classify("db.users.find(); db.users.drop()").reason, "multiple_statements")
	eq(mongo.classify('db.getCollection("a.b").find({}).limit(10)').action, "run")
	eq(mongo.classify('db.getCollection("a.b").getIndexes()').action, "run")
	eq(mongo.classify('db.getCollection("a.b").deleteMany({})').action, "confirm")
	eq(mongo.classify('other.getCollection("a.b").find({})').action, "confirm")
	eq(mongo.classify('db.getCollection(chooseName()).find({})').action, "confirm")
end

return T
