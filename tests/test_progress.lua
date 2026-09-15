local helpers = dofile("tests/helpers.lua")
local eq, expect_match = helpers.eq, helpers.expect_match

local config = require("dbsh.config")
local progress = require("dbsh.progress")

local original_clock
local original_timer_factory
local now
local timers

local function fake_timer()
	local timer = { started = false, stopped = false, closed = false }
	function timer:start(_, _, callback)
		self.started = true
		self.callback = callback
	end
	function timer:stop()
		self.stopped = true
	end
	function timer:close()
		self.closed = true
	end
	table.insert(timers, timer)
	return timer
end

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			config.setup({ connections = {} })
			progress.stop_all()
			progress.state.replaceable = nil
			now = 1000
			timers = {}
			original_clock = progress.clock
			original_timer_factory = progress.timer_factory
			progress.clock = function() return now end
			progress.timer_factory = fake_timer
		end,
		post_case = function()
			progress.stop_all()
			progress.clock = original_clock
			progress.timer_factory = original_timer_factory
		end,
	},
})

T["collapses whitespace and truncates on characters"] = function()
	eq(progress.summarize("SELECT   1\n\nFROM t", 60), "SELECT 1 FROM t")
	eq(progress.summarize("", 60), "query")
	eq(progress.summarize("ééééééé", 4), "ééé…")
end

T["formats elapsed time below and above a minute"] = function()
	eq(progress.elapsed_text(0), "0s")
	eq(progress.elapsed_text(12400), "12s")
	eq(progress.elapsed_text(63000), "1m03s")
end

T["advances the spinner with the clock"] = function()
	local first = progress.frame(0)
	local second = progress.frame(100)
	eq(first ~= second, true)
	eq(progress.frame(0), progress.frame(1000))
end

T["registers an operation and starts the timer once"] = function()
	local a = progress.start({ title = "heimdall", summary = "SELECT 1" })
	local b = progress.start({ title = "heimdall", summary = "SELECT 2" })
	eq(type(a), "number")
	eq(#timers, 1)
	eq(timers[1].started, true)
	progress.finish(a, { ok = true })
	eq(timers[1].stopped, false)
	progress.finish(b, { ok = true })
	eq(timers[1].stopped, true)
	eq(timers[1].closed, true)
end

T["renders nothing before the delay and a full line after"] = function()
	local id = progress.start({ title = "heimdall", summary = "SELECT * FROM users" })

	now = now + 200
	progress.tick()
	eq(progress.state.operations[id].rendered, nil)

	now = now + 200
	progress.tick()
	expect_match(progress.state.operations[id].rendered, "executing SELECT %* FROM users")
	expect_match(progress.state.operations[id].rendered, "0s")
end

T["relabels without restarting the clock"] = function()
	local id = progress.start({ title = "heimdall", summary = "SELECT 1" })
	now = now + 5000
	progress.relabel(id, "re-authenticating")
	progress.tick()
	expect_match(progress.state.operations[id].rendered, "re%-authenticating")
	expect_match(progress.state.operations[id].rendered, "5s")
end

T["returns nil and registers nothing when disabled"] = function()
	config.setup({ connections = {}, progress = { enabled = false } })
	eq(progress.start({ title = "heimdall", summary = "SELECT 1" }), nil)
	eq(next(progress.state.operations), nil)
	eq(#timers, 0)
end

T["ignores a nil id"] = function()
	progress.finish(nil, { ok = true })
	progress.relabel(nil, "loading")
	eq(next(progress.state.operations), nil)
end

T["stop_all empties the registry"] = function()
	progress.start({ title = "heimdall", summary = "SELECT 1" })
	progress.start({ title = "heimdall", summary = "SELECT 2" })
	progress.stop_all()
	eq(next(progress.state.operations), nil)
	eq(timers[1].closed, true)
end

T["replaces a single bubble when the notifier supports it"] = function()
	local original_notify = vim.notify
	local calls = {}
	vim.notify = function(message, level, opts)
		table.insert(calls, { message = message, level = level, opts = opts or {} })
		return { record = #calls }
	end

	local id = progress.start({ title = "heimdall", summary = "SELECT 1" })
	now = now + 400
	progress.tick()
	now = now + 100
	progress.tick()
	progress.finish(id, { ok = true })

	vim.notify = original_notify
	eq(#calls, 3)
	expect_match(calls[1].message, "dbsh.nvim: heimdall — .*executing SELECT 1")
	eq(calls[1].opts.timeout, false)
	eq(calls[1].opts.replace, nil)
	eq(calls[2].opts.replace ~= nil, true)
	eq(calls[2].message:find("dbsh.nvim") == nil, true)
	expect_match(calls[3].message, "done in 0s")
	eq(calls[3].opts.timeout, nil)
end

T["emits exactly two dry notifications without a capable notifier"] = function()
	local original_notify = vim.notify
	local calls = {}
	vim.notify = function(message, level, opts)
		table.insert(calls, { message = message, level = level, opts = opts or {} })
		return nil
	end

	local id = progress.start({ title = "heimdall", summary = "SELECT 1" })
	now = now + 400
	progress.tick()
	now = now + 100
	progress.tick()
	now = now + 100
	progress.tick()
	progress.finish(id, { ok = true })

	vim.notify = original_notify
	eq(#calls, 2)
	expect_match(calls[1].message, "dbsh.nvim: heimdall — .*executing SELECT 1")
	expect_match(calls[2].message, "dbsh.nvim: heimdall — done in 0s")
end

T["stays silent for an operation that never reached the delay"] = function()
	local original_notify = vim.notify
	local calls = 0
	vim.notify = function()
		calls = calls + 1
		return nil
	end

	local id = progress.start({ title = "heimdall", summary = "SELECT 1" })
	now = now + 80
	progress.tick()
	progress.finish(id, { ok = true })

	vim.notify = original_notify
	eq(calls, 0)
end

T["reports a failed outcome with its message"] = function()
	local original_notify = vim.notify
	local calls = {}
	vim.notify = function(message, level, opts)
		table.insert(calls, { message = message, level = level, opts = opts or {} })
		return nil
	end

	local id = progress.start({ title = "heimdall", summary = "SELECT 1" })
	now = now + 400
	progress.tick()
	now = now + 2000
	progress.finish(id, { ok = false, message = "cancelled" })

	vim.notify = original_notify
	eq(#calls, 2)
	expect_match(calls[2].message, "cancelled after 2s")
	eq(calls[2].level, vim.log.levels.WARN)
end

return T
