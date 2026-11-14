build:
	swift build -c release

test:
	swift test

install: build
	.build/release/headroom install

bench:
	swift build -c release && HEADROOM_BENCH=1 swift test --filter 'readerSpeed|samplingPassBudget|statuslineSpeed|releaseBinaryHookIsFast'

.PHONY: build test bench install
