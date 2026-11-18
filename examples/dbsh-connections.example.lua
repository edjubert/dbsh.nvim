-- Example dbsh connections file.
--
-- Copy this file somewhere your Neovim configuration can require, for example
-- ~/.config/nvim/lua/config/dbsh-connections.lua, then load it with:
--
--   require("dbsh").setup(require("config.dbsh-connections"))
--
-- Keep the copy out of version control: it names hosts, users, and AWS
-- profiles. Only this example belongs in the repository.
--
-- No password is written here. PostgreSQL passwords come from ~/.pgpass,
-- Snowflake and MongoDB passwords from the macOS Keychain.

local credentials = require("dbsh.credentials")

return {
	connections = {
		-- PostgreSQL. `password` is a callback, invoked only when a managed
		-- PgLS client attaches; SQL execution never needs it because psql
		-- reads ~/.pgpass itself.
		local_db = {
			host = "127.0.0.1",
			port = 5432,
			database = "app",
			username = "app",
			schema = "public",
			search_path = { "extensions", "public" },
			password = credentials.pgpass,
		},

		-- PostgreSQL on a remote host, same password resolution.
		analytics = {
			host = "<host>",
			port = 5432,
			database = "<database>",
			username = "<username>",
			password = credentials.pgpass,
		},

		-- Snowflake through a native SSO authenticator. The password is read
		-- from the Keychain item named below, never from this file.
		warehouse = {
			type = "snowflake",
			host = "<account-host>",
			port = 443,
			username = "<username>",
			authenticator = "<native-sso-authenticator-url>",
			role = "<role>",
			warehouse = "<warehouse>",
			database = "<database>",
			schema = "<optional-schema>",
			password_command = credentials.keychain("dbsh.snowflake.warehouse"),
		},

		-- MongoDB Atlas with password authentication.
		atlas = {
			type = "mongo",
			srv = true,
			host = "<cluster>.mongodb.net",
			username = "<username>",
			database = "<database>",
			password_command = credentials.keychain("dbsh.mongo.atlas"),
		},

		-- MongoDB Atlas with AWS IAM authentication. The AWS CLI profile
		-- supplies the credentials, so no password command is involved.
		atlas_aws = {
			type = "mongo",
			auth = "aws",
			srv = true,
			host = "<cluster>.mongodb.net",
			database = "<database>",
			aws_profile = "<AWS CLI profile>",
			read_preference = "secondary",
		},
	},

	-- Connection selected at startup. Must exist in `connections`.
	default = "local_db",
}
