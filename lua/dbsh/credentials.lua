-- In-memory credential resolution for CLI-backed database connections.

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

local function valid_argv(argv)
	if type(argv) ~= "table" or #argv == 0 then
		return false
	end
	for _, value in ipairs(argv) do
		if type(value) ~= "string" or value == "" then
			return false
		end
	end
	return true
end

local function valid_cache_ttl(value)
	return type(value) == "number"
		and value > 0
		and value < math.huge
		and value == math.floor(value)
end

local function trim_terminal_newline(value)
	if value:sub(-2) == "\r\n" then
		return value:sub(1, -3)
	end
	if value:sub(-1) == "\n" then
		return value:sub(1, -2)
	end
	return value
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

function M.resolve(key, password_command, opts, callback)
	opts = opts or {}
	if type(key) ~= "string" or key == "" then
		callback(nil, "credential key must be a non-empty string")
		return nil
	end
	if not valid_argv(password_command) then
		callback(nil, "password_command must be a non-empty argv list")
		return nil
	end

	local cache_ttl_ms = opts.cache_ttl_ms or default_cache_ttl_ms
	if not valid_cache_ttl(cache_ttl_ms) then
		callback(nil, "credential cache TTL must be a positive integer")
		return nil
	end

	local cached = cache[key]
	if cached ~= nil and M.now() < cached.expires_at then
		vim.schedule(function()
			callback(cached.password, nil)
		end)
		return nil
	end
	cache[key] = nil
	M._cache[key] = nil

	local resolution_epoch = epoch
	local version = versions[key] or 0
	local ok, handle = pcall(M.runner, password_command, { text = true }, function(result)
		if result == nil or result.code ~= 0 then
			callback(nil, "password command failed")
			return
		end

		local password = trim_terminal_newline(result.stdout or "")
		if password == "" then
			callback(nil, "password command returned an empty value")
			return
		end

		if epoch == resolution_epoch and (versions[key] or 0) == version then
			local expires_at = M.now() + cache_ttl_ms
			cache[key] = {
				password = password,
				expires_at = expires_at,
			}
			M._cache[key] = { expires_at = expires_at }
		end
		callback(password, nil)
		password = nil
	end)
	if not ok then
		callback(nil, "password command failed")
		return nil
	end
	return handle
end

return M
