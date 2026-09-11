.PHONY: test snowflake-smoke

test:
	nvim --headless --noplugin -u tests/minimal_init.lua \
		-c "lua MiniTest.run()"

snowflake-smoke:
	nvim --headless --noplugin -u tests/minimal_init.lua \
		-l tests/snowflake_smoke.lua -- --self-test
	nvim --headless --noplugin -u tests/minimal_init.lua \
		-l tests/snowflake_smoke.lua
