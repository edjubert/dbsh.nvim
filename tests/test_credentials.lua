local helpers = dofile("tests/helpers.lua")
local eq, expect_match = helpers.eq, helpers.expect_match

local credentials = require("dbsh.credentials")

local original_runner
local original_now
local now

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
			now = 1000
			credentials.now = function() return now end
		end,
		post_case = function()
			credentials.clear()
			credentials.runner = original_runner
			credentials.now = original_now
		end,
	},
})

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
