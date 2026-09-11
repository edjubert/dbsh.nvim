local helpers = dofile("tests/helpers.lua")
local eq = helpers.eq

local safety = require("dbsh.safety")

local T = MiniTest.new_set()

T["runs read-only statements without confirmation"] = function()
	for _, sql in ipairs({
		"SELECT 1",
		"SHOW search_path",
		"DESCRIBE users",
		"DESC users",
		"EXPLAIN ANALYZE DELETE FROM users",
		"-- a leading comment\n /* another */ SELECT 1",
		"WITH recent AS (SELECT 1) SELECT * FROM recent",
	}) do
		eq(safety.classify(sql), { action = "run", reason = "read" })
	end
end

T["confirms mutations and privilege changes"] = function()
	for _, sql in ipairs({
		"INSERT INTO users VALUES (1)",
		"UPDATE users SET active = true",
		"DELETE FROM users",
		"MERGE INTO users u USING source s ON true WHEN MATCHED THEN UPDATE SET active = true",
		"COPY users TO STDOUT",
		"CREATE TABLE users (id integer)",
		"ALTER TABLE users ADD COLUMN email text",
		"DROP TABLE users",
		"TRUNCATE users",
		"COMMENT ON TABLE users IS 'internal'",
		"VACUUM users",
		"ANALYZE users",
		"CALL refresh_cache()",
		"WITH source AS (SELECT 1) INSERT INTO users SELECT * FROM source",
		"WITH changed AS (DELETE FROM users RETURNING id) SELECT * FROM changed",
	}) do
		eq(safety.classify(sql), { action = "confirm", reason = "mutation" })
	end
	for _, sql in ipairs({ "GRANT SELECT ON users TO reader", "REVOKE SELECT ON users FROM reader" }) do
		eq(safety.classify(sql), { action = "confirm", reason = "privilege" })
	end
end

T["keeps semicolons in strings, identifiers, dollar quotes, and comments inside one statement"] = function()
	for _, sql in ipairs({
		"SELECT ';' AS punctuation",
		'SELECT "semi;colon" FROM users',
		"SELECT $$a;b$$",
		"SELECT $tag$a;b$tag$",
		"SELECT 1 -- ;\n",
		"SELECT /* ; */ 1",
	}) do
		eq(safety.classify(sql), { action = "run", reason = "read" })
	end
end

T["confirms unknown, malformed, and genuinely multi-statement SQL"] = function()
	for _, sql in ipairs({
		"SET ROLE reader",
		"USE reporting",
		"/* only a comment */",
		"SELECT 'unterminated",
		"SELECT /* unterminated",
	}) do
		eq(safety.classify(sql), { action = "confirm", reason = "ambiguous" })
	end
	for _, sql in ipairs({
		"SELECT 1; SELECT 2",
		"SELECT 1; -- end\n SELECT 2",
		"DELETE FROM users; VACUUM users",
	}) do
		eq(safety.classify(sql), { action = "confirm", reason = "multiple_statements" })
	end
end

return T
