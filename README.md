# headroom

A lightweight, native macOS monitor that answers one question: is this laptop
big enough for the work being run on it?

Engineers increasingly run many things at once: several AI coding agents,
parallel Go builds and test suites, Docker image builds and local Kubernetes
clusters. headroom:

1. **Records**, continuously and without gaps, how often CPU, memory and disk
   are the limit on the machine, broken down by workload (containers, builds,
   agents) instead of by raw process.
2. **Produces evidence** from that record: a short report a non-technical
   reader can act on, ending in a concrete recommended spec.

## Install

Requires macOS and the Swift toolchain.

```sh
make install
```

Fuller build and usage documentation will follow.

## Privacy

headroom records what the machine is doing, never what the person is doing. It
never records window titles, URLs, document names, keystrokes, input idle
time, focused-app time or command arguments. Reports show workload groups,
never individual process names. All data stays on the local machine.

## License

MIT
