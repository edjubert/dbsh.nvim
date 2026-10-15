-- Parsing of the table psql draws with box-drawing characters, and CSV
-- serialization of the cells it holds. Every function here is pure: no
-- buffer, no configuration, no visual selection.

local M = {}

local BORDER = "│"

-- Visual mode names, as returned by vim.fn.mode().
M.LINEWISE = "V"
M.BLOCKWISE = "\22"

-- Splits a rendered row into its cells. Frame lines (┌─┬─┐, ├─┼┤, └─┴─┘)
-- carry no vertical border and therefore yield no cell at all.
-- from/to are 1-based inclusive byte offsets of the cell inside the line.
function M.split_cells(line)
	local cells = {}
	local pos = 1
	while true do
		local bstart, bend = line:find(BORDER, pos, true)
		if bstart == nil then
			break
		end
		-- Whatever sits before the very first border is outside the table.
		if pos > 1 then
			table.insert(cells, {
				text = vim.trim(line:sub(pos, bstart - 1)),
				from = pos,
				to = bstart - 1,
			})
		end
		pos = bend + 1
	end
	return cells
end

-- Keeps the cells whose byte range intersects [from, to].
function M.cells_in_range(cells, from, to)
	local kept = {}
	for _, cell in ipairs(cells) do
		if cell.from <= to and cell.to >= from then
			table.insert(kept, cell)
		end
	end
	return kept
end

-- mode is M.LINEWISE (every column) or M.BLOCKWISE (only the columns
-- touched by [col_from, col_to]). Lines holding no cell are dropped, which
-- silently discards frame lines and the echoed query.
function M.rows_from_lines(lines, mode, col_from, col_to)
	local rows = {}
	for _, line in ipairs(lines) do
		local cells = M.split_cells(line)
		if mode == M.BLOCKWISE then
			cells = M.cells_in_range(cells, col_from, col_to)
		end

		local values = {}
		for _, cell in ipairs(cells) do
			table.insert(values, cell.text)
		end
		if #values > 0 then
			table.insert(rows, values)
		end
	end
	return rows
end

-- Quotes a field holding the delimiter, a quote or a newline, doubling
-- inner quotes, per RFC 4180.
function M.escape_field(value, delimiter)
	local needs_quotes = value:find('"', 1, true) ~= nil
		or value:find("\n", 1, true) ~= nil
		or value:find("\r", 1, true) ~= nil
		or value:find(delimiter, 1, true) ~= nil
	if not needs_quotes then
		return value
	end
	return '"' .. (value:gsub('"', '""')) .. '"'
end

function M.to_csv(rows, delimiter)
	local lines = {}
	for _, row in ipairs(rows) do
		local fields = {}
		for _, value in ipairs(row) do
			table.insert(fields, M.escape_field(value, delimiter))
		end
		table.insert(lines, table.concat(fields, delimiter))
	end
	return table.concat(lines, "\n")
end

-- EJSON scalar wrappers stay in one cell; arrays remain JSON rather than
-- multiplying documents into rows. Nested document paths become columns.
local function flatten(value, path, fields)
	if type(value) ~= "table" or vim.islist(value) or next(value) == nil then
		fields[path ~= "" and path or "value"] = value
		return
	end
	for key in pairs(value) do
		if type(key) == "string" and key:sub(1, 1) == "$" then
			fields[path ~= "" and path or "value"] = value
			return
		end
	end
	for key, child in pairs(value) do
		-- Escape dots/backslashes in literal field names so "address.city"
		-- cannot overwrite the nested address.city path.
		local name = tostring(key):gsub("\\", "\\\\"):gsub("%.", "\\.")
		flatten(child, path == "" and name or path .. "." .. name, fields)
	end
end

local function document_cell(value)
	if value == nil or value == vim.NIL then return "" end
	if type(value) ~= "table" then return tostring(value) end
	if value["$oid"] ~= nil then return tostring(value["$oid"]) end
	if type(value["$date"]) == "string" then return value["$date"] end
	for _, key in ipairs({ "$numberLong", "$numberDecimal", "$numberDouble", "$numberInt" }) do
		if value[key] ~= nil then return tostring(value[key]) end
	end
	return vim.json.encode(value)
end

function M.documents_to_csv(documents, delimiter)
	if #documents == 0 then return nil, "no documents to display as CSV" end
	local columns, seen, flattened = {}, {}, {}
	for _, document in ipairs(documents) do
		local fields = {}
		flatten(document, "", fields)
		table.insert(flattened, fields)
		for key in pairs(fields) do
			if not seen[key] then
				seen[key] = true
				table.insert(columns, key)
			end
		end
	end
	table.sort(columns, function(a, b)
		if a == "_id" then return b ~= "_id" end
		if b == "_id" then return false end
		return a < b
	end)
	local rows = { columns }
	for _, fields in ipairs(flattened) do
		local row = {}
		for _, column in ipairs(columns) do table.insert(row, document_cell(fields[column])) end
		table.insert(rows, row)
	end
	return M.to_csv(rows, delimiter)
end

return M
