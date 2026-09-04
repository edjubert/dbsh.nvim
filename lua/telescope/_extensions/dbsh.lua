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
		databases = function()
			require("dbsh.telescope.pickers").databases()
		end,
		schemas = function()
			require("dbsh.telescope.pickers").schemas()
		end,
		tables = function(opts)
			require("dbsh.telescope.pickers").tables(opts)
		end,
	},
})
