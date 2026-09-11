# Snowflake smoke test

The opt-in `make snowflake-smoke` target validates a private Snowflake connection before the
Snowflake backend is enabled in dbsh. It runs a fixed, read-only query for the effective session
context; it does not query business data or perform DDL, DML, grants, role changes, warehouse
changes, or configuration changes.

The target first runs local fakes, then reads these environment variables only:

```sh
export DBSH_SNOWFLAKE_HOST='<account-host>'
export DBSH_SNOWFLAKE_PORT='443'
export DBSH_SNOWFLAKE_USERNAME='<user>'
export DBSH_SNOWFLAKE_AUTHENTICATOR='<native-sso-authenticator-url>'
export DBSH_SNOWFLAKE_ROLE='<role>'
export DBSH_SNOWFLAKE_WAREHOUSE='<warehouse>'
export DBSH_SNOWFLAKE_DATABASE='<database>'
export DBSH_SNOWFLAKE_SCHEMA='<optional-schema>'
export DBSH_SNOWFLAKE_PASSWORD_COMMAND_JSON='["security","find-generic-password","-s","dbsh.snowflake.<profile>","-w"]'
```

`DBSH_SNOWFLAKE_PASSWORD_COMMAND_JSON` is a JSON argv array, not a shell command. Its standard
output is trimmed in memory and supplied only as `SNOWFLAKE_PASSWORD` to the child `snow sql`
process. Never add a literal password, a JDBC URL, a Snow CLI profile, command output, or any
private connection value to the repository.

The smoke invocation uses a temporary structured connection:

```text
snow sql --temporary-connection --account <host-first-label> --host <host> --port <port> --user <user>
  --authenticator <authenticator> --role <role> --warehouse <warehouse>
  --database <database> [--schema <schema>] --format JSON_EXT --silent --query <read-only-query>
```

Snowflake CLI requires an account identifier in addition to the host. The smoke derives it from
the first DNS label of `DBSH_SNOWFLAKE_HOST`, so no additional private environment variable is
needed.

Run it only after exporting private values in the current shell:

```sh
make snowflake-smoke
```

A successful run prints only:

```text
dbsh snowflake smoke: authenticated JSON_EXT result received
```

Failures are sanitized: the password, command output, and full child environment are never
printed.

The production backend uses the same temporary connection flags with `--filename <sql-file>`.
It never creates a persistent Snow CLI connection. Its password cache is in memory only,
defaults to 15 minutes, is cleared when Neovim exits, and is invalidated before one recognized
authentication retry.

Snowflake contexts are role, warehouse, database and schema. dbsh passes them as CLI flags for
each command; a manually typed `USE` affects that command only. Catalogs use `JSON_EXT` and
include account-level categories through `SHOW` plus `RESULT_SCAN`, and database categories
through paged, literal-filtered information-schema queries. Database permissions remain the
security authority; dbsh safety confirmations do not bypass them.
