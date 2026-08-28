# psql.nvim

A PostgreSQL client for Neovim that stays out of your way: queries run
asynchronously, passwords live in `~/.pgpass`, and your schema is a fuzzy find
away.

<!-- SCREENSHOT: hero shot — a SQL buffer on the left, the __SQL__ result table
     on the right, showing a real query and its formatted output. -->
![psql.nvim in action](docs/media/hero.png)

> **This is a fork.** It descends from
> [harrisoncramer/psql](https://github.com/harrisoncramer/psql), itself a fork of
> [mzarnitsa/psql](https://github.com/mzarnitsa/psql). The original authors built
> the idea — run SQL from a buffer, read the result in another one. This fork
> rewrote the internals around that idea: asynchronous execution, `~/.pgpass`
> authentication, Telescope pickers, a persistent scratchpad, and CSV export.
> See [Migrating from the upstream plugin](#migrating-from-the-upstream-plugin)
> if you are coming from either of them.

## Why this fork

| | upstream | this fork |
|---|---|---|
| Query execution | `vim.fn.systemlist` — blocks the editor | `vim.system` — asynchronous, cancellable |
| Authentication | password or hash in your config | `~/.pgpass`, resolved by `psql` itself |
| Switching database | one Lua file per connection | Telescope picker, or `setup()` table |
| Schema browsing | none | four pickers: connections, databases, schemas, tables |
| Scratch queries | none | one persistent `.sql` file per connection |
| Getting data out | copy one cell at a time | CSV export to file, CSV yank from a selection |
| Namespace | `lua/psql.lua`, `lua/util/`, `lua/hash/` | everything under `lua/psql/` |
| Tests | none | 87 tests on `mini.test`, run with `make test` |

### Never blocks the editor

Queries run through `vim.system`. You keep editing, scrolling, or opening another
file while a slow query is in flight, and `:PSQLCancel` kills it. A generation
counter drops results that belong to a connection you have already left, so a
late answer never overwrites a fresh one.

### No password anywhere

There is no `password` field, no hash, no `PGPASSWORD` in your process list.
`psql` is always invoked with `-w` and resolves credentials from `~/.pgpass`,
which is the mechanism PostgreSQL already ships for exactly this.

### Your schema, fuzzy-found

<!-- SCREENSHOT: the :PSQLTables picker open over a SQL buffer, prompt showing a
     partial match, a few schema.table entries with their [table]/[view] kind. -->
![Table picker](docs/media/picker-tables.png)

Four pickers, drill-down included: pick a connection, pick a database on that
server, pick a schema then one of its tables, or search every table at once as a
flat `schema.table` list. Selecting a table previews it right away.

## Requirements

- Neovim 0.10+
- `psql` on your `PATH`
- [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) — optional,
  only needed for the pickers

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

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
	csv_delimiter = ",",    -- column separator for CSV export and CSV yank
	export_dir = vim.fs.joinpath(vim.fn.stdpath("data"), "psql", "exports"),
})
```

A connection has exactly four fields: `host`, `port`, `database`, `username`.
There is no `password` field, by design.

## Authentication

Passwords are resolved by `psql` through `~/.pgpass`. The plugin never prompts
and never leaks a password into the process list.

```
# ~/.pgpass
hostname:port:database:username:password
db.example.com:5432:*:readonly:secret
```

The file **must** be `chmod 600`:

```bash
chmod 600 ~/.pgpass
```

PostgreSQL silently ignores a `.pgpass` with looser permissions, and the symptom
is an unexpected password prompt — this is the single most common setup mistake.

## Commands

| Command | Description |
|---|---|
| `:PSQLConnections` | pick a connection |
| `:PSQLDatabases` | pick a database on the current server |
| `:PSQLSchemas` | pick a schema, then one of its tables |
| `:PSQLTables` | pick any table, as a flat `schema.table` list |
| `:PSQLTemp` | open the scratchpad of the current connection |
| `:PSQLExportCSV` | export the current query result to a CSV file |
| `:PSQLCancel` | cancel the running query |
| `:PSQLInfo` | show the current connection and database |

In the table picker opened from `:PSQLSchemas`, `<BS>` goes back to the schema
list. It is bound in **normal mode only**, so backspace still edits the Telescope
prompt.

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
vim.keymap.set("v", "<localleader>y", psql.yank_csv, opts)
```

## Running queries

Three ways to send SQL, none of which need you to select anything precisely:

- `query_paragraph()` — the block of lines around the cursor, delimited by blank
  lines. This is the one you will use most.
- `query_current_line()` — just the line under the cursor.
- `query_selection()` — the visual selection, in any visual mode.

## Results buffer

<!-- SCREENSHOT: the __SQL__ buffer showing a wide table scrolled horizontally,
     making the point that rows stay on one line instead of wrapping. -->
![Result buffer](docs/media/results.png)

Results land in a reused `__SQL__` buffer, which keeps the history of previous
queries in view. Wrapping is disabled, so wide tables scroll horizontally
(`zl` / `zh`, or `zL` / `zH` for larger jumps) instead of folding into unreadable
blocks — the single most annoying thing about reading query output in a text
editor.

The buffer is not modifiable: it is rendered by the plugin, and hand edits would
desync it from what `psql` actually returned.

## Scratchpad

`:PSQLTemp` opens `<stdpath("data")>/psql/<connection>.sql` — a real file on
disk, not a throwaway buffer, so your SQL LSP, formatter, and persistent undo all
work normally. Each connection gets its own scratchpad, so your working queries
follow the database you are working on, across sessions.

## CSV export

<!-- SCREENSHOT: the :PSQLExportCSV prompt open, pre-filled with a suggested
     path like ~/.local/share/nvim/psql/exports/20260828_local_db.csv -->
![CSV export prompt](docs/media/export-prompt.png)

`:PSQLExportCSV` writes the result of a query to a `.csv` file. Which query it
exports depends on where you run it from:

- from the `__SQL__` result buffer, it re-runs the query currently displayed;
- from any other buffer, it exports the SQL paragraph under the cursor.

The suggested path is `<export_dir>/<YYYYMMDD>_<connection>.csv`, or
`<export_dir>/<YYYYMMDD>_scratchpad.csv` when no connection is selected. It gets
suffixed `_1`, `_2`, ... when the file already exists, and the prompt lets you
edit it. An existing file is never overwritten: the suffix is applied again to
whatever path you confirm.

The export runs `COPY (...) TO STDOUT WITH (FORMAT CSV, HEADER)`, so it needs no
superuser right, and the file lands on the machine running Neovim.

## CSV yank

<!-- SCREENSHOT: a blockwise <C-v> selection over two columns of the result
     table, with the resulting CSV visible in a register listing or pasted
     below. -->
![CSV yank](docs/media/yank-csv.png)

`psql.yank_csv()` turns a visual selection of the result table into CSV in the
default register:

- `V` (linewise) takes every column of the selected rows;
- `<C-v>` (blockwise) takes only the columns covered by the block, which also
  covers the single-cell case.

Character-wise `v` is not supported — the meaning of a character selection across
a drawn table is ambiguous — and the function says so rather than guessing.

Border and separator lines are ignored, so a selection that overshoots the table
frame still yields clean CSV. The header row, if selected, is copied like any
other row.

The text goes to the **default register**. Add `vim.opt.clipboard =
"unnamedplus"` to your config if you want it in the system clipboard too.

For a single cell without selecting anything, `psql.yank_cell()` grabs the cell
under the cursor.

## Migrating from the upstream plugin

1. Replace `harrisoncramer/psql` (or `mzarnitsa/psql`) with `edjubert/psql.nvim`
   in your plugin spec.
2. Delete your `~/.config/nvim/lua/psql/<name>.lua` files. Move their `host`,
   `port`, `database` and `username` fields into the `connections` table passed
   to `setup()`, and drop `password` and `hash_algorithm`.
3. Make sure `~/.pgpass` exists, is `chmod 600`, and has a line for every
   connection you declared.
4. `:PSQL <name>` is gone — use `:PSQLConnections`.

Everything else you knew still applies: the result buffer is still `__SQL__`, and
paragraph / line / selection queries behave the same.

## Development

```bash
make test
```

Tests run on [mini.test](https://github.com/nvim-mini/mini.test). Set
`MINI_TEST_DIR` if it is not in one of the standard locations; otherwise it is
cloned automatically into `deps/`.

## Credits

- [mzarnitsa/psql](https://github.com/mzarnitsa/psql) — the original plugin.
- [harrisoncramer/psql](https://github.com/harrisoncramer/psql) — the fork this
  one is based on.
