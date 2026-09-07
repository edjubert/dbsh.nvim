-- Telescope extension entry point.
-- This path is imposed by Telescope: load_extension("dbsh") looks for
-- lua/telescope/_extensions/dbsh.lua and nowhere else.

local ok, telescope = pcall(require, "telescope")
if not ok then
	return {}
end

-- Deferred requires: loading the pickers here would pull in dbsh.config
-- before the user had a chance to call setup().
return telescope.register_extension({
	exports = {
		connections = function()
			require("dbsh.telescope.pickers").connections()
		end,
		-- The catalog levels are declared by the backend, so there is nothing
		-- to name here: the caller says which level it wants.
		-- :lua require("telescope").extensions.dbsh.level({ index = 2 })
		level = function(opts)
			local index = tonumber(opts and (opts.index or opts.args)) or 1
			require("dbsh.telescope.pickers").level(index, {})
		end,
	},
})
