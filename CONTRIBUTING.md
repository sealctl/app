# Contributing

Thanks for your interest in the sealctl app.

**Code pull requests are not accepted for now.** Pull requests with code will be closed
without review.

**Issues are welcome:** bug reports, questions and ideas, on
[GitHub issues](https://github.com/sealctl/app/issues).

**Security reports are welcome**, privately: see the
[security policy](https://github.com/sealctl/.github/blob/main/SECURITY.md). Never in a public
issue or pull request.

## Why

The app is AGPL-3.0 and is also distributed through the App Store and Google Play. Store terms
add restrictions that the AGPL does not allow for code from other copyright holders, so outside
code needs contribution terms (a contributor licence agreement and an additional permission)
before it can ship. Until those terms are published, the app takes no outside code. This file
will say when that changes.

The command line tool and protocol core, [sealctl/sealctl](https://github.com/sealctl/sealctl),
have their own contribution rules.

## Claude on GitHub (maintainers)

Every pull request from a branch of this repository gets an AI review from Claude: inline
comments on real problems, each marked **blocker**, **should fix** or **nit**, and one summary
comment that is updated on every push. It is advice, not a required check. What it looks for is
in [`.github/claude-review.md`](.github/claude-review.md); the rules it holds code to are in
[`CLAUDE.md`](CLAUDE.md). Label a pull request `skip-claude-review` to skip it, or
`claude-review` to review a Dependabot pull request or one that changes only generated or lock
files.

Collaborators can also ask Claude directly in an issue or pull request comment:

- `@claude review this again`
- `@claude explain this change`
- `@claude fix the failing test`
- `@claude <task>` on an issue: Claude pushes a `claude/` branch and links a pull request.

Claude follows `CLAUDE.md`. It can push commits to the pull request's branch when asked, but it
never merges, force-pushes, deploys, tags or changes workflows: a maintainer still reviews and
merges. Comments from people who are not collaborators are ignored.
