-- Telescope extension entry point.
-- This path is imposed by Telescope: load_extension("psql") looks for
-- lua/telescope/_extensions/psql.lua and nowhere else.

local ok, telescope = pcall(require, "telescope")
if not ok then
	return {}
end

-- Deferred requires: loading the pickers here would pull in psql.config
-- before the user had a chance to call setup().
return telescope.register_extension({
	exports = {
		connections = function()
			require("psql.telescope.pickers").connections()
		end,
		databases = function()
			require("psql.telescope.pickers").databases()
		end,
		schemas = function()
			require("psql.telescope.pickers").schemas()
		end,
		tables = function(opts)
			require("psql.telescope.pickers").tables(opts)
		end,
	},
})
