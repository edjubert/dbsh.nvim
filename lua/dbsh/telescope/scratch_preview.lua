-- Scratchpad previews are copies: never open/bind the source buffer or run SQL.
local backends = require("dbsh.backends")
local config = require("dbsh.config")
local scratch = require("dbsh.scratch")

local M = {}

local function source(item)
	if item.kind == "new" then
		return nil, nil, "Create a named scratchpad and choose its connection."
	end
	if item.error then return nil, nil, item.error end
	local path, backend_name
	if item.kind == "legacy" then
		path = item.path or scratch.legacy_path(item.connection_name)
		local connection = config.connection(item.connection_name)
		backend_name = connection and connection.type or "postgres"
	else
		backend_name = item.metadata.backend
		path = scratch.paths(item.id, backend_name)
	end
	local backend = backends.get(backend_name)
	return path, backend and backend.filetype or "sql"
end

local function loaded_buffer(path)
	-- Neovim resolves path aliases (e.g. /var versus /private/var on macOS)
	-- when naming file buffers, so use its own lookup rather than string equality.
	local buf = vim.fn.bufnr(path)
	if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) then return buf end
end

function M.new(t)
	return t.previewers.new_buffer_previewer({
		title = "Scratchpad",
		get_buffer_by_name = function(_, entry)
			local path = source(entry.value)
			return path
		end,
		define_preview = function(self, entry)
			local path, filetype, message = source(entry.value)
			local buf = self.state.bufnr
			if path == nil then
				vim.api.nvim_buf_set_lines(buf, 0, -1, false, { message })
				return
			end
			local loaded = loaded_buffer(path)
			if loaded then
				vim.api.nvim_buf_set_lines(buf, 0, -1, false,
					vim.api.nvim_buf_get_lines(loaded, 0, -1, false))
				t.preview_utils.highlighter(buf, filetype)
				return
			end
			if vim.fn.filereadable(path) ~= 1 then
				vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Scratchpad file is missing or unreadable." })
				return
			end
			-- Telescope handles asynchronous reads, caching and size limits.
			-- Its default detection would color a legacy Mongo .sql file as SQL;
			-- the metadata determines the query language instead.
			t.conf.buffer_previewer_maker(path, buf, {
				bufname = self.state.bufname,
				winid = self.state.winid,
				use_ft_detect = false,
				preview = vim.tbl_extend("force", type(t.conf.preview) == "table" and t.conf.preview or {}, {
					filetype_hook = function(_, _, opts)
						opts.ft = filetype
						return true
					end,
				}),
			})
		end,
	})
end

return M
