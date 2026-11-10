local helpers = dofile("tests/helpers.lua")
local eq, expect_match = helpers.eq, helpers.expect_match

local credentials = require("dbsh.credentials")

local original_runner
local original_now
local now
local original_pgpassfile
local original_expand
local pgpassfile

local connection = { host = "db.example.test", port = 5432, database = "analytics", username = "reader" }

local function write_pgpass(lines)
	vim.fn.writefile(lines, pgpassfile)
	assert(vim.uv.fs_chmod(pgpassfile, 384)) -- 0600
end

local function resolve(key, password_command, opts)
	local result
	credentials.resolve(key, password_command, opts, function(password, err)
		result = { password = password, err = err }
	end)
	vim.wait(200, function() return result ~= nil end)
	return result
end

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			credentials.clear()
			original_runner = credentials.runner
			original_now = credentials.now
			original_pgpassfile = vim.env.PGPASSFILE
			original_expand = vim.fn.expand
			pgpassfile = vim.fn.tempname()
			vim.env.PGPASSFILE = pgpassfile
			now = 1000
			credentials.now = function() return now end
		end,
		post_case = function()
			credentials.clear()
			credentials.runner = original_runner
			credentials.now = original_now
			vim.env.PGPASSFILE = original_pgpassfile
			vim.fn.expand = original_expand
			vim.fn.delete(pgpassfile)
		end,
	},
})

T["pgpass matches all four connection fields and skips comments and malformed lines"] = function()
	write_pgpass({
		"# db.example.test:5432:analytics:reader:comment-password",
		"malformed",
		"other.example.test:5432:analytics:reader:wrong-host",
		"db.example.test:5433:analytics:reader:wrong-port",
		"db.example.test:5432:postgres:reader:wrong-database",
		"db.example.test:5432:analytics:writer:wrong-user",
		"db.example.test:5432:analytics:reader:matched-password",
		"db.example.test:5432:analytics:reader:later-password",
	})
	local password, err = credentials.pgpass(connection)
	eq(password, "matched-password")
	eq(err, nil)
	eq(connection, { host = "db.example.test", port = 5432, database = "analytics", username = "reader" })
end

T["pgpass supports wildcards and preserves first-match order"] = function()
	for _, line in ipairs({
		"*:5432:analytics:reader:wildcard-password",
		"db.example.test:*:analytics:reader:wildcard-password",
		"db.example.test:5432:*:reader:wildcard-password",
		"db.example.test:5432:analytics:*:wildcard-password",
	}) do
		write_pgpass({ line, "db.example.test:5432:analytics:reader:exact-password" })
		eq(credentials.pgpass(connection), "wildcard-password")
	end
end

T["pgpass unescapes colons and backslashes in fields and passwords"] = function()
	write_pgpass({ "db\\:private:5432:analytics\\:2026:user\\\\name:fake\\:password\\\\tail" })
	eq(credentials.pgpass({
		host = "db:private", port = 5432, database = "analytics:2026", username = "user\\name",
	}), "fake:password\\tail")
end

T["pgpass treats an escaped star as a literal field instead of a wildcard"] = function()
	write_pgpass({
		"db.example.test:5432:analytics:\\*:literal-password",
		"db.example.test:5432:analytics:*:wildcard-password",
	})
	eq(credentials.pgpass(connection), "wildcard-password")
	local literal = vim.tbl_extend("force", connection, { username = "*" })
	eq(credentials.pgpass(literal), "literal-password")
end

T["pgpass honors PGPASSFILE and otherwise reads the home password file"] = function()
	write_pgpass({ "*:*:*:*:fixture-password" })
	vim.fn.expand = function(path)
		eq(path, "~/.pgpass")
		return pgpassfile
	end
	eq(credentials.pgpass(connection), "fixture-password")
	vim.env.PGPASSFILE = nil
	eq(credentials.pgpass(connection), "fixture-password")
	vim.env.PGPASSFILE = ""
	eq(credentials.pgpass(connection), "fixture-password")
end

T["pgpass returns sanitized failures without falling through an empty matching entry"] = function()
	local password, err = credentials.pgpass(connection)
	eq(password, nil)
	expect_match(err, "missing or unreadable")

	write_pgpass({ "db.example.test:5432:other:reader:private-password" })
	password, err = credentials.pgpass(connection)
	eq(password, nil)
	expect_match(err, "no matching entry")
	eq(err:find("private-password", 1, true), nil)

	write_pgpass({ "*:*:*:*:", "*:*:*:*:later-password" })
	password, err = credentials.pgpass(connection)
	eq(password, nil)
	expect_match(err, "empty password")

	password, err = credentials.pgpass({})
	eq(password, nil)
	expect_match(err, "requires host, port, database, and username")
end

T["pgpass ignores password files accessible to group or others on Unix"] = function()
	if vim.fn.has("win32") == 1 then return end
	write_pgpass({ "*:*:*:*:private-password" })
	assert(vim.uv.fs_chmod(pgpassfile, 420)) -- 0644
	local password, err = credentials.pgpass(connection)
	eq(password, nil)
	expect_match(err, "group or other access")
	assert(vim.uv.fs_chmod(pgpassfile, 256)) -- 0400 also satisfies libpq
	eq(credentials.pgpass(connection), "private-password")
end

T["keychain builds independent argv arrays without executing a command"] = function()
	credentials.runner = function() error("must not execute during construction") end
	local first = credentials.keychain("dbsh.snowflake.prod")
	local second = credentials.keychain("service with spaces; $(not-a-shell)")
	eq(first, { "security", "find-generic-password", "-s", "dbsh.snowflake.prod", "-w" })
	eq(second[4], "service with spaces; $(not-a-shell)")
	first[1] = "changed"
	eq(credentials.keychain("dbsh.snowflake.prod")[1], "security")
	for _, service in ipairs({ "", false, 123 }) do
		local ok, err = pcall(credentials.keychain, service)
		eq(ok, false)
		expect_match(err, "non%-empty string")
	end
end

T["rejects shell strings and malformed password commands"] = function()
	local result = resolve("profile", "security find-generic-password", { cache_ttl_ms = 100 })
	eq(result.password, nil)
	expect_match(result.err, "non%-empty argv")

	result = resolve("profile", { "security", "" }, { cache_ttl_ms = 100 })
	eq(result.password, nil)
	expect_match(result.err, "non%-empty argv")
end

T["trims one terminal newline and never exposes command output in errors"] = function()
	local fake_password = "fake-password"
	local calls = 0
	credentials.runner = function(argv, opts, callback)
		calls = calls + 1
		eq(argv, { "password-command" })
		eq(opts, { text = true })
		callback({ code = 0, stdout = fake_password .. "\n", stderr = "" })
	end

	local result = resolve("profile", { "password-command" }, { cache_ttl_ms = 100 })
	eq(calls, 1)
	eq(result.password, fake_password)
	eq(result.err, nil)
	eq(credentials._cache.profile.password, nil)

	credentials.invalidate("profile")
	credentials.runner = function(_, _, callback)
		callback({ code = 1, stdout = fake_password, stderr = fake_password })
	end
	result = resolve("profile", { "password-command" }, { cache_ttl_ms = 100 })
	eq(result.password, nil)
	expect_match(result.err, "password command failed")
	eq(result.err:find(fake_password, 1, true), nil)
end

T["rejects empty password command output"] = function()
	credentials.runner = function(_, _, callback)
		callback({ code = 0, stdout = "\n", stderr = "" })
	end

	local result = resolve("profile", { "password-command" }, { cache_ttl_ms = 100 })
	eq(result.password, nil)
	expect_match(result.err, "empty")
end

T["uses a cached credential asynchronously until the TTL expires"] = function()
	local calls = 0
	credentials.runner = function(_, _, callback)
		calls = calls + 1
		callback({ code = 0, stdout = "fake-password\n", stderr = "" })
	end

	local result = resolve("profile", { "password-command" }, { cache_ttl_ms = 100 })
	eq(result.password, "fake-password")
	eq(calls, 1)

	local cached
	credentials.resolve("profile", { "password-command" }, { cache_ttl_ms = 100 }, function(password, err)
		cached = { password = password, err = err }
	end)
	eq(cached, nil)
	vim.wait(200, function() return cached ~= nil end)
	eq(cached, { password = "fake-password", err = nil })
	eq(calls, 1)

	now = 1100
	result = resolve("profile", { "password-command" }, { cache_ttl_ms = 100 })
	eq(result.password, "fake-password")
	eq(calls, 2)
end

T["invalidates and clears cached credentials"] = function()
	local calls = 0
	credentials.runner = function(_, _, callback)
		calls = calls + 1
		callback({ code = 0, stdout = "fake-password\n", stderr = "" })
	end

	resolve("profile", { "password-command" }, { cache_ttl_ms = 100 })
	credentials.invalidate("profile")
	resolve("profile", { "password-command" }, { cache_ttl_ms = 100 })
	eq(calls, 2)

	credentials.clear()
	eq(next(credentials._cache), nil)
	resolve("profile", { "password-command" }, { cache_ttl_ms = 100 })
	eq(calls, 3)
end

return T
