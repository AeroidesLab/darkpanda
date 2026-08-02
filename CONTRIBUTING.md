# Contributing

Lightpanda accepts pull requests through GitHub.

## Development

- Run the tests: `make test`
- Check formatting: `zig fmt --check ./*.zig ./**/*.zig`
- Smoke-test the native C toolchain: `make pffft`

See [AGENTS.md](AGENTS.md) for the full set of test, formatting, and code conventions (test filters, the leak-detection invariant, `@import` alias case, struct-init inference).

### Native build inputs

Native checks, tests, and installs require absolute `CANVAS_DIST`,
`HTML5EVER_DIST`, `WREQ_DIST`, and `BORINGSSL_DIST` paths. The `v8` Zig package
must be checked out at `../zig-v8-fork`; set `V8_ARCHIVE` to a compatible
prebuilt archive to avoid compiling V8 from source.

On macOS, install the Xcode command-line tools and use `macos-aarch64` component
distributions on Apple silicon or `macos-x86_64` distributions on Intel. The
browser build graph and PFFFT dependency support both architectures, but the
complete runtime remains blocked until the Canvas component publishes the same
macOS distribution contract as the other native components.

## Before opening a PR

- [ ] Tests pass (`make test`).
- [ ] Formatting is clean (`zig fmt --check ./*.zig ./**/*.zig`).
- [ ] CLA signed (see below).

## CLA

You have to sign our [CLA](CLA.md) during your first pull request process
otherwise we're not able to accept your contributions.

The process signature uses the [CLA assistant
lite](https://github.com/marketplace/actions/cla-assistant-lite). You can see
an example of the process in [#303](https://github.com/lightpanda-io/browser/pull/303).
