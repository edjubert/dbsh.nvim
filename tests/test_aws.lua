local helpers = dofile("tests/helpers.lua")
local eq, expect_match = helpers.eq, helpers.expect_match
local aws = require("dbsh.aws")

local original_runner
local original_home

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			aws.clear()
			original_runner = aws.runner
			original_home = aws._home
		end,
		post_case = function()
			aws.runner = original_runner
			aws._home = original_home
			aws.clear()
		end,
	},
})

local function write_file(path, content)
	local f = assert(io.open(path, "w"))
	f:write(content)
	f:close()
end

local function fake_sso_cache(tmpdir, start_url, region, token)
	vim.fn.mkdir(tmpdir .. "/.aws/sso/cache", "p")
	local config_content = "[profile test]\n"
		.. "sso_start_url = " .. start_url .. "\n"
		.. "sso_region = " .. region .. "\n"
		.. "sso_account_id = 123456789012\n"
		.. "sso_role_name = test-role\n"
		.. "\n[profile other]\n"
		.. "sso_start_url = https://other.awsapps.com/start\n"
	write_file(tmpdir .. "/.aws/config", config_content)
	local cache_content = vim.json.encode({
		startUrl = start_url,
		region = region,
		accessToken = token,
		expiresAt = "2099-01-01T00:00:00Z",
	})
	write_file(tmpdir .. "/.aws/sso/cache/abc123.json", cache_content)
	aws._home = function() return tmpdir end
end

T["rejects invalid arguments"] = function()
	local err
	aws.resolve("", "profile", "123", "role", {}, function(_, e) err = e end)
	expect_match(err, "credential key must be a non%-empty string")

	err = nil
	aws.resolve("key", "", "123", "role", {}, function(_, e) err = e end)
	expect_match(err, "profile must be a non%-empty string")

	err = nil
	aws.resolve("key", "profile", "", "role", {}, function(_, e) err = e end)
	expect_match(err, "account_id must be a non%-empty string")

	err = nil
	aws.resolve("key", "profile", "123", "", {}, function(_, e) err = e end)
	expect_match(err, "role_name must be a non%-empty string")
end

T["reports missing SSO session without leaking details"] = function()
	aws._home = function() return "/nonexistent-home-aws-test" end
	local err
	aws.resolve("key", "no-such-profile", "123", "role", {}, function(_, e) err = e end)
	expect_match(err, "no valid SSO session")
	expect_match(err, "aws sso login")
end

T["resolves and caches credentials from SSO"] = function()
	local tmpdir = vim.fn.tempname()
	fake_sso_cache(tmpdir, "https://example.awsapps.com/start", "eu-west-1", "test-token-123")

	local calls = 0
	aws.runner = function(argv, _, callback)
		calls = calls + 1
		eq(argv[1], "aws")
		eq(argv[2], "sso")
		eq(argv[3], "get-role-credentials")
		eq(vim.tbl_contains(argv, "test-token-123"), true)
		eq(vim.tbl_contains(argv, "123456789012"), true)
		eq(vim.tbl_contains(argv, "test-role"), true)
		callback({
			code = 0,
			stdout = vim.json.encode({
				roleCredentials = {
					accessKeyId = "AKIAEXAMPLE",
					secretAccessKey = "secret",
					sessionToken = "token",
					expiration = 9999999999999,
				},
			}),
		})
		return { kill = function() end }
	end

	local creds, err
	aws.resolve("key", "test", "123456789012", "test-role", {}, function(c, e)
		creds, err = c, e
	end)
	eq(err, nil)
	eq(creds.access_key_id, "AKIAEXAMPLE")
	eq(creds.secret_access_key, "secret")
	eq(creds.session_token, "token")
	eq(calls, 1)

	-- Second call should hit the cache (callback is scheduled)
	local creds2
	aws.resolve("key", "test", "123456789012", "test-role", {}, function(c, e)
		creds2, err = c, e
	end)
	vim.wait(200, function() return creds2 ~= nil end)
	eq(creds2.access_key_id, "AKIAEXAMPLE")
	eq(calls, 1)

	vim.fn.delete(tmpdir, "rf")
end

T["reports aws cli failure without leaking secrets"] = function()
	local tmpdir = vim.fn.tempname()
	fake_sso_cache(tmpdir, "https://example.awsapps.com/start", "eu-west-1", "test-token-123")

	aws.runner = function(_, _, callback)
		callback({ code = 1, stdout = "", stderr = "UnauthorizedException" })
		return { kill = function() end }
	end

	local creds, err
	aws.resolve("key", "test", "123456789012", "test-role", {}, function(c, e)
		creds, err = c, e
	end)
	eq(creds, nil)
	expect_match(err, "get%-role%-credentials failed")
	eq(err:find("test%-token%-123", 1, true), nil)
	eq(err:find("UnauthorizedException", 1, true), nil)

	vim.fn.delete(tmpdir, "rf")
end

T["reports unparseable aws output"] = function()
	local tmpdir = vim.fn.tempname()
	fake_sso_cache(tmpdir, "https://example.awsapps.com/start", "eu-west-1", "test-token-123")

	aws.runner = function(_, _, callback)
		callback({ code = 0, stdout = "not json", stderr = "" })
		return { kill = function() end }
	end

	local creds, err
	aws.resolve("key", "test", "123456789012", "test-role", {}, function(c, e)
		creds, err = c, e
	end)
	eq(creds, nil)
	expect_match(err, "could not parse")

	vim.fn.delete(tmpdir, "rf")
end

T["invalidate forces a fresh resolution"] = function()
	local tmpdir = vim.fn.tempname()
	fake_sso_cache(tmpdir, "https://example.awsapps.com/start", "eu-west-1", "test-token-123")

	local calls = 0
	aws.runner = function(_, _, callback)
		calls = calls + 1
		callback({
			code = 0,
			stdout = vim.json.encode({
				roleCredentials = {
					accessKeyId = "AKIA" .. calls,
					secretAccessKey = "secret",
					sessionToken = "token",
					expiration = 9999999999999,
				},
			}),
		})
		return { kill = function() end }
	end

	local creds
	aws.resolve("key", "test", "123456789012", "test-role", {}, function(c) creds = c end)
	eq(creds.access_key_id, "AKIA1")

	aws.invalidate("key")

	aws.resolve("key", "test", "123456789012", "test-role", {}, function(c) creds = c end)
	eq(creds.access_key_id, "AKIA2")
	eq(calls, 2)

	vim.fn.delete(tmpdir, "rf")
end

return T
