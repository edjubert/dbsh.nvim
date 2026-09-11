# dbsh.nvim

Query PostgreSQL from Neovim without leaving your editor, without blocking it,
and without exposing a password to `psql`.

<!--
SCREENSHOT docs/media/hero.png
Shows: the whole loop in one frame.
Setup: a vertical split. Left, a .sql file with two or three statements, cursor
  inside a SELECT. Right, the __DBSH__ buffer showing that query echoed, a
  "Time: N ms" line, and a result table of 4-5 rows.
Framing: full Neovim window, no terminal chrome, no tab bar clutter.
-->
![dbsh.nvim](docs/media/hero.png)

```lua
require("dbsh").setup({
	connections = {
		analytics = {
			type = "postgres",
			host = "<host>",
			port = 5432,
			database = "<database>",
			username = "<username>",
		},
	},
	default = "analytics",
})
```

---

## Lineage

This is a fork of [harrisoncramer/psql](https://github.com/harrisoncramer/psql),
itself forked from [mzarnitsa/psql](https://github.com/mzarnitsa/psql). Those
projects contributed the core idea this one still rests on: write SQL in a normal
buffer, read the result in another one, no modal UI in between.

Everything under that idea has been rewritten. Execution moved off the main
thread, authentication moved to `~/.pgpass`, the schema became browsable, and the
plugin gained a test suite. If you are coming from either upstream, read
[Migrating](#migrating-from-an-upstream-version) — the configuration format
changed.

## What you get

| | upstream | dbsh.nvim |
|---|---|---|
| Execution | `vim.fn.systemlist`, editor frozen until the query returns | `vim.system`, asynchronous and cancellable |
| Authentication | password or hash stored in your Neovim config | `~/.pgpass`, resolved by `psql` itself |
| Switching database | one Lua file per connection, hand-written | context scoped to the active buffer |
| Schema browsing | none | paged contexts and PostgreSQL object catalogs |
| Ad-hoc queries | scratch buffer, lost on exit | named scratchpads with independent metadata |
| Getting data out | one cell at a time | CSV to file, or CSV from a visual selection |
| Result buffer | soft-wrapped, editable | horizontal scroll, read-only |
| Lua namespace | `lua/psql.lua`, `lua/util/`, `lua/hash/` | everything under `lua/dbsh/` |
| Tests | none | `mini.test`, run with `make test` |

### It never blocks

Queries run through `vim.system`. The editor stays responsive while one is in
flight, and `:DbCancel` kills it. A generation counter invalidates results that
belong to a connection you have already left, so a slow answer can never
overwrite a fresh one.

### It never asks `psql` for a password

`psql` is always invoked with `-w` and resolves credentials from `~/.pgpass`;
dbsh never puts a password or `PGPASSWORD` in its process list. Managed PgLS is
an opt-in exception described in [Language server](#language-server): its
in-memory session secret is sent only through the PgLS RPC, never to `psql`.

### It knows your schema

<!--
SCREENSHOT docs/media/picker-tables.png
Shows: :DbTables over a real database.
Setup: run :DbTables on a schema with a mix of object kinds. Type 2-3
  characters in the prompt so fuzzy matching is visibly at work. The result list
  must contain at least one [table] and one [view] so the kind annotation reads
  clearly.
Framing: the Telescope window, with enough of the underlying SQL buffer visible
  to show it floats over your work.
-->
![Table picker](docs/media/picker-tables.png)

Contexts, paged catalogues and relation inspection all use the same picker
surface. Selecting a relation previews rows; structural objects open a
read-only definition buffer.

---

## Requirements

- Neovim **0.10+** — the plugin uses `vim.system`, `vim.fn.getregion` and
  `vim.fs.joinpath`
- `psql` on your `PATH`
- [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) — **optional**;
  every picker degrades to a clear message without it, and queries work fine
- [postgres-language-server](https://github.com/supabase-community/postgres-language-server) —
  **optional**; only needed if you enable an LSP mode, see
  [Language server](#language-server)

## Installation

<details open>
<summary><b>lazy.nvim</b></summary>

```lua
{
	"edjubert/dbsh.nvim",
	dependencies = { "nvim-telescope/telescope.nvim" },
	config = function()
		require("dbsh").setup({
			connections = {
				analytics = {
					type = "postgres",
					host = "<host>",
					port = 5432,
					database = "<database>",
					username = "<username>",
				},
			},
			default = "analytics",
		})
	end,
}
```
</details>

<details>
<summary><b>packer.nvim</b></summary>

```lua
use({
	"edjubert/dbsh.nvim",
	requires = { "nvim-telescope/telescope.nvim" },
	config = function()
		require("dbsh").setup({ --[[ ... ]] })
	end,
})
```
</details>

To get the pickers under `:Telescope`, load the extension:

```lua
require("telescope").load_extension("dbsh")
-- :Telescope dbsh tables
```

## Quick start

1. Declare a connection in `setup()` — four fields for `psql`, no password.
2. Add a line for it to `~/.pgpass`, then `chmod 600 ~/.pgpass`.
3. Open a `.sql` file, put the cursor in a statement, and run
   `:lua require("dbsh").query_paragraph()`.

If a password prompt appears, `~/.pgpass` is being ignored — see
[Troubleshooting](#troubleshooting).

## Configuration

```lua
require("dbsh").setup({
	connections = {
		analytics = {
			type = "postgres",
			host = "<host>",
			port = 5432,
			database = "<database>",
			username = "<username>",
		},
	},
	default = "analytics",
	connect_timeout = 5,
	query_timeout = 30000,
	preview_limit = 10,
	catalog_page_size = 200,
	csv_delimiter = ",",
	export_dir = vim.fs.joinpath(vim.fn.stdpath("data"), "dbsh", "exports"),
	results_split = "horizontal",
	variable_patterns = {}, -- e.g. { ":(raw_data)" }, see SQL variables below
	safety = { mode = "confirm" }, -- "confirm" or "off"
	lsp = {
		mode = "off", -- "off", "external", or "managed"; see below
	},
})
```

| Option | Default | Meaning |
|---|---|---|
| `connections` | `{}` | Named connections. `type` names the backend driving it and defaults to `"postgres"`; a postgres connection then needs `host`, `port`, `database`, `username`. |
| `default` | `nil` | Connection selected at startup. Falls back to any declared one. |
| `connect_timeout` | `5` | `PGCONNECT_TIMEOUT`, in seconds. |
| `query_timeout` | `30000` | Kills a runaway query, in milliseconds. |
| `preview_limit` | `10` | `LIMIT` used when previewing a table from the picker. |
| `catalog_page_size` | `200` | Number of catalog objects fetched per page. |
| `csv_delimiter` | `","` | Column separator, for both CSV export and CSV yank. |
| `export_dir` | `<stdpath("data")>/dbsh/exports` | Where `:DbExportCSV` suggests writing. |
| `results_split` | `"horizontal"` | `"horizontal"`, `"vertical"` or `"float"`: which window opens `__DBSH__` in. Only applies the first time the window is created; combine with `vim.opt.splitright = true` for a right-hand split. `"float"` is styled after your telescope config, when installed. |
| `variable_patterns` | `{}` | Lua patterns (one capture each) naming SQL variables to prompt for. See [SQL variables](#sql-variables). |
| `safety` | `{ mode = "confirm" }` | Confirms mutating or ambiguous SQL. Use `{ mode = "off" }` to disable the ergonomic guardrail. |
| `lsp` | `{ mode = "off" }` | Disable PgLS by default. Choose `external` for a user-owned client or `managed` for dbsh-owned PostgreSQL clients. |

There is deliberately no password field required for SQL execution. `psql`
always uses `~/.pgpass`. Managed PgLS alone needs an in-memory `password` on
its PostgreSQL profile, usually sourced from an environment variable as shown
below; dbsh never passes that value to `psql` or persists it.

## Authentication

`psql` resolves passwords from `~/.pgpass`. The plugin passes `-w`, so it never
prompts and never leaks a password into the process list.

```
# ~/.pgpass — hostname:port:database:username:password
<host>:<port>:<database>:<username>:<password>
```

The file **must** be `chmod 600`:

```bash
chmod 600 ~/.pgpass
```

PostgreSQL silently ignores a `.pgpass` with looser permissions. The symptom is an
unexpected password prompt, and it is the single most common setup mistake.

## Language server

[postgres-language-server](https://github.com/supabase-community/postgres-language-server)
validates SQL against a real database: it will tell you a column does not exist
before you run the query. dbsh supports three explicit modes:

```lua
require("dbsh").setup({
	connections = {
		local_db = {
			host = "127.0.0.1",
			port = 5432,
			database = "app",
			username = "app",
			password = vim.env.PGAPP_PASSWORD,
			search_path = { "extensions", "public" },
		},
	},
	default = "local_db",
	lsp = {
		mode = "managed", -- "off", "external", or "managed"
		command = { "postgres-language-server", "lsp-proxy" },
		client_pool = {
			strategy = "immediate", -- "immediate", "idle", or "session"
			idle_timeout_ms = 30000,
		},
		notifications = { failures = true },
	},
})
```

- `off` is the default and performs no LSP work.
- `external` preserves the original integration with a client you start through
  lspconfig, Mason, or another plugin. dbsh never starts, stops, attaches, or
  detaches that client.
- `managed` is PostgreSQL-only. dbsh starts and owns PgLS clients for eligible
  dbsh SQL contexts, then retires them according to the selected pool strategy.

`lsp.enabled = true` remains accepted as a deprecated alias for
`lsp.mode = "external"` and warns once. `false` maps to `off`. An explicit
`mode` always wins over the old boolean.

### External mode

External mode sends the existing password-free
`workspace/didChangeConfiguration` delta and invalidates/warm-ups PgLS's schema
cache after successful queries. It never copies dbsh values into the
user-owned client's `settings` table.

A user-owned PgLS client has only one effective configuration. With distinct
buffer contexts, **last-synchronized context wins**: changing one buffer can
change diagnostics for another. Use `:DbLspStatus` to see the last public
context dbsh synchronized, or use managed mode when contexts need isolation.

### Managed mode

Managed mode uses one client per public context key: PostgreSQL connection
identity, effective database, project root, and the resolved search path
(selected schema first, then the configured `search_path`, deduplicated).
Changing one buffer's context detaches only that buffer from its stale client;
other buffers retain their references.

`immediate` stops a client when its final buffer detaches. `idle` waits for
`idle_timeout_ms` and cancels that timer if a buffer reattaches. `session`
retains the client until Neovim exits.

The password remains in dbsh memory and is sent only in the
`pgls/setDatabaseContext` session RPC. It is never put in the spawned command,
environment, public client key, status output, notification, or persisted dbsh
state. If starting or configuring PgLS fails, SQL execution remains unaffected;
dbsh stores a sanitized per-context error and notifies once by default. Set
`lsp.notifications.failures = false` to suppress that notification.

`:DbLspStatus` reports the active public managed record or, in external mode,
the user-owned/shared limitation and its last synchronized public context.

Managed mode requires a PgLS binary containing `pgls/setDatabaseContext`. It is
not available in an unpatched PgLS release. Roll out the PgLS protocol change
first, then dbsh, and test against a merged or released PgLS binary before
release.

Until PgLS ships that request, development and review can build the companion
[PgLS context RPC commit](https://github.com/edjubert/postgres-language-server/commit/4ab9acd4441cdd6721e0a2d57e8e2935f5d90cf3):

```bash
git clone https://github.com/supabase-community/postgres-language-server.git
cd postgres-language-server
git fetch https://github.com/edjubert/postgres-language-server.git \
  edjubert/pgls-database-context-rpc
git checkout --detach FETCH_HEAD
cargo build --release
```

An existing PgLS checkout may cherry-pick that same commit instead. Point
`lsp.command` at the locally built binary only; do not put a machine-specific
path in shared configuration.

## Commands

| Command | Description |
|---|---|
| `:DbConnections` | pick a connection |
| `:DbTemp` | open the named scratchpad picker |
| `:DbObjects` | choose an object catalog |
| `:DbDefinitions` | choose a definition buffer for the active context |
| `:DbToggleDefinition` | show or hide the current/last definition |
| `:DbRefreshDefinition` | re-fetch the current definition using its captured context |
| `:DbCloseDefinitions` | close visible definition windows for the active context |
| `:DbToggleResults` | toggle the result window closed or open, keeping its content |
| `:DbExportCSV` | export a query result to a CSV file — accepts a range |
| `:DbCancel` | cancel the running query |
| `:DbInfo` | show the current connection and database |

Catalog commands are declared from the union of installed backend contracts, then
dispatched against the backend of the active buffer. A command that is not
available for that buffer explains why instead of changing another buffer's
context. PostgreSQL provides:

| Command | Description |
|---|---|
| `:DbDatabases` | pick a database on the current server |
| `:DbSchemas` | set the active schema context |
| `:DbRelations` | browse tables, views, materialized/partitioned and foreign tables |
| `:DbTables` | compatibility relation browser without foreign tables |
| `:DbColumns`, `:DbIndexes`, `:DbConstraints`, `:DbSequences` | browse structural objects |
| `:DbFunctions`, `:DbTypes`, `:DbPolicies`, `:DbTriggers`, `:DbExtensions` | browse remaining PostgreSQL object kinds |

Catalog searches are literal server-side filters, not arbitrary SQL. They use
deterministic keyset pagination; choose **Load more** to fetch the next page.

### Compatibility note

`:DbTables` remains available for PostgreSQL users migrating from older dbsh or
psql.nvim configurations. It keeps the historical table/view/materialized-view/
partitioned-table coverage. Prefer `:DbRelations` for the canonical relation
browser, which also includes foreign tables. Backend authors should use the
separate `contexts` and `catalogs` contracts; the former `backend.levels`
hierarchy is no longer part of the plugin contract.

## Lua API

The plugin defines no keymaps. These are the functions worth binding:

| Function | Description |
|---|---|
| `query(sql)` | run an arbitrary string |
| `query_paragraph()` | run the block around the cursor, delimited by blank lines |
| `query_current_line()` | run the line under the cursor |
| `query_selection()` | run the visual selection, in any visual mode |
| `yank_cell()` | copy the result cell under the cursor |
| `yank_csv()` | copy the selected result cells as CSV |
| `export_csv(opts)` | the function behind `:DbExportCSV` |
| `last_query()` | the last query handed to `query()`, or `nil` |

## Keymaps

```lua
local dbsh = require("dbsh")
local opts = { noremap = true, silent = true, nowait = true }

vim.keymap.set("n", "<localleader>r", dbsh.query_paragraph, opts)
vim.keymap.set("v", "<localleader>r", dbsh.query_selection, opts)
vim.keymap.set("n", "<localleader>e", dbsh.query_current_line, opts)
vim.keymap.set("v", "<localleader>e", dbsh.query_selection, opts)
vim.keymap.set("n", "<localleader>y", dbsh.yank_cell, opts)
vim.keymap.set("v", "<localleader>y", dbsh.yank_csv, opts)
```

Bind every key in **both** normal and visual mode, even where one of the two looks
redundant. An unmapped `<localleader>` prefix falls through in visual mode, and the
next key is then read as a plain Vim command: with `<localleader>r` left unmapped,
pressing it over a selection runs `r`, which silently replaces every selected
character. Mapping it closes that trap.

| | normal mode | visual mode |
|---|---|---|
| `<localleader>r` | run the paragraph | run the selection |
| `<localleader>e` | run the current line | run the selection |
| `<localleader>y` | yank the cell under the cursor | yank the selection as CSV |

---

## Running queries

Three ways to send SQL, none of which need a precise selection:

- **`query_paragraph()`** — the block of lines around the cursor, bounded by blank
  lines. This is the one you will reach for. Separate your statements with a blank
  line and you never have to select anything.
- **`query_current_line()`** — just the line under the cursor.
- **`query_selection()`** — whatever is selected, in any visual mode.

While a query runs, the result buffer shows a `# Running...` placeholder, and
`:DbCancel` kills the process.

### Query safety

By default dbsh asks before SQL that mutates data/schema, changes privileges, is
ambiguous, or contains multiple top-level statements. Read-only `SELECT`, `WITH
… SELECT`, `SHOW`, `DESCRIBE`, `DESC`, and `EXPLAIN` run immediately.

The prompt describes only the classifier reason; it never displays resolved
variable values. Choosing **Cancel** stops before dbsh asks for SQL variables or
starts a subprocess. This is an ergonomic guardrail, not authorization:
PostgreSQL permissions remain authoritative. Set `safety = { mode = "off" }` if
you do not want confirmations.

Manually typed `SET ROLE`, `USE`, or similar SQL affects only that invocation.
dbsh never infers a persistent context change from arbitrary SQL.

### Contexts and sessions

Connection and database/schema selections belong to the active buffer. Two SQL
buffers can therefore use different connections and schemas at the same time;
their queries, result buffers, process slots, catalog pages, and definitions do
not overwrite each other. `:DbGlobalConnection` changes only the fallback used
by buffers that have not been explicitly bound.

## Results buffer

<!--
SCREENSHOT docs/media/results.png
Shows: why disabling wrap matters.
Setup: run a query returning a table too wide for the window — 8+ columns, or a
  column holding a long text value. Scroll right with zL so the table is visibly
  cut off on the left edge, proving rows stay on a single line.
Framing: the __DBSH__ window filling most of the screen, line numbers visible so
  it is obvious that one row is one line.
-->
![Result buffer](docs/media/results.png)

Results land in a reused `__DBSH__` buffer, which keeps previous queries in view as
a working history.

Wrapping is off, so wide tables scroll horizontally (`zl` / `zh`, `zL` / `zH` for
bigger jumps) instead of folding into unreadable blocks. The buffer is also
**read-only**: it is rendered by the plugin, and hand edits would only desync it
from what `psql` returned.

On failure, `stderr` is rendered in place of the result, so a syntax error reads
exactly where you expect the table.

## Pickers

<!--
SCREENSHOT docs/media/picker-schemas_1.png + docs/media/picker-schemas_2.png
Shows: the drill-down. Frame 1, :DbSchemas with a schema highlighted.
  Frame 2, the table picker that opens after selecting it, titled
  "dbsh tables - <schema>".
-->
<table>
<tr>
<td width="50%"><img src="docs/media/picker-schemas_1.png" alt="DbSchemas, a schema highlighted"></td>
<td width="50%"><img src="docs/media/picker-schemas_2.png" alt="Tables of the selected schema"></td>
</tr>
</table>

- **`:DbConnections`** — switch between the connections you declared.
- **`:DbDatabases`** — every database on the current server. Selecting one keeps
  the same host, port and user, and swaps only the database.
- **`:DbSchemas`** — pick the schema context for the active buffer.
- **`:DbRelations`** / **`:DbTables`** — browse relations with a schema scope or
  all schemas. `DbTables` keeps the compatibility object set.
- **Structural catalogs** — columns, indexes, constraints, sequences, routines,
  types, policies, triggers, and extensions are direct commands as listed above.

Selecting a table runs `SELECT * FROM "schema"."table" LIMIT 10;`, with the limit
taken from `preview_limit`. Identifiers are quoted, so mixed-case names and
reserved words survive.

Press `<C-i>` on a relation to open its inspector: Columns, Indexes,
Constraints, Triggers, Policies, Dependencies, and Definition. Structural
objects open a read-only DDL buffer. Introspection and DDL execution use
independent process slots, so neither cancels a user query.

### Definition buffers

There is one read-only DDL buffer per object identity and effective public
context. Reopening the same object focuses it; opening a different object while
reading a definition uses a split, keeping the previous DDL visible.

Definition buffers retain the context captured at opening. Consequently,
`:DbRefreshDefinition` does not accidentally use a connection selected later in
another buffer. `:DbDefinitions` lists them for the active context and
`:DbCloseDefinitions` hides only visible windows; hidden buffers remain reusable.

## Backends

The plugin drives a database shell as a subprocess; which shell it drives is a
property of the connection:

```lua
connections = {
	analytics = {
		type = "postgres",
		host = "<host>",
		port = 5432,
		database = "<database>",
		username = "<username>",
	},
}
```

`type` defaults to `"postgres"`, which is the only backend implemented today. A
backend is a small table under `lua/dbsh/backends/`: it says how to build the
CLI invocation, what preamble to write, how to parse raw output, how to declare
a query variable, how to export CSV, and which navigation levels its catalog
has. Context selectors live in `backend.contexts`; paged object browsers live in
`backend.catalogs`. Everything else — result and definition buffers, the CSV
yank, scratchpads, variable prompts, and export file handling — is shared and
knows nothing about any particular database.

## Scratchpad

<!--
SCREENSHOT docs/media/scratchpad.png
Shows: that the scratchpad is a real file.
Setup: run :DbTemp, write two queries in it, and make the statusline or winbar
  visible so the full path
  ~/.local/share/nvim/dbsh/<connection>.sql can be read. SQL syntax highlighting
  must be visible.
Framing: include the statusline; the path is the point of the shot.
-->
![Scratchpad](docs/media/scratchpad.png)

`:DbTemp` opens a picker of named scratchpads. Each scratchpad is a real `.sql`
file with persistent metadata: backend, optional connection, effective context
levels, and an optional project root. Your SQL LSP, formatter, and persistent
undo work normally, and scratchpads survive restarts.

Scratchpads do not share an in-memory global context. Opening two of them keeps
their sessions independent, just like ordinary SQL buffers.

## SQL variables

Shared SQL files often target a table that changes from one run to the next:

```sql
SELECT * FROM :raw_data WHERE created_at > now() - interval '7 days';
```

Declare which names are variables, and dbsh.nvim asks for their value before
running the query:

```lua
variable_patterns = { ":(raw_data)" },
```

Each entry is a Lua pattern with **one capture**, which gives the variable name.
This mirrors the *User Parameters* setting of JetBrains DataGrip, where the same
declaration reads `:(raw_data)`. The default is an empty list, so no existing SQL
file changes behaviour until you opt in.

<!-- SCREENSHOT: the "dbsh variable raw_data" picker open over a SQL buffer,
     listing two previously used table names. -->
![Variable prompt](docs/media/variable-prompt.png)

The prompt doubles as the input field: the list holds the values you already used
for that variable, most recent first. `<CR>` takes the highlighted entry, or the
text you typed when nothing matches. `<C-e>` always takes the typed text, which is
how you enter a value that happens to be a substring of an existing one. Dismissing
the prompt cancels the whole run — a half-parameterised query never reaches the
server.

Without telescope.nvim, the prompt degrades to `vim.ui.input`, prefilled with the
most recent value.

Values are remembered per connection in
`<stdpath("data")>/dbsh/vars/<connection>.json`, deduplicated and capped at 50 per
variable. Table and schema names only make sense on the database they came from,
which is the same reasoning the scratchpad follows. Edit or delete that file by
hand if you need to clean it up.

### How substitution works

The plugin does **not** rewrite your SQL. It emits `\set` directives ahead of the
query and lets `psql` interpolate `:name` itself. Two consequences worth knowing:

- Nothing is ever substituted inside a quoted literal, because `psql` does not
  interpolate there. That is the guarantee DataGrip has to offer as a checkbox.
- Only `:name`-shaped variables can work. A bare token with no colon is not
  something `psql` can interpolate.

### Choosing a pattern

A wide pattern catches everything at once:

```lua
variable_patterns = { ":([%w_]+)" },
```

Be aware it also matches things you did not mean: `a::text` yields a variable
named `text`, and `'12:30'` yields `30`. Naming each variable explicitly, as in
`":(raw_data)"`, avoids this entirely and is the recommended default.

## CSV export

<!--
SCREENSHOT docs/media/export-prompt.png
Shows: the destination prompt and its generated suggestion.
Setup: run :DbExportCSV from the __DBSH__ buffer. Capture while the prompt is
  open, pre-filled with a path of the form
  <export_dir>/<YYYYMMDD>_<connection>.csv so the date and connection name are
  both legible.
Framing: the command line area plus enough of the result buffer above to show
  which query is being exported.
-->
![CSV export prompt](docs/media/export-prompt.png)

`:DbExportCSV` writes a query result to a `.csv` file. What it exports depends on
where you run it:

- from the `__DBSH__` buffer — the query currently displayed, re-run;
- over a **visual selection** — the selected lines;
- anywhere else — the SQL paragraph under the cursor.

Queries holding SQL variables are resolved before the export, so `:DbExportCSV`
asks for their values first and the destination path second.

The suggested path is `<export_dir>/<YYYYMMDD>_<connection>.csv`, or
`..._scratchpad.csv` when no connection is selected. It gains a `_1`, `_2` suffix
when the file exists, and the prompt lets you edit it. **An existing file is never
overwritten**: the suffix is applied again to whatever path you confirm.

Under the hood it runs `COPY (...) TO STDOUT WITH (FORMAT CSV, HEADER)`. That needs
no superuser right, keeps multi-line queries valid, and the file is written by
Neovim on the machine you are sitting at.

## CSV yank

<!--
SCREENSHOT docs/media/yank-csv.png
Shows: a blockwise selection and what comes out of it.
Setup: two stacked frames. Frame 1, a <C-v> block covering two columns of the
  result table across three rows, with the "yanked 3 row(s) as CSV" notification
  visible. Frame 2, the output of :reg " showing those cells as CSV, ideally with
  one value quoted because it holds a comma.
Framing: crop to the table and the notification; the register listing can be a
  smaller inset.
-->
![CSV yank](docs/media/yank-csv.png)

`yank_csv()` turns a visual selection of the rendered table into CSV:

- **`V`** takes every column of the selected rows;
- **`<C-v>`** takes only the columns the block covers, which also handles the
  single-cell case.

Character-wise `v` is rejected with a message rather than guessed at — the meaning
of a character selection across a drawn table is ambiguous.

Frame and separator lines are ignored, so a selection that overshoots the table
still yields clean CSV. Values are escaped per RFC 4180: a field holding the
delimiter, a quote or a newline gets quoted, and inner quotes are doubled.

The text goes to the default register **and** to the clipboard registers your
`'clipboard'` option asks for — `+` under `unnamedplus`, `*` under `unnamed`. So
`vim.opt.clipboard = "unnamedplus"` is enough to paste it into a spreadsheet.

For a single cell without selecting anything, `yank_cell()` grabs the one under the
cursor.

> **`(NULL)` versus empty.** A CSV *yank* copies what is on screen, so a null cell
> reads `(NULL)`. A CSV *export* goes through `COPY`, which knows the real SQL null
> and writes an empty field. Same data, two honest representations.

---

## Troubleshooting

**A password prompt appears.** `~/.pgpass` is not `chmod 600`, or has no line
matching this host, port, database and user. PostgreSQL ignores an over-permissive
file without saying so.

**`:DbTables` says telescope is required.** Telescope is optional but needed for
the pickers. Queries still work without it.

**`yank_csv` reports success but nothing pastes.** Your `'clipboard'` sends puts
through `+`. This is handled since the CSV yank honours `'clipboard'` — make sure
you are on a current version.

**Pressing `<localleader>r` over a selection mangles the buffer.** The prefix is
unmapped in visual mode, so Vim's `r` takes over. See [Keymaps](#keymaps).

**A query hangs.** `:DbCancel` kills it. `query_timeout` caps it automatically.
Note that killing `psql` does not repair a degraded SSH tunnel underneath.

## Migrating from an upstream version

1. Replace `harrisoncramer/psql` or `mzarnitsa/psql` with `edjubert/dbsh.nvim`.
2. Delete your `~/.config/nvim/lua/psql/<name>.lua` files. Move their `host`,
   `port`, `database` and `username` into the `connections` table passed to
   `setup()`, and drop `password` and `hash_algorithm`.
3. Create `~/.pgpass`, `chmod 600` it, and add a line per connection.
4. `:PSQL <name>` is gone — use `:DbConnections`.

The parts you knew are unchanged: the result buffer is still `__DBSH__`, and
paragraph, line and selection queries behave the same.

## Migrating from psql.nvim

The plugin was renamed to make room for other database shells. The break is
clean: there is no deprecated `:PSQL*` alias and no `psql.*` Lua namespace.

- Replace `require("psql")` with `require("dbsh")` in your config.
- Rename your commands: `:PSQLTables` becomes `:DbTables`, and so on.
- Move your stored data, which is not migrated automatically:

```sh
mv ~/.local/share/nvim/psql ~/.local/share/nvim/dbsh
```

## Development

```bash
make test
```

Tests run on [mini.test](https://github.com/nvim-mini/mini.test), cloned into
`deps/` automatically. Set `MINI_TEST_DIR` if you keep it elsewhere.

The modules are small and single-purpose, which is what makes them testable:

| Module | Responsibility |
|---|---|
| `config.lua` / `context.lua` | static options and buffer-scoped runtime contexts |
| `exec.lua` | asynchronous SQL/argv invocation, session slots, cancellation |
| `results.lua` / `definitions.lua` | read-only result and DDL buffers |
| `catalog.lua` / `backends/*.lua` | generic paged contract and backend catalog queries |
| `scratch.lua` | named scratchpads and their metadata |
| `safety.lua` | pure conservative SQL confirmation classifier |
| `csv.lua` | table parsing and CSV serialization, pure functions |
| `export.lua` | destination paths and the `COPY` statement |
| `telescope/pickers.lua` | connection, scratchpad, catalog, and definition pickers |
| `init.lua` | public API and user commands |

## Credits

- [mzarnitsa/psql](https://github.com/mzarnitsa/psql) — the original plugin.
- [harrisoncramer/psql](https://github.com/harrisoncramer/psql) — the fork this one
  grew from.
