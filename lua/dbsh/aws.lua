-- Let the AWS CLI resolve profiles, including SSO and credential_process.
-- Exported credentials stay in memory; no bearer token is passed in argv.

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

function M.wall_now()
	return os.time() * 1000
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

local function parse_expiration(value)
	if type(value) ~= "string" then return nil end
	value = value:gsub("%+00:00$", "Z"):gsub("%.%d+Z$", "Z")
	local year, month, day, hour, minute, second = value:match(
		"^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)Z$"
	)
	if year == nil then return nil end
	year, month, day = tonumber(year), tonumber(month), tonumber(day)
	hour, minute, second = tonumber(hour), tonumber(minute), tonumber(second)
	if month < 1 or month > 12 or day < 1 or day > 31
		or hour > 23 or minute > 59 or second > 59 then return nil end
	-- UTC civil dates avoid extending a credential's lifetime through local DST.
	local adjusted_year = year - (month <= 2 and 1 or 0)
	local era = math.floor(adjusted_year / 400)
	local year_of_era = adjusted_year - era * 400
	local adjusted_month = month + (month > 2 and -3 or 9)
	local day_of_year = math.floor((153 * adjusted_month + 2) / 5) + day - 1
	local days = era * 146097 + year_of_era * 365 + math.floor(year_of_era / 4)
		- math.floor(year_of_era / 100) + day_of_year - 719468
	local timestamp = days * 86400 + hour * 3600 + minute * 60 + second
	if os.date("!%Y-%m-%dT%H:%M:%SZ", timestamp) ~= value then return nil end
	return timestamp * 1000
end

local function parse_credentials(stdout)
	local ok, parsed = pcall(vim.json.decode, stdout or "")
	if not ok or type(parsed) ~= "table" then return nil end
	if parsed.Version ~= 1 then return nil end
	if type(parsed.AccessKeyId) ~= "string" or parsed.AccessKeyId == "" then return nil end
	if type(parsed.SecretAccessKey) ~= "string" or parsed.SecretAccessKey == "" then return nil end
	if parsed.SessionToken ~= nil
		and (type(parsed.SessionToken) ~= "string" or parsed.SessionToken == "") then return nil end
	local expiration
	if parsed.Expiration ~= nil then
		expiration = parse_expiration(parsed.Expiration)
		if expiration == nil then return nil end
	end
	return {
		access_key_id = parsed.AccessKeyId,
		secret_access_key = parsed.SecretAccessKey,
		session_token = parsed.SessionToken,
		expiration = expiration,
	}
end

function M.resolve(key, profile, opts, callback)
	opts = opts or {}
	if type(key) ~= "string" or key == "" then
		callback(nil, "aws credential key must be a non-empty string")
		return nil
	end
	if type(profile) ~= "string" or profile == "" then
		callback(nil, "aws profile must be a non-empty string")
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

	local resolution_epoch = epoch
	local version = versions[key] or 0
	local argv = {
		"aws", "configure", "export-credentials",
		"--profile", profile, "--format", "process",
	}
	local ok, handle = pcall(M.runner, argv, { text = true, timeout = 30000 }, vim.schedule_wrap(function(result)
		if result == nil or result.code ~= 0 then
			callback(nil, "aws configure export-credentials failed for profile " .. profile
				.. "; check access and run aws sso login --profile " .. profile)
			return
		end

		local creds = parse_credentials(result.stdout)
		if creds == nil then
			callback(nil, "could not parse aws credentials for profile " .. profile)
			return
		end

		local remaining_ms = cache_ttl_ms
		if creds.expiration ~= nil then
			remaining_ms = math.min(remaining_ms, creds.expiration - M.wall_now())
			if remaining_ms <= 0 then
				callback(nil, "aws credentials have expired for profile " .. profile)
				return
			end
		end
		if epoch == resolution_epoch and (versions[key] or 0) == version then
			local expires_at = M.now() + remaining_ms
			cache[key] = {
				credentials = creds,
				expires_at = expires_at,
			}
			M._cache[key] = { expires_at = expires_at }
		end
		callback(creds, nil)
	end))
	if not ok then
		callback(nil, "aws configure export-credentials failed for profile " .. profile)
		return nil
	end
	return handle
end

return M
