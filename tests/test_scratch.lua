local helpers = dofile("tests/helpers.lua")
local eq, expect_match = helpers.eq, helpers.expect_match

local config = require("dbsh.config")
local context = require("dbsh.context")
local results = require("dbsh.results")
local scratch = require("dbsh.scratch")

local original_data_dir
local original_rename
local root

local function metadata(id, extra)
	return vim.tbl_deep_extend("force", {
		version = 1,
		id = id,
		name = id,
		backend = "postgres",
		connection_name = "local_db",
		levels = { database = "postgres" },
		project_root = nil,
	}, extra or {})
end

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			config.setup({
				connections = {
					local_db = {
						host = "localhost",
						port = 5432,
						database = "postgres",
						username = "dev",
						password = "never-persisted",
					},
					staging = { host = "db.example.com", port = 5432, database = "app", username = "readonly" },
				},
				default = "local_db",
			})
			context.setup()
			root = vim.fn.tempname()
			original_data_dir = scratch._data_dir
			original_rename = scratch._rename
			scratch._data_dir = function() return vim.fs.joinpath(root, "scratchpads") end
		end,
		post_case = function()
			scratch._data_dir = original_data_dir
			scratch._rename = original_rename
			vim.fn.delete(root, "rf")
		end,
	},
})

T["stores paired SQL and metadata files under the scratchpad catalog"] = function()
	local sql, json = scratch.paths("pad-1")
	eq(sql, vim.fs.joinpath(root, "scratchpads", "pad-1.sql"))
	eq(json, vim.fs.joinpath(root, "scratchpads", "pad-1.json"))
end

T["creates public JSON metadata without copying profile credentials"] = function()
	local item = assert(scratch.create(metadata("pad-1", {
		name = "Monthly reconciliation",
		levels = { database = "warehouse", schema = "reporting" },
		project_root = "/work/project",
	})))
	local sql, json = scratch.paths(item.id)
	local decoded = vim.json.decode(table.concat(vim.fn.readfile(json), "\n"))

	eq(vim.fn.filereadable(sql), 1)
	eq(decoded, metadata("pad-1", {
		name = "Monthly reconciliation",
		levels = { database = "warehouse", schema = "reporting" },
		project_root = "/work/project",
	}))
	eq(table.concat(vim.fn.readfile(json), "\n"):find("never%-persisted"), nil)
end

T["reads metadata and lists scratchpads by display name"] = function()
	assert(scratch.create(metadata("zulu", { name = "Zulu" })))
	assert(scratch.create(metadata("alpha", { name = "Alpha" })))

	local opened = assert(scratch.read("zulu"))
	eq(opened.name, "Zulu")

	local items = scratch.list()
	eq(vim.tbl_map(function(item) return item.id end, items), { "alpha", "zulu" })
end

T["keeps malformed and missing sidecars as visible, non-fatal catalog entries"] = function()
	local missing_sql = scratch.paths("missing")
	vim.fn.mkdir(scratch.dir(), "p")
	vim.fn.writefile({}, missing_sql)

	local broken_sql, broken_json = scratch.paths("broken")
	vim.fn.writefile({}, broken_sql)
	vim.fn.writefile({ "{" }, broken_json)

	local items = scratch.list()
	eq(#items, 2)
	eq(items[1].metadata, nil)
	expect_match(items[1].error, "metadata")
	eq(items[2].metadata, nil)
	expect_match(items[2].error, "metadata")
end

T["writes metadata atomically without replacing the previous file on rename failure"] = function()
	assert(scratch.write_metadata(metadata("pad-1", { name = "Before" })))
	local _, json = scratch.paths("pad-1")
	local before = table.concat(vim.fn.readfile(json), "\n")

	scratch._rename = function() return nil, "rename failed" end
	local ok, err = scratch.write_metadata(metadata("pad-1", { name = "After" }))

	eq(ok, nil)
	expect_match(err, "rename failed")
	eq(table.concat(vim.fn.readfile(json), "\n"), before)
end

T["reopens independent scratchpad contexts from persisted metadata"] = function()
	assert(scratch.create(metadata("alpha", {
		levels = { database = "warehouse", schema = "reporting" },
		project_root = "/work/alpha",
	})))
	assert(scratch.create(metadata("beta", {
		connection_name = "staging",
		levels = { database = "app" },
		project_root = nil,
	})))

	local alpha_path = scratch.open("alpha")
	local alpha_buf = vim.api.nvim_get_current_buf()
	local alpha_snapshot = context.snapshot(alpha_buf)
	vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(true, true))
	local beta_path = scratch.open("beta")
	local beta_snapshot = context.snapshot(0)
	local alpha_result = results.render(alpha_snapshot, "SELECT 'alpha';", "alpha")
	local beta_result = results.render(beta_snapshot, "SELECT 'beta';", "beta")
	assert(context.set_level(alpha_buf, "schema", "updated", "test"))

	eq(alpha_path, scratch.paths("alpha"))
	eq(beta_path, scratch.paths("beta"))
	eq(alpha_snapshot.kind, "scratchpad")
	eq(alpha_snapshot.id == beta_snapshot.id, false)
	eq(alpha_result == beta_result, false)
	eq(alpha_snapshot.levels, { database = "warehouse", schema = "reporting" })
	eq(alpha_snapshot.project_root, "/work/alpha")
	eq(beta_snapshot.connection_name, "staging")
	eq(beta_snapshot.project_root, nil)
	eq(assert(scratch.read("alpha")).levels.schema, "updated")

	vim.api.nvim_buf_delete(alpha_result, { force = true })
	vim.api.nvim_buf_delete(beta_result, { force = true })
end

T["migrates a legacy scratchpad only when explicitly requested"] = function()
	local legacy = scratch.legacy_path("local_db")
	vim.fn.mkdir(vim.fs.dirname(legacy), "p")
	vim.fn.writefile({ "SELECT 1;" }, legacy)

	local item = assert(scratch.migrate_legacy("local_db"))
	local sql, json = scratch.paths(item.id)

	eq(vim.fn.readfile(legacy), { "SELECT 1;" })
	eq(vim.fn.readfile(sql), { "SELECT 1;" })
	eq(vim.json.decode(table.concat(vim.fn.readfile(json), "\n")).connection_name, "local_db")
end

return T
