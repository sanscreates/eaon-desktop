# Contributing to Eaon

Thanks for considering it — here's what to know before opening a PR.

## Getting set up

```sh
swift build
./run.sh
```

No external dependencies (see `Package.swift`) — this is deliberate. New
functionality (an HTTP client, a parser, a small protocol implementation)
gets hand-rolled rather than pulling in a package, so keep that pattern
unless there's a strong reason not to.

## Before opening a PR

- **Build for real.** `swift build` — don't assume a change compiles.
- **Test the actual behavior**, not just that it builds. If you're touching
  a network call, a parser, or anything with a real external API, verify it
  against the real thing where practical rather than only reasoning about
  it.
- **Match the existing style.** Doc comments in this codebase explain *why*,
  not *what* — a comment restating the code in English isn't useful, but a
  hidden constraint, a workaround for a specific bug, or a non-obvious
  tradeoff is worth writing down.
- **Don't add abstractions the change doesn't need.** Three similar lines
  are better than a premature shared helper. If you're touching code that
  already has a pattern (a `Store` class for settings, a wire-format struct
  for a provider), follow it rather than introducing a new one.
- **Keep PRs focused.** A bug fix doesn't need a drive-by refactor riding
  along with it — makes review faster and keeps `git blame` useful.

## Reporting issues

Open a GitHub issue with what you expected, what happened, and macOS/Swift
version if it's build-related. For anything security-sensitive, please
don't open a public issue — reach out privately first.

## License

By contributing, you agree your contribution is licensed under this
project's [PolyForm Shield 1.0.0](LICENSE.md) license.
