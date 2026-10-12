-- AWS SSO credential resolution for MONGODB-AWS authentication.
-- Reads the SSO access token from the AWS CLI cache, exchanges it for
-- temporary role credentials via `aws sso get-role-credentials`, and
-- caches the result in memory. Secrets never touch disk or error messages.

local M = {}

local default_cache_ttl_ms = 900000
local cache = {}
local versions = {}
local epoch = 0

M.runner = vim.system
M._cache = {}

function M.now()
	return vim.uv.now()
end

local function valid_cache_ttl(value)
	return type(value) == "number"
		and value > 0
		and value < math.huge
		and value == math.floor(value)
end

function M.invalidate(key)
	cache[key] = nil
	M._cache[key] = nil
	versions[key] = (versions[key] or 0) + 1
end

function M.clear()
	cache = {}
	M._cache = {}
	versions = {}
	epoch = epoch + 1
end

function M._home()
	return vim.fn.expand("~")
end

local function sso_cache_dir()
	return M._home() .. "/.aws/sso/cache"
end

local function read_profile_section(content, profile)
	local escaped = profile:gsub("%W", "%%%0")
	local pattern = "%[profile " .. escaped .. "%](.-)%["
	return content:match(pattern)
end

local function read_sso_access_token(profile)
	local config_path = M._home() .. "/.aws/config"
	local config_file = io.open(config_path, "r")
	if config_file == nil then return nil end
	local content = config_file:read("*a")
	config_file:close()

	local section = read_profile_section(content, profile)
	if section == nil then return nil end
	local start_url = section:match("sso_start_url%s*=%s*(%S+)")
	local sso_region = section:match("sso_region%s*=%s*(%S+)")
	if start_url == nil or sso_region == nil then return nil end

	local dir = io.open(sso_cache_dir(), "r")
	if dir == nil then return nil end
	dir:close()

	for entry in vim.fs.dir(sso_cache_dir()) do
		local path = sso_cache_dir() .. "/" .. entry
		local file = io.open(path, "r")
		if file ~= nil then
			local data = file:read("*a")
			file:close()
			local ok, parsed = pcall(vim.json.decode, data)
			if ok and type(parsed) == "table"
				and parsed.startUrl == start_url
				and parsed.region == sso_region
				and type(parsed.accessToken) == "string"
				and parsed.accessToken ~= "" then
				return parsed.accessToken, sso_region
			end
		end
	end
	return nil
end

local function parse_role_credentials(stdout)
	local ok, parsed = pcall(vim.json.decode, stdout or "")
	if not ok or type(parsed) ~= "table" then return nil end
	local creds = parsed.roleCredentials
	if type(creds) ~= "table" then return nil end
	if type(creds.accessKeyId) ~= "string" or creds.accessKeyId == "" then return nil end
	if type(creds.secretAccessKey) ~= "string" or creds.secretAccessKey == "" then return nil end
	if type(creds.sessionToken) ~= "string" or creds.sessionToken == "" then return nil end
	return {
		access_key_id = creds.accessKeyId,
		secret_access_key = creds.secretAccessKey,
		session_token = creds.sessionToken,
		expiration = creds.expiration,
	}
end

function M.resolve(key, profile, account_id, role_name, opts, callback)
	opts = opts or {}
	if type(key) ~= "string" or key == "" then
		callback(nil, "aws credential key must be a non-empty string")
		return nil
	end
	if type(profile) ~= "string" or profile == "" then
		callback(nil, "aws profile must be a non-empty string")
		return nil
	end
	if type(account_id) ~= "string" or account_id == "" then
		callback(nil, "aws account_id must be a non-empty string")
		return nil
	end
	if type(role_name) ~= "string" or role_name == "" then
		callback(nil, "aws role_name must be a non-empty string")
		return nil
	end

	local cache_ttl_ms = opts.cache_ttl_ms or default_cache_ttl_ms
	if not valid_cache_ttl(cache_ttl_ms) then
		callback(nil, "aws credential cache TTL must be a positive integer")
		return nil
	end

	local cached = cache[key]
	if cached ~= nil and M.now() < cached.expires_at then
		vim.schedule(function()
			callback(cached.credentials, nil)
		end)
		return nil
	end
	cache[key] = nil
	M._cache[key] = nil

	local access_token, sso_region = read_sso_access_token(profile)
	if access_token == nil then
		callback(nil, "no valid SSO session found for profile " .. profile .. "; run aws sso login --profile " .. profile)
		return nil
	end

	local resolution_epoch = epoch
	local version = versions[key] or 0
	local argv = {
		"aws", "sso", "get-role-credentials",
		"--access-token", access_token,
		"--account-id", account_id,
		"--role-name", role_name,
		"--region", sso_region or "eu-west-1",
	}
	local ok, handle = pcall(M.runner, argv, { text = true }, function(result)
		if result == nil or result.code ~= 0 then
			callback(nil, "aws sso get-role-credentials failed for profile " .. profile)
			return
		end

		local creds = parse_role_credentials(result.stdout)
		if creds == nil then
			callback(nil, "could not parse aws credentials for profile " .. profile)
			return
		end

		if epoch == resolution_epoch and (versions[key] or 0) == version then
			local expires_at = M.now() + cache_ttl_ms
			cache[key] = {
				credentials = creds,
				expires_at = expires_at,
			}
			M._cache[key] = { expires_at = expires_at }
		end
		callback(creds, nil)
	end)
	if not ok then
		callback(nil, "aws sso get-role-credentials failed for profile " .. profile)
		return nil
	end
	return handle
end

return M
