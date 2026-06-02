.PHONY: lib app run test swift-test fmt-check check clean

lib:
	zig build

app: lib
	zig build app

run: app
	zig build run

test:
	zig build test

swift-test: lib
	zig build swift-test

fmt-check:
	zig build fmt-check

check:
	zig build check

clean:
	rm -rf zig-out .zig-cache
