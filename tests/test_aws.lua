local helpers = dofile("tests/helpers.lua")
local eq, expect_match = helpers.eq, helpers.expect_match
local aws = require("dbsh.aws")

local original_runner, original_now, original_wall_now
local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			aws.clear()
			original_runner, original_now, original_wall_now = aws.runner, aws.now, aws.wall_now
			aws.now = function() return 1000 end
			aws.wall_now = function() return 1791972000000 end -- 2026-10-14T10:00:00Z
		end,
		post_case = function()
			aws.runner, aws.now, aws.wall_now = original_runner, original_now, original_wall_now
			aws.clear()
		end,
	},
})

local function exported(overrides)
	local value = {
		Version = 1, AccessKeyId = "AKIAEXAMPLE", SecretAccessKey = "private-secret",
		SessionToken = "private-token", Expiration = "2026-10-14T11:00:00Z",
	}
	for key, field in pairs(overrides or {}) do
		if field == vim.NIL then value[key] = nil else value[key] = field end
	end
	return vim.json.encode(value)
end

local function resolve(opts)
	local done, creds, err = false, nil, nil
	aws.resolve("key", "TestProfile", opts or {}, function(c, e)
		creds, err, done = c, e, true
	end)
	assert(vim.wait(500, function() return done end))
	return creds, err
end

T["rejects invalid arguments and TTL"] = function()
	local err
	aws.resolve("", "profile", {}, function(_, e) err = e end)
	expect_match(err, "credential key")
	aws.resolve("key", "", {}, function(_, e) err = e end)
	expect_match(err, "profile")
	aws.resolve("key", "profile", { cache_ttl_ms = -1 }, function(_, e) err = e end)
	expect_match(err, "TTL")
end

T["uses the AWS CLI profile without secrets in argv"] = function()
	aws.runner = function(argv, opts, callback)
		eq(argv, {
			"aws", "configure", "export-credentials", "--profile", "TestProfile", "--format", "process",
		})
		eq(opts.timeout, 30000)
		callback({ code = 0, stdout = exported() })
		return { kill = function() end }
	end
	local creds, err = resolve()
	eq(err, nil)
	eq(creds.access_key_id, "AKIAEXAMPLE")
	eq(creds.secret_access_key, "private-secret")
	eq(creds.session_token, "private-token")
	eq(creds.expiration, 1791975600000)
	eq(aws._cache.key, { expires_at = 901000 })
end

T["supports static credentials without token or expiration"] = function()
	aws.runner = function(_, _, callback)
		callback({ code = 0, stdout = exported({ SessionToken = vim.NIL, Expiration = vim.NIL }) })
	end
	local creds, err = resolve()
	eq(err, nil)
	eq(creds.session_token, nil)
	eq(creds.expiration, nil)
end

T["does not retain credentials beyond AWS expiration"] = function()
	local calls = 0
	aws.runner = function(_, _, callback)
		calls = calls + 1
		callback({ code = 0, stdout = exported({ Expiration = "2026-10-14T10:00:02+00:00" }) })
	end
	resolve()
	eq(aws._cache.key.expires_at, 3000)
	resolve()
	eq(calls, 1)
	aws.now = function() return 3000 end
	resolve()
	eq(calls, 2)
end

T["rejects expired and malformed credentials"] = function()
	for _, output in ipairs({
		"not json",
		exported({ Version = 2 }),
		exported({ SecretAccessKey = vim.NIL }),
		exported({ Expiration = "invalid-date" }),
		exported({ Expiration = "2026-02-30T10:00:00Z" }),
		exported({ Expiration = "2026-10-14T09:00:00Z" }),
	}) do
		aws.runner = function(_, _, callback) callback({ code = 0, stdout = output }) end
		local creds, err = resolve()
		eq(creds, nil)
		eq(type(err), "string")
		eq(aws._cache.key, nil)
	end
end

T["reports CLI failures without echoing credentials"] = function()
	aws.runner = function(_, _, callback)
		callback({ code = 1, stdout = exported(), stderr = "ForbiddenException private-secret private-token" })
	end
	local creds, err = resolve()
	eq(creds, nil)
	expect_match(err, "export%-credentials failed")
	expect_match(err, "aws sso login")
	eq(err:find("private", 1, true), nil)
	eq(err:find("ForbiddenException", 1, true), nil)
end

T["reports a missing CLI without echoing thrown errors"] = function()
	aws.runner = function() error("private-secret") end
	local creds, err = resolve()
	eq(creds, nil)
	expect_match(err, "export%-credentials failed")
	eq(err:find("private", 1, true), nil)
end

T["invalidate forces a fresh resolution"] = function()
	local calls = 0
	aws.runner = function(_, _, callback)
		calls = calls + 1
		callback({ code = 0, stdout = exported({ AccessKeyId = "AKIA" .. calls }) })
	end
	eq(resolve().access_key_id, "AKIA1")
	eq(resolve().access_key_id, "AKIA1")
	aws.invalidate("key")
	eq(resolve().access_key_id, "AKIA2")
end

T["invalidating an in-flight request prevents cache repopulation"] = function()
	local pending, done
	aws.runner = function(_, _, callback) pending = callback end
	aws.resolve("key", "TestProfile", {}, function() done = true end)
	aws.invalidate("key")
	pending({ code = 0, stdout = exported() })
	assert(vim.wait(500, function() return done end))
	eq(aws._cache.key, nil)
end

return T
