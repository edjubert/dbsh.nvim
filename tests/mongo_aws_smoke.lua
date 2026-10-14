-- Opt-in authentication check using the production backend, without reading
-- application collections or printing credentials and raw CLI errors.
local mongo = require("dbsh.backends.mongo")
local aws = require("dbsh.aws")

local connection = {
	type = "mongo", auth = "aws", srv = true,
	host = vim.env.DBSH_MONGO_HOST,
	database = vim.env.DBSH_MONGO_DATABASE or "admin",
	aws_profile = vim.env.DBSH_MONGO_AWS_PROFILE,
	read_preference = "secondary",
}
if vim.env.DBSH_MONGO_PROXY_HOST ~= nil then
	connection.proxy = {
		host = vim.env.DBSH_MONGO_PROXY_HOST,
		port = tonumber(vim.env.DBSH_MONGO_PROXY_PORT),
	}
end

local valid, err = mongo.validate(connection)
if not valid then
	print("Mongo AWS smoke: " .. err)
	vim.cmd("cq!")
	return
end

local done, passed = false, false
local process
mongo.prepare({ connection = connection, connection_name = "mongo-aws-smoke" }, {}, function(runtime, prepare_err)
	if prepare_err ~= nil then
		print("Mongo AWS smoke: " .. prepare_err)
		done = true
		return
	end
	local queries = { "db.runCommand({ping: 1})", "db.runCommand({connectionStatus: 1})" }
	local function probe(index)
		process = vim.system(mongo.argv(connection, "/dev/stdin"), {
			text = true, timeout = 20000,
			stdin = mongo.compose(queries[index], "raw", connection, runtime),
			env = mongo.env(connection, {}, runtime),
		}, vim.schedule_wrap(function(result)
			if result.code ~= 0 then
				local output = (result.stderr or "") .. (result.stdout or "")
				print("Mongo AWS smoke: exit " .. tostring(result.code) .. ", category: "
					.. (output:match("(Mongo[%w]+Error)") or "timeout or process error"))
				done = true
				return
			end
			local ok, data = pcall(vim.json.decode, result.stdout or "")
			if not ok or type(data) ~= "table" or data.ok ~= 1 then
				print("Mongo AWS smoke: invalid command response")
				done = true
				return
			end
			if index == 1 then
				probe(2)
				return
			end
			passed = type(data.authInfo) == "table"
				and type(data.authInfo.authenticatedUsers) == "table"
				and #data.authInfo.authenticatedUsers > 0
			print(passed and "Mongo AWS smoke: PASS (ping and authenticated session)"
				or "Mongo AWS smoke: response did not confirm authentication")
			done = true
		end))
	end
	probe(1)
end)

if not vim.wait(75000, function() return done end, 50) then
	if process ~= nil then process:kill(15) end
	print("Mongo AWS smoke: deadline exceeded")
end
aws.clear()
vim.cmd(passed and "qa!" or "cq!")
