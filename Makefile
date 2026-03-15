.PHONY: lib app run test clean

lib:
	zig build

app: lib
	zig build app

run: app
	zig build run

test:
	zig build test

clean:
	rm -rf zig-out .zig-cache
