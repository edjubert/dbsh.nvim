-- Credential helpers and in-memory resolution for database connections.

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

local function split_pgpass(line)
	local fields, wildcards, current, escaped, had_escape = {}, {}, {}, false, false
	for i = 1, #line do
		local char = line:sub(i, i)
		if escaped then
			current[#current + 1] = char
			escaped = false
		elseif char == "\\" then
			escaped = true
			had_escape = true
		elseif char == ":" and #fields < 4 then
			fields[#fields + 1] = table.concat(current)
			wildcards[#fields] = not had_escape and fields[#fields] == "*"
			current = {}
			had_escape = false
		else
			current[#current + 1] = char
		end
	end
	fields[#fields + 1] = table.concat(current)
	return fields, wildcards
end

--- Read the first matching password from PGPASSFILE or ~/.pgpass.
--- Returns nil and a sanitized error when no usable entry is available.
---@param connection table
---@return string? password
---@return string? error
function M.pgpass(connection)
	if type(connection) ~= "table"
		or type(connection.host) ~= "string" or connection.host == ""
		or type(connection.port) ~= "number" or connection.port <= 0
		or type(connection.database) ~= "string" or connection.database == ""
		or type(connection.username) ~= "string" or connection.username == "" then
		return nil, "pgpass requires host, port, database, and username"
	end

	local path = vim.env.PGPASSFILE
	if path == nil or path == "" then
		path = vim.fn.expand("~/.pgpass")
	end
	local stat = vim.uv.fs_stat(path)
	if stat == nil or stat.type ~= "file" then
		return nil, "pgpass file is missing or unreadable"
	end
	-- libpq ignores password files with any group or other permissions on Unix.
	if vim.fn.has("win32") ~= 1 and stat.mode % 64 ~= 0 then
		return nil, "pgpass file must not allow group or other access"
	end
	local ok, lines = pcall(vim.fn.readfile, path)
	if not ok then
		return nil, "pgpass file is missing or unreadable"
	end

	local expected = { connection.host, tostring(connection.port), connection.database, connection.username }
	for _, line in ipairs(lines) do
		if not line:match("^%s*#") then
			local fields, wildcards = split_pgpass(line)
			local matches = #fields == 5
			for i = 1, 4 do
				if not wildcards[i] and fields[i] ~= expected[i] then
					matches = false
					break
				end
			end
			if matches then
				if fields[5] == "" then
					return nil, "matching pgpass entry has an empty password"
				end
				return fields[5]
			end
		end
	end
	return nil, "no matching entry in pgpass file"
end

--- Build a macOS Keychain password command without executing it.
---@param service string
---@return string[]
function M.keychain(service)
	assert(type(service) == "string" and service ~= "", "keychain service must be a non-empty string")
	return { "security", "find-generic-password", "-s", service, "-w" }
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
