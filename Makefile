.PHONY: test snowflake-smoke mongo-aws-smoke

test:
	nvim --headless --noplugin -u tests/minimal_init.lua \
		-c "lua MiniTest.run()"

snowflake-smoke:
	nvim --headless --noplugin -u tests/minimal_init.lua \
		-l tests/snowflake_smoke.lua -- --self-test
	nvim --headless --noplugin -u tests/minimal_init.lua \
		-l tests/snowflake_smoke.lua

mongo-aws-smoke:
	nvim --headless --noplugin -u tests/minimal_init.lua \
		-l tests/mongo_aws_smoke.lua
