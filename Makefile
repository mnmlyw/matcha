.PHONY: lib app run test swift-test clean

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

clean:
	rm -rf zig-out .zig-cache
