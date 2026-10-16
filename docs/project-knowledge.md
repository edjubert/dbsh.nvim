# Project Knowledge

This document describes the current contracts in dbsh.nvim. The plugin drives
a database CLI from Neovim; it does not include a database driver. Modules live
under `lua/dbsh/`, user messages start with `dbsh.nvim: `, and persistent data
lives under `stdpath("data")/dbsh/`.

## Backends

A backend is a stateless table under `lua/dbsh/backends/<name>.lua`, registered
in `lua/dbsh/backends/init.lua`. It declares functions such as `argv`, `env`,
`preamble`, `parse_raw`, `variable_preamble`, `export_query`, and `preview_query`,
the `contexts` and `catalogs` contracts, and optionally `definition_request`
and `lsp`.

`contexts` represents context changes persisted in the active buffer;
`catalogs` represents the objects users can browse. A catalog exposes `key`,
`command`, `title`, `list(request, callback)`, and its actions. Its `request`
contains a **public** context, a scope, a literal filter, an opaque cursor, and
a page limit. Backends build pages and apply server-side filters; the UI filters
already-loaded entries locally and does not fetch every page into memory.

MongoDB exposes `DbMongoDatabases` for selecting a database, and
`DbMongoCollections`, `DbMongoIndexes`, and `DbMongoPreview` for browsing
catalogs. MongoDB's catalog APIs do not provide sorting with a limit, so the
backend filters, sorts, and paginates index metadata by name. Database context
selection and the collections/preview catalogs return all names in one request,
without a page limit. Explicit literal filters for databases and collections
are also sent to the server. Indexes declare `parent = "collections"`: the
picker first selects a collection without starting a preview. The
`on_select`/`action` callbacks receive options as their third argument and keep
the source buffer's snapshot; `query(text, snapshot)` accepts that context.
The Mongo script uses an `async` function and awaits the result of `eval`, then
materializes cursors with `toArray`. `eval` does not get mongosh's asynchronous
rewriting, so previews pass the limit in the `find({}, null, { limit: n })`
options instead of chaining `limit()` on its promise. A MongoDB command selects
its operation from the first BSON key, so `listDatabases` is emitted explicitly
before its options instead of depending on Lua table key order during JSON
encoding.

A backend never requires `config`, `definitions`, or global state. Callers pass
the required values as arguments. Backends defer access to `exec` to avoid a
dependency cycle with the backend registry.

A non-SQL backend can declare `compose` to wrap the query text,
`script_delivery = "stdin"` to pass a secret without writing a temporary file,
`classify` to replace the SQL scanner, and `tabular = false` for document-style
output. `csv.lua` splits cells on │, so CSV yanking explicitly refuses
non-tabular output.

MongoDB supports `auth = "aws"` with a profile managed by AWS CLI v2.
`aws.lua` calls `aws configure export-credentials --format process`: it does
not read the SSO cache or pass tokens in argv. The `MONGODB-AWS` URI has no
userinfo because those fields represent an AWS access key and secret, not an
IAM ARN. Credentials are passed only through the child process environment,
and their cache respects both the AWS expiration time and the dbsh TTL. The
SOCKS proxy is optional.

## Context, Results, and Definitions

`config.lua` holds immutable declared options and profiles. `context.lua` holds
runtime contexts: a fallback for unbound buffers and a separate context for
each buffer/scratchpad. A snapshot is copied before each query, catalog,
result, or definition request; `generation` prevents a late callback from
overwriting a changed context.

`results.lua` keeps one `__DBSH__` buffer per session. Buffer names are derived
from the registry key, not a broader label: `results.lua` adds a hash of the
session ID to the connection name, while `definitions.lua` adds a hash of its
key to the object label. Distinct registry entries therefore cannot compete
for a name and trigger `E95`. `find_buf` also recovers a buffer through its
`dbsh_context_id` buffer variable: reloading the plugin clears module state,
not buffers.

Scratchpads and results use `backend.filetype`: `sql` for PostgreSQL/Snowflake
and `javascript` for MongoDB. New scratchpads use `backend.extension` (`.sql`
or `.js`). Existing files are reused without renaming; the filetype also
follows connection changes. Results choose their filetype from the source
snapshot and update it even when the result buffer already exists.

`DbCSVView` / `csv_view(opts)` reruns a query in a separate CSV buffer. The
`csvview.nvim` plugin is optional, but required for this command. From a result
buffer, it uses `b:dbsh_result_query`, not the decorated buffer text or the
last query from another view. It follows the same safety-confirmation and
`resolve.preamble` path as ordinary queries. Stale contexts are rejected before
opening a view.

Backends expose `csv_mode` and may also expose `csv_query(text, delimiter)`,
`csv_output(stdout, delimiter)`, and `csv_delimiter`. PostgreSQL uses
`psql --csv`, disables the footer, and sets `csv_fieldsep` before the original
SQL; there is no `COPY` wrapper, so statement terminators and comments are
preserved. Snowflake requests `--format CSV` (comma delimiter). Mongo converts
raw EJSON documents with `csv.documents_to_csv`. Nested Mongo objects become
paths; arrays and EJSON wrappers stay in a single cell, and columns are the
union of document fields.

The CSV buffer keeps its query and snapshot in `b:dbsh_csv_source` instead of
using `dbsh_context_id`, which belongs to the result registry. It is read-only,
uses `bufhidden=wipe`, follows `results_split`, and does not steal focus when
asynchronous output arrives. `DbCancel` uses its snapshot, and query-reading
mappings refuse this buffer. CSVView's parser options set the delimiter, quote
character, and first-line header, and disable comment prefixes from the user's
personal configuration.

The result window's focus behavior is derived from `results_split`; there is no
separate focus option. A split stays beside the SQL buffer and never takes the
cursor. A floating window covers it and takes focus when the query starts, so
its `q` and `<Esc>` mappings can be used. Only `running` moves focus: `render`
runs in a CLI callback, long after the user may have moved elsewhere, and
asynchronously stealing focus is worse than leaving it alone. Functions that
read the current buffer (`query_paragraph`, `query_current_line`, and
`query_selection`) refuse `__DBSH__` buffers: mappings are global, and the
first paragraph in a result is the echoed query. `M.query` has no such guard;
it receives its query text as an argument.

`definitions.lua` keeps one DDL buffer per public object identity: backend,
public connection fingerprint, effective levels, type, and OID (or qualified
name). The key contains no password, raw connection string, or SQL.

Definitions keep the snapshot captured when they open. The `definition` slot
in `exec.lua` therefore uses that context even if the user changes connections
in another buffer. Opening a new definition from a definition buffer creates a
split instead of replacing the visible DDL.

## Execution and Safety

`exec.lua` has per-session slots: `user`, `introspect`, and `definition`.
`run` writes a temporary SQL script; `run_argv` executes an argv supplied by a
backend without a temporary script or logging arguments and environment
variables. A backend can prepare a private asynchronous runtime. For
Snowflake, this runtime holds only an in-memory password from a
`password_command` argv, passed to the child `snow` process as
`SNOWFLAKE_PASSWORD`. Secrets must never enter the public context, catalog
keys, result buffers, errors, or persistent storage.

`progress.lua` reports in-flight operations in two places: the winbar of the
window that will show the output, and a notification titled with the connection
name. It only requires `config`; the caller supplies the window as a
`function(): integer|nil` resolver, avoiding the
`definitions → exec → progress → definitions` dependency cycle. `exec.lua` is
the only module that starts and stops progress, through both of its entry
points. It keeps a registry of IDs keyed by `"<session_id>/<slot>"`: after a
process starts, its slot holds the process handle instead of the operation, so
the progress ID would otherwise be unavailable to cancellation. Progress starts
before `backend.prepare`, so it includes backend authentication. The indicator
receives only a public title and summary, never argv, an environment, or a
`runtime`.

When a recognized authentication error occurs, `exec` calls the optional
`backend.invalidate_credentials(connection, key)` hook before its one retry.
MongoDB uses it to invalidate either the AWS cache or the password cache,
depending on the profile; other backends keep the default invalidation.

`exec.compose_script` is the single point for building scripts and receives
the connection and runtime. `safety.classify` delegates to `backend.classify`;
`config.connection` uses `backend.validate`, while only `config.backend_for`
reports an unknown type. dbsh does not provide a tunnel: any SOCKS proxy must
be started outside the editor.

`safety.lua` is pure and does not depend on the UI. Its classifier is
deliberately conservative: known reads run directly, while mutations,
privilege changes, ambiguous input, and multiple statements require
confirmation by default. This is an ergonomic safeguard, not a security
boundary; database permissions remain authoritative. `dbsh.query` asks for
confirmation before resolving variables, then executes with the captured
snapshot.

## Commands and UI

`init.lua` declares generic commands and the union of commands in
`backend.contexts` and `backend.catalogs`. Each command is checked against the
backend of the active buffer. `telescope/pickers.lua` is generic: it handles
connections, scratchpads, contexts, catalogs, and definitions. Telescope is
optional; affected commands fall back to a Neovim UI or show a clear error.
Every Telescope picker filters its loaded entries locally: typing does not run
a query or reopen the picker. Paginated catalogs keep an explicit “Load more”
action; `query` values passed to the Lua API are still sent to the backend.

`DbTemp` provides a `new_buffer_previewer` through
`telescope/scratch_preview.lua`. It copies contents from a buffer that is
already loaded, including unsaved changes; otherwise, it delegates the
asynchronous read to Telescope's `buffer_previewer_maker`. Syntax highlighting
follows the backend metadata, including for older Mongo scratchpads with a
`.sql` extension. Creation entries, invalid metadata, and missing files show a
message. The preview does not call `scratch.open`, attach a context, or run a
query.

`DbTables` is the PostgreSQL compatibility contract; `DbRelations` is the
canonical relation browser. Do not restore `backend.levels` or global
navigation.

## Persistence

CSV exports, variable history, and scratchpad metadata and files live under
`stdpath("data")/dbsh/`. Always create the parent directory with
`vim.fn.mkdir(dir, "p")` before writing. Secrets are never copied to this
persistent storage.

## Style, Errors, and Tests

Neovim ≥ 0.10 and LuaJIT/Lua 5.1: no `goto` or bitwise operators. Use tabs for
indentation. Comments should explain why; identifiers and code comments stay in
English.

Do not call `error()` on a user-facing path. Synchronous paths return
`nil, err`; asynchronous paths follow their module's contract. Notifications
use `vim.notify` with the standard prefix.

Run the MiniTest suite with `make test`. Use a `tests/test_<module>.lua` file,
`tests/helpers.lua`, and `vim.wait` for asynchronous code. Test seams are
reassignable fields: `exec.runner`, `pickers._telescope`, the LSP seams
(`start_client`, `attach_client`, `detach_client`, `request`, `stop_client`,
diagnostics, and timers), and pure modules (`safety.classify`, backend query
builders). Restore all injected fields in test hooks.

## PgLS

`lsp.mode` is `off`, `external`, or `managed`. The legacy boolean
`lsp.enabled = true` remains a deprecated alias for `external`; `false` remains
`off`. The `external` mode targets only a PgLS client owned by the user: it
sends configuration without a password and invalidates its cache after a
query, but never manages the client's lifecycle. Its status must mention the
**last-synchronized context wins** limitation.

The `managed` mode applies only to PostgreSQL. It owns native Neovim clients
indexed by the public connection fingerprint, effective database, project
root, and resolved `search_path`. The password stays in memory and is sent only
through `pgls/set_configuration_overrides`; it must never appear in a key,
status, notification, log, or persisted configuration. Pool strategies are
`immediate`, `idle`, and `session`. Context reconciliation detaches only
managed clients and resets only their diagnostic namespace.

`DbLspStatus` displays only the active context's public state. Managed mode
requires PgLS 0.26.0 or newer (tested with 0.28.1) and uses its official
persistent-override layer. No patched binary is required.

Commit messages follow Conventional Commits, in English.

## Snowflake

The Snowflake backend uses only `snow sql` with a structured temporary
connection. Profiles contain neither a JDBC URL nor a literal password. Role,
warehouse, database, and schema flags represent the effective context; a `USE`
statement typed in SQL does not change dbsh's context.

Snowflake catalogs use `JSON_EXT`. Multi-statement queries, such as `SHOW`
followed by `RESULT_SCAN`, return multiple result sets. The parser uses the
last result set, which contains the selection, filter, and pagination results.
Categories with a schema use the generic scope; account-level categories do not
ask for one.

The credentials cache is in memory, expires by TTL, is invalidated after a
recognized authentication error, and is cleared when Neovim exits. Snowflake
permissions remain the security boundary.
