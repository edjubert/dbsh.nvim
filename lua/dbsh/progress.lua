-- Reports in-flight CLI operations. Every operation is owned by dbsh.exec;
-- nothing here knows about backends, connections or credentials.

local config = require("dbsh.config")

local M = {}

local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local FRAME_MS = 100
local SAFE_OPTIONS = { enabled = false, delay_ms = 300, summary_width = 60 }

-- Injection points: this repo has no mock framework, tests reassign these.
M.clock = function()
	return vim.uv.now()
end

M.timer_factory = function()
	return vim.uv.new_timer()
end

M.state = {
	operations = {},
	next_id = 1,
	timer = nil,
	-- nil until the first notification tells us whether the notifier can
	-- replace a bubble. Native vim.notify cannot.
	replaceable = nil,
}

local function options()
	local opts = config.options().progress
	if type(opts) ~= "table" then
		return SAFE_OPTIONS
	end
	return opts
end

-- Truncates on characters, never bytes: the summary is user-written SQL and
-- may be multibyte.
function M.summarize(text, width)
	local compact = vim.trim((tostring(text or "")):gsub("%s+", " "))
	if compact == "" then
		return "query"
	end
	if vim.fn.strchars(compact) <= width then
		return compact
	end
	return vim.fn.strcharpart(compact, 0, width - 1) .. "…"
end

function M.elapsed_text(ms)
	local seconds = math.floor(ms / 1000)
	if seconds < 60 then
		return string.format("%ds", seconds)
	end
	return string.format("%dm%02ds", math.floor(seconds / 60), seconds % 60)
end

function M.frame(ms)
	return SPINNER[(math.floor(ms / FRAME_MS) % #SPINNER) + 1]
end

local function stop_timer()
	local timer = M.state.timer
	if timer == nil then
		return
	end
	M.state.timer = nil
	-- An unclosed uv timer leaks once per query.
	pcall(function()
		timer:stop()
		timer:close()
	end)
end

local function ensure_timer()
	if M.state.timer ~= nil then
		return
	end
	local timer = M.timer_factory()
	if timer == nil then
		return
	end
	M.state.timer = timer
	timer:start(FRAME_MS, FRAME_MS, vim.schedule_wrap(function()
		M.tick()
	end))
end

-- The title is dropped by native vim.notify, so the body carries the connection
-- name until we know the notifier can replace a bubble.
local function notification_body(operation, text)
	if M.state.replaceable == true then
		return text
	end
	return string.format("dbsh.nvim: %s — %s", operation.title, text)
end

local function notification_options(operation)
	return {
		title = operation.title,
		id = "dbsh.progress." .. operation.id,
		replace = operation.notification,
	}
end

local function update_notification(operation, text)
	-- Without replacement, one bubble per tick would be a flood.
	if operation.notified and M.state.replaceable == false then
		return
	end
	local opts = notification_options(operation)
	opts.timeout = false
	opts.hide_from_history = true
	local record = vim.notify(notification_body(operation, text), vim.log.levels.INFO, opts)
	if M.state.replaceable == nil then
		M.state.replaceable = record ~= nil
	end
	if record ~= nil then
		operation.notification = record
	end
	operation.notified = true
end

local function close_notification(operation, outcome)
	-- An operation that never crossed the delay stays silent to the end.
	if not operation.notified then
		return
	end
	local elapsed = M.elapsed_text(M.clock() - operation.started_at)
	local text, level
	if outcome.ok then
		text = string.format("done in %s", elapsed)
		level = vim.log.levels.INFO
	else
		text = string.format("%s after %s", outcome.message or "failed", elapsed)
		level = vim.log.levels.WARN
	end
	-- No timeout override here: the terminal bubble is meant to fade.
	vim.notify(notification_body(operation, text), level, notification_options(operation))
	operation.notification = nil
end

-- spec = {
--   title   = string,                     -- connection name, notification title
--   summary = string,                     -- raw SQL or object label
--   label   = string?,                    -- verb, defaults to "executing"
--   window  = (function(): integer|nil)?, -- resolver, nil means notification only
-- }
function M.start(spec)
	local opts = options()
	if opts.enabled ~= true or type(spec) ~= "table" then
		return nil
	end
	local id = M.state.next_id
	M.state.next_id = id + 1
	M.state.operations[id] = {
		id = id,
		title = spec.title or "dbsh.nvim",
		label = spec.label or "executing",
		summary = M.summarize(spec.summary, opts.summary_width),
		window = type(spec.window) == "function" and spec.window or nil,
		started_at = M.clock(),
		rendered = nil,
		notification = nil,
		notified = false,
	}
	ensure_timer()
	return id
end

function M.relabel(id, label)
	local operation = M.state.operations[id]
	if operation == nil or type(label) ~= "string" then
		return
	end
	operation.label = label
end

function M.finish(id, outcome)
	local operation = M.state.operations[id]
	if operation == nil then
		return
	end
	M.state.operations[id] = nil
	close_notification(operation, outcome or {})
	if next(M.state.operations) == nil then
		stop_timer()
	end
end

function M.stop_all()
	for id in pairs(M.state.operations) do
		M.finish(id, { ok = false })
	end
	M.state.operations = {}
	stop_timer()
end

function M.tick()
	local now = M.clock()
	local delay = options().delay_ms
	for _, operation in pairs(M.state.operations) do
		local elapsed = now - operation.started_at
		if elapsed >= delay then
			operation.rendered = string.format(
				"%s %s %s  %s",
				M.frame(elapsed),
				operation.label,
				operation.summary,
				M.elapsed_text(elapsed)
			)
			update_notification(operation, operation.rendered)
		end
	end
end

return M
