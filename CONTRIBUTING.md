# Contributing to Eaon

Thanks for considering it — contributing here is meant to be easy. There's
**no CLA to sign**, **no external dependencies to install**, and **no
build tooling beyond Swift itself**. Clone, build, run, send a PR.

New here? Look for issues labelled
[`good first issue`](https://github.com/sanscreates/eaon-desktop/labels/good%20first%20issue),
or just open an issue describing what you'd like to work on.

## Getting set up

```sh
git clone https://github.com/sanscreates/eaon-desktop
cd eaon-desktop
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

## License & sign-off

By contributing, you agree your contribution is licensed under this
project's [GNU GPL v3.0](LICENSE.md) license.

Instead of a contributor agreement to sign, we use the lightweight
**Developer Certificate of Origin (DCO)** — the same one the Linux kernel
uses. It's a one-line promise that you wrote the change (or have the right
to submit it), added automatically by committing with `-s`:

```sh
git commit -s -m "your message"
```

That appends a `Signed-off-by: Your Name <you@example.com>` line to the
commit. That's it — no form, no account, no waiting. The full DCO text is
below for reference; committing with `-s` is your agreement to it.

> **Developer Certificate of Origin 1.1** — By making a contribution to
> this project, I certify that: (a) the contribution was created in whole or
> in part by me and I have the right to submit it under the open source
> license indicated in the file; or (b) it is based upon previous work that,
> to the best of my knowledge, is covered under an appropriate open source
> license and I have the right under that license to submit it; or (c) it
> was provided directly to me by some other person who certified (a), (b) or
> (c) and I have not modified it. (d) I understand and agree that this
> project and the contribution are public and that a record of the
> contribution (including all personal information I submit with it) is
> maintained indefinitely and may be redistributed consistent with this
> project and its open source license.
