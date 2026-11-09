-- Builds an inventory from local state only. Branch loading belongs to the panel.

local config = require("dbsh.config")
local context = require("dbsh.context")
local catalog = require("dbsh.catalog")
local scratch = require("dbsh.scratch")

local M = {}

local function contract(backend, kind, key)
	for _, definition in ipairs(backend[kind] or {}) do
		if definition.key == key then
			return definition
		end
	end
end

local function identity(...)
	return vim.json.encode({ ... })
end

function M.build(source)
	local roots, nodes = {}, {}
	local function add(parent, id, kind, label, extra)
		if nodes[id] ~= nil then
			return nodes[id]
		end
		local node = vim.tbl_extend("force", {
			id = id, kind = kind, label = label, parent = parent and parent.id,
			children = {},
		}, extra or {})
		nodes[id] = node
		table.insert(parent and parent.children or roots, node)
		return node
	end

	local connections = add(nil, "connections", "section", "Connections", { branch = true })
	local pads = add(nil, "scratchpads", "section", "Scratchpads / files", { branch = true })
	local profiles = {}
	local function scoped(snapshot, database, schema)
		local copy = vim.deepcopy(snapshot)
		copy.levels.database, copy.connection.database = database, database
		copy.levels.schema, copy.connection.schema = schema, schema
		return copy
	end
	local function database(profile, name)
		if type(name) ~= "string" or name == "" then return end
		return add(profile.node, identity("database", profile.name, name), "database", name, {
			branch = true, snapshot = scoped(profile.snapshot, name, nil),
			request = contract(profile.backend, "contexts", "schema")
				or contract(profile.backend, "catalogs", "collections"),
		})
	end
	local function schema(profile, db, name)
		if db == nil or type(name) ~= "string" or name == "" then return end
		return add(db, identity("schema", profile.name, db.label, name), "schema", name, {
			branch = true, snapshot = scoped(profile.snapshot, db.label, name),
			request = contract(profile.backend, "catalogs", "relations"),
			scope = { schema = name, all_schemas = false },
		})
	end
	local function seed(name, levels)
		local profile = profiles[name]
		if profile == nil then return end
		local db = database(profile, levels.database)
		if profile.backend.name ~= "mongo" then schema(profile, db, levels.schema) end
	end

	for _, name in ipairs(config.names()) do
		local connection, err = config.connection(name)
		local backend = connection and config.backend_for(connection)
		local snapshot = vim.deepcopy(source)
		snapshot.connection_name, snapshot.connection = name, connection
		snapshot.backend_name = connection and (connection.type or "postgres")
		snapshot.levels = {}
		for _, key in ipairs({ "database", "schema", "role", "warehouse" }) do
			snapshot.levels[key] = connection and connection[key]
		end
		if source.connection_name == name and connection ~= nil then
			snapshot = vim.deepcopy(source)
		end
		local node = add(connections, identity("connection", name), "connection", name, {
			branch = true, snapshot = snapshot,
			request = backend and contract(backend, "contexts", "database"),
			error = err or (backend == nil and "backend unavailable" or nil),
		})
		if backend ~= nil then
			profiles[name] = { name = name, node = node, backend = backend, snapshot = snapshot }
			seed(name, connection)
			seed(name, snapshot.levels)
		end
	end
	for _, value in ipairs(context.list()) do seed(value.connection_name, value.levels) end

	local paths = {}
	local function pad_group(name)
		return add(pads, identity("pads", name or ""), "group", name or "No connection", { branch = true })
	end
	for _, item in ipairs(scratch.list()) do
		local metadata = item.metadata
		local path = metadata and scratch.paths(item.id, metadata.backend)
		if path ~= nil then paths[path] = true end
		if metadata ~= nil then seed(metadata.connection_name, metadata.levels) end
		local levels = metadata and metadata.levels or {}
		local location = levels.database or ""
		if levels.schema then location = location .. "." .. levels.schema end
		add(pad_group(metadata and metadata.connection_name), identity("pad", item.id), "scratchpad",
			(metadata and metadata.name or item.id) .. " [scratchpad]"
				.. (location ~= "" and " " .. location or ""), {
				scratchpad_id = item.id, path = path, error = item.error,
			})
	end
	for _, item in ipairs(scratch.legacy()) do
		paths[item.path] = true
		add(pad_group(item.connection_name), identity("legacy", item.path), "legacy",
			item.connection_name .. " [legacy scratchpad]", { connection_name = item.connection_name })
	end
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].buftype == "" and vim.bo[bufnr].buflisted then
			local snapshot = context.snapshot(bufnr)
			local backend = context.backend(snapshot)
			local filetype = vim.bo[bufnr].filetype
			local path = vim.api.nvim_buf_get_name(bufnr)
			if not paths[path] and snapshot.kind ~= "scratchpad"
				and (snapshot.kind == "buffer" or filetype == "sql"
					or (backend and backend.filetype == "javascript" and filetype == "javascript")) then
				seed(snapshot.connection_name, snapshot.levels)
				local label = path ~= "" and vim.fn.fnamemodify(path, ":~:.") or ("[unnamed " .. bufnr .. "]")
				add(pad_group(snapshot.connection_name), identity("file", bufnr), "file",
					label .. " [file]" .. (vim.bo[bufnr].modified and " [+]" or ""), { bufnr = bufnr })
			end
		end
	end
	add(pads, "new_scratchpad", "new", "New scratchpad…")

	-- Cache fragments retain their original filter and scope. Only an exact,
	-- unfiltered inventory can establish that a branch has been fully loaded.
	for name, profile in pairs(profiles) do
		for _, entry in ipairs(catalog.entries(profile.snapshot)) do
			local levels = entry.context.levels
			if levels.role == profile.snapshot.levels.role and levels.warehouse == profile.snapshot.levels.warehouse then
				local parent
				if entry.selector and entry.catalog == "database" then
					parent = profile.node
					for _, item in ipairs(entry.items) do database(profile, item.value or item.name) end
				elseif entry.selector and entry.catalog == "schema" then
					parent = database(profile, levels.database)
					for _, item in ipairs(entry.items) do schema(profile, parent, item.value or item.name) end
				elseif entry.catalog == "relations" or entry.catalog == "tables"
					or entry.catalog == "collections" or entry.catalog == "preview" then
					local db = database(profile, levels.database)
					parent = entry.scope.schema and schema(profile, db, entry.scope.schema) or db
					for _, item in ipairs(entry.items) do
						local object = type(item.value) == "table" and item.value or item
						local object_db = database(profile, object.database or levels.database)
						local owner = object.schema and schema(profile, object_db, object.schema) or object_db
						if owner ~= nil and type(object.name) == "string" then
							add(owner, identity("table", name, object.database or levels.database,
								object.schema or "", object.name), "table", object.name .. " ["
								.. (object.relkind and require("dbsh.backends.postgres").kind_label(object.relkind)
									or object.relation_type or object.type or object.kind or "table") .. "]", {
									item = item, snapshot = owner.snapshot,
									definition = contract(profile.backend, "catalogs", entry.catalog),
								})
						end
					end
				end
				if parent ~= nil then
					local definition = contract(profile.backend, entry.selector and "contexts" or "catalogs", entry.catalog)
					local snapshot = scoped(profile.snapshot, levels.database, levels.schema)
					local options = { scope = entry.scope, query = entry.query, relation = entry.relation, limit = entry.limit }
					if parent.request == definition and entry.query == "" and not entry.partial
						and (entry.selector or entry.scope.schema == parent.snapshot.levels.schema
							or profile.backend.name == "mongo") then
						parent.loaded = true
					end
					if entry.next_cursor ~= nil and definition ~= nil then
						options.cursor = entry.next_cursor
						add(parent, identity("more", entry.key), "more", "Load more…"
							.. (entry.query ~= "" and " (" .. entry.query .. ")" or ""), {
								snapshot = snapshot, request = definition, options = options,
							})
					end
				end
			end
		end
	end

	local function finish(node)
		if node.branch and node.request ~= nil and not node.loaded then
			local title = node.kind == "connection" and "databases" or node.kind == "schema" and "tables"
				or (node.request.key == "collections" and "collections" or "schemas")
			add(node, identity("load", node.id), "load", "Load " .. title .. "…", {
				request = node.request, snapshot = node.snapshot, options = { scope = node.scope },
			})
		elseif node.branch and #node.children == 0 then
			add(node, identity("empty", node.id), "empty", node.error or "No cached entries")
		end
		table.sort(node.children, function(a, b)
			local function rank(value)
				return (value.kind == "load" or value.kind == "more" or value.kind == "new" or value.kind == "empty") and 1 or 0
			end
			if rank(a) ~= rank(b) then return rank(a) < rank(b) end
			return a.label == b.label and a.id < b.id or a.label < b.label
		end)
		for _, child in ipairs(node.children) do finish(child) end
	end
	for _, node in ipairs(roots) do finish(node) end
	return roots, nodes
end

return M
