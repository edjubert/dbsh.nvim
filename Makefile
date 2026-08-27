.PHONY: test

test:
	nvim --headless --noplugin -u tests/minimal_init.lua \
		-c "lua MiniTest.run()"
