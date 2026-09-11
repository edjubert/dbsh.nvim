-- Conservative SQL safety classification. This is an ergonomic confirmation
-- gate, not an authorization system or a full SQL parser.

local M = {}

local READ = {
	select = true,
	show = true,
	describe = true,
	desc = true,
	explain = true,
}

local MUTATION = {
	insert = true,
	update = true,
	delete = true,
	merge = true,
	copy = true,
	create = true,
	alter = true,
	drop = true,
	truncate = true,
	comment = true,
	vacuum = true,
	analyze = true,
	call = true,
}

local PRIVILEGE = {
	grant = true,
	revoke = true,
}

local TERMINAL = {}
for keyword in pairs(READ) do
	TERMINAL[keyword] = true
end
for keyword in pairs(MUTATION) do
	TERMINAL[keyword] = true
end
for keyword in pairs(PRIVILEGE) do
	TERMINAL[keyword] = true
end

local function is_space(char)
	return char:match("%s") ~= nil
end

local function dollar_delimiter(sql, index)
	local rest = sql:sub(index)
	return rest:match("^(%$%$)") or rest:match("^(%$[%a_][%w_]*%$)")
end

local function scan(sql)
	local tokens = {}
	local length = #sql
	local index = 1
	local depth = 0
	local statement_has_code = false
	local terminated = false
	local multiple = false
	local ambiguous = false

	local function mark_code()
		if terminated then
			multiple = true
		end
		statement_has_code = true
	end

	local function add_token(value)
		table.insert(tokens, { value = value:lower(), depth = depth })
	end

	while index <= length do
		local char = sql:sub(index, index)
		local next_char = sql:sub(index + 1, index + 1)

		if is_space(char) then
			index = index + 1
		elseif char == "-" and next_char == "-" then
			local newline = sql:find("\n", index + 2, true)
			index = newline and newline + 1 or length + 1
		elseif char == "/" and next_char == "*" then
			local comment_depth = 1
			index = index + 2
			while index <= length and comment_depth > 0 do
				local current = sql:sub(index, index)
				local after = sql:sub(index + 1, index + 1)
				if current == "/" and after == "*" then
					comment_depth = comment_depth + 1
					index = index + 2
				elseif current == "*" and after == "/" then
					comment_depth = comment_depth - 1
					index = index + 2
				else
					index = index + 1
				end
			end
			if comment_depth ~= 0 then
				ambiguous = true
			end
		elseif char == "'" then
			mark_code()
			index = index + 1
			local closed = false
			while index <= length do
				local current = sql:sub(index, index)
				if current == "\\" then
					index = index + 2
				elseif current == "'" and sql:sub(index + 1, index + 1) == "'" then
					index = index + 2
				elseif current == "'" then
					index = index + 1
					closed = true
					break
				else
					index = index + 1
				end
			end
			if not closed then
				ambiguous = true
			end
		elseif char == '"' then
			mark_code()
			index = index + 1
			local closed = false
			while index <= length do
				local current = sql:sub(index, index)
				if current == '"' and sql:sub(index + 1, index + 1) == '"' then
					index = index + 2
				elseif current == '"' then
					index = index + 1
					closed = true
					break
				else
					index = index + 1
				end
			end
			if not closed then
				ambiguous = true
			end
		elseif char == "$" and dollar_delimiter(sql, index) ~= nil then
			mark_code()
			local delimiter = dollar_delimiter(sql, index)
			local closing = sql:find(delimiter, index + #delimiter, true)
			if closing == nil then
				ambiguous = true
				break
			end
			index = closing + #delimiter
		elseif char == ";" then
			if depth == 0 then
				if statement_has_code then
					terminated = true
					statement_has_code = false
				else
					ambiguous = true
				end
			else
				mark_code()
			end
			index = index + 1
		elseif char == "(" then
			mark_code()
			depth = depth + 1
			index = index + 1
		elseif char == ")" then
			mark_code()
			if depth == 0 then
				ambiguous = true
			else
				depth = depth - 1
			end
			index = index + 1
		elseif char:match("[%a_]") ~= nil then
			mark_code()
			local finish = index + 1
			while finish <= length and sql:sub(finish, finish):match("[%w_$]") ~= nil do
				finish = finish + 1
			end
			add_token(sql:sub(index, finish - 1))
			index = finish
		else
			mark_code()
			index = index + 1
		end
	end

	if depth ~= 0 then
		ambiguous = true
	end
	return {
		tokens = tokens,
		has_code = statement_has_code or terminated,
		multiple = multiple,
		ambiguous = ambiguous,
	}
end

local function decision(keyword)
	if READ[keyword] then
		return { action = "run", reason = "read" }
	end
	if MUTATION[keyword] then
		return { action = "confirm", reason = "mutation" }
	end
	if PRIVILEGE[keyword] then
		return { action = "confirm", reason = "privilege" }
	end
	return { action = "confirm", reason = "ambiguous" }
end

function M.classify(sql)
	local parsed = scan(sql or "")
	if parsed.multiple then
		return { action = "confirm", reason = "multiple_statements" }
	end
	if parsed.ambiguous or not parsed.has_code or #parsed.tokens == 0 then
		return { action = "confirm", reason = "ambiguous" }
	end

	local first = parsed.tokens[1]
	if first.value ~= "with" then
		return decision(first.value)
	end
	for index = 2, #parsed.tokens do
		local token = parsed.tokens[index]
		if MUTATION[token.value] or PRIVILEGE[token.value] then
			return decision(token.value)
		end
	end
	for index = 2, #parsed.tokens do
		local token = parsed.tokens[index]
		if token.depth == 0 and TERMINAL[token.value] then
			return decision(token.value)
		end
	end
	return { action = "confirm", reason = "ambiguous" }
end

return M
