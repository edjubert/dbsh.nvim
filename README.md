# psql.nvim

Run PostgreSQL queries from Neovim, browse your schema with Telescope, and never
block the editor while a query runs.

Fork of [harrisoncramer/psql](https://github.com/harrisoncramer/psql), itself
forked from [mzarnitsa/psql](https://github.com/mzarnitsa/psql).

## What this fork changes

- **Asynchronous execution.** Queries run through `vim.system`; the editor stays
  usable, and a query can be cancelled with `:PSQLCancel`.
- **`~/.pgpass` authentication.** No password, no hash, no `PGPASSWORD` in the
  process list.
- **Telescope pickers** for connections, databases, schemas and tables.
- **Persistent scratchpad**, one SQL file per connection.
- All modules live under `lua/psql/` instead of polluting the global Lua namespace.

## Requirements

- Neovim 0.10+
- `psql`
- [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) (optional, for
  the pickers)

## Installation

With lazy.nvim:

```lua
{
	"edjubert/psql.nvim",
	dependencies = {
		"nvim-telescope/telescope.nvim",
	},
	config = function()
		require("psql").setup({
			connections = {
				local_db = { host = "localhost", port = 5432, database = "postgres", username = "dev" },
				staging = { host = "db.example.com", port = 5432, database = "app", username = "readonly" },
			},
			default = "local_db",
		})
	end,
}
```

## Configuration

```lua
require("psql").setup({
	connections = {
		local_db = { host = "localhost", port = 5432, database = "postgres", username = "dev" },
	},
	default = "local_db",   -- connection selected at startup
	connect_timeout = 5,    -- PGCONNECT_TIMEOUT, in seconds
	query_timeout = 30000,  -- kills a runaway query, in milliseconds
	preview_limit = 10,     -- LIMIT used by the table picker
})
```

A connection has exactly four fields: `host`, `port`, `database`, `username`.
There is no `password` field.

## Authentication

Passwords are resolved by `psql` itself through `~/.pgpass`. The plugin always
invokes `psql -w`, so it never prompts and never leaks a password into the
process list.

```
# ~/.pgpass
hostname:port:database:username:password
db.example.com:5432:*:readonly:secret
```

The file **must** be `chmod 600`:

```bash
chmod 600 ~/.pgpass
```

PostgreSQL silently ignores a `.pgpass` with looser permissions, which shows up
as an unexpected password prompt.

## Commands

| Command | Description |
|---|---|
| `:PSQLConnections` | pick a connection |
| `:PSQLDatabases` | pick a database on the current server |
| `:PSQLSchemas` | pick a schema, then one of its tables |
| `:PSQLTables` | pick any table, as a flat `schema.table` list |
| `:PSQLTemp` | open the scratchpad of the current connection |
| `:PSQLCancel` | cancel the running query |
| `:PSQLInfo` | show the current connection and database |

In the table picker opened from `:PSQLSchemas`, `<BS>` goes back to the schema
list. It is bound in **normal mode only**, so that backspace still edits the
Telescope prompt.

Selecting a table runs `SELECT * FROM "schema"."table" LIMIT 10;`.

## Keymaps

This plugin defines no keymaps. These are a reasonable starting point:

```lua
local psql = require("psql")
local opts = { noremap = true, silent = true, nowait = true }

vim.keymap.set("n", "<localleader>r", psql.query_paragraph, opts)
vim.keymap.set("n", "<localleader>e", psql.query_current_line, opts)
vim.keymap.set("v", "<localleader>e", psql.query_selection, opts)
vim.keymap.set("n", "<localleader>y", psql.yank_cell, opts)
```

## Results buffer

Results are written to a reused `__SQL__` buffer, which keeps the history of
previous queries. Wrapping is disabled so that wide tables scroll horizontally
(`zl` / `zh`, or `zL` / `zH` for larger jumps) instead of folding into
unreadable blocks.

## Scratchpad

`:PSQLTemp` opens `<stdpath("data")>/psql/<connection>.sql`, a real file on disk.
Each connection gets its own scratchpad, so your working queries follow the
database you are working on across sessions.

## Migrating from the upstream plugin

1. Replace `harrisoncramer/psql` with `edjubert/psql.nvim` in your plugin spec.
2. Delete your `~/.config/nvim/lua/psql/<name>.lua` files and move their
   `host` / `port` / `database` / `username` fields into `connections`. Drop
   `password` and `hash_algorithm`.
3. Make sure `~/.pgpass` exists, is `chmod 600`, and has a line for every
   connection you declared.
4. `:PSQL <name>` is gone; use `:PSQLConnections`.

## Development

```bash
make test
```

Tests use [mini.test](https://github.com/nvim-mini/mini.test). Set `MINI_TEST_DIR`
if it is not in one of the standard locations; otherwise it is cloned automatically
into `deps/`.
