local helpers = dofile("tests/helpers.lua")
local eq, expect_match = helpers.eq, helpers.expect_match
local config = require("dbsh.config")
local context = require("dbsh.context")
local scratch = require("dbsh.scratch")
local preview = require("dbsh.telescope.scratch_preview")

local directory, original_dir, preview_buf, reads, highlights, previewer, source_buf
local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			directory = vim.fn.tempname()
			original_dir = scratch._data_dir
			scratch._data_dir = function() return directory end
			config.setup({
				connections = {
					pg = { host = "localhost", port = 5432, database = "postgres", username = "dev" },
					mongo = {
						type = "mongo", srv = true, host = "cluster.example.test", database = "analytics",
						username = "analyst", password_command = { "password-command" },
					},
				},
				default = "pg",
			})
			context.setup()
			preview_buf = vim.api.nvim_create_buf(false, true)
			source_buf = nil
			reads, highlights = {}, {}
			previewer = preview.new({
				previewers = { new_buffer_previewer = function(opts) return opts end },
				preview_utils = {
					highlighter = function(buf, filetype) table.insert(highlights, { buf, filetype }) end,
				},
				conf = {
					buffer_previewer_maker = function(path, buf, opts)
						table.insert(reads, path)
						-- Telescope invokes the hook after default extension detection.
						opts.ft = "sql"
						assert(opts.preview.filetype_hook(path, buf, opts))
						table.insert(highlights, { buf, opts.ft })
						vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.fn.readfile(path))
					end,
				},
			})
		end,
		post_case = function()
			scratch._data_dir = original_dir
			if source_buf and vim.api.nvim_buf_is_valid(source_buf) then
				vim.api.nvim_buf_delete(source_buf, { force = true })
			end
			for _, buf in ipairs(vim.api.nvim_list_bufs()) do
				if vim.api.nvim_buf_is_valid(buf) and
					(buf == preview_buf or vim.startswith(vim.api.nvim_buf_get_name(buf), directory)) then
					vim.api.nvim_buf_delete(buf, { force = true })
				end
			end
			vim.fn.delete(directory, "rf")
		end,
	},
})

local function create(id, backend, lines)
	local item = assert(scratch.create({ id = id, name = id, backend = backend, levels = {} }))
	local path = scratch.paths(id, backend)
	vim.fn.writefile(lines, path)
	return { id = id, metadata = item }, path
end

local function show(item)
	previewer.define_preview({ state = { bufnr = preview_buf } }, { value = item })
	return vim.api.nvim_buf_get_lines(preview_buf, 0, -1, false)
end

T["previews SQL and Mongo files with backend highlighting without opening them"] = function()
	local before = context.snapshot(0)
	for _, backend in ipairs({ "postgres", "snowflake", "mongo" }) do
		local lines = backend == "mongo" and { "db.users.find({})" } or { "SELECT 42;" }
		local item, path = create(backend, backend, lines)
		eq(previewer.get_buffer_by_name(nil, { value = item }), path)
		eq(show(item), lines)
		eq(highlights[#highlights][2], backend == "mongo" and "javascript" or "sql")
		-- Reading a preview never creates a loaded source buffer.
		eq(vim.fn.bufnr(path), -1)
	end
	eq(#reads, 3)
	eq(context.snapshot(0).id, before.id)
	eq(context.snapshot(0).generation, before.generation)
end

T["shows unsaved text from a loaded scratchpad without changing the source or disk"] = function()
	local item, path = create("unsaved", "mongo", { "db.users.find({ saved: true })" })
	local source = vim.api.nvim_create_buf(true, false)
	source_buf = source
	vim.api.nvim_buf_set_name(source, path)
	vim.api.nvim_buf_set_lines(source, 0, -1, false, { "db.users.find({ unsaved: true })" })
	vim.bo[source].modified = true
	eq(show(item), { "db.users.find({ unsaved: true })" })
	eq(#reads, 0)
	eq(highlights[1][2], "javascript")
	eq(vim.bo[source].modified, true)
	eq(vim.fn.readfile(path), { "db.users.find({ saved: true })" })
	eq(vim.api.nvim_buf_get_lines(source, 0, -1, false), { "db.users.find({ unsaved: true })" })
end

T["uses JavaScript for existing Mongo scratchpads still named sql"] = function()
	local item, path = create("old-mongo", "mongo", { "db.users.find({})" })
	local old_path = path:gsub("%.js$", ".sql")
	assert(vim.fn.rename(path, old_path) == 0)
	eq(show(item), { "db.users.find({})" })
	eq(reads[1], old_path)
	eq(highlights[1][2], "javascript")
end

T["previews legacy scratchpads with the configured connection language"] = function()
	local path = scratch.legacy_path("mongo")
	vim.fn.mkdir(vim.fs.dirname(path), "p")
	vim.fn.writefile({ "db.legacy.find({})" }, path)
	eq(show({ kind = "legacy", connection_name = "mongo", path = path }), { "db.legacy.find({})" })
	eq(highlights[1][2], "javascript")
	vim.fn.delete(path)
end

T["shows messages for creation and invalid metadata without reading files"] = function()
	expect_match(show({ kind = "new" })[1], "Create a named scratchpad")
	eq(show({ id = "broken", error = "invalid metadata" }), { "invalid metadata" })
	eq(#reads, 0)
end

T["handles missing files and empty scratchpads"] = function()
	local item, path = create("empty", "postgres", {})
	eq(show(item), { "" })
	vim.fn.delete(path)
	expect_match(show(item)[1], "missing or unreadable")
	eq(#reads, 1)
end

return T
