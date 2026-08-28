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

return M
