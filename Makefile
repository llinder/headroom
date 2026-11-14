build:
	swift build -c release

test:
	swift test

install: build
	.build/release/headroom install

.PHONY: build test install
