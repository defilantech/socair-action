# Contributing to socair-action

This action is part of Socair, and [Socair's contribution guide](https://github.com/defilantech/socair/blob/main/CONTRIBUTING.md)
applies here. Security issues go through [SECURITY.md](SECURITY.md), never a
public issue.

## Sign off your commits (DCO)

Sign off every commit with a Developer Certificate of Origin sign-off
(<https://developercertificate.org/>):

```
git commit -s -m "Describe the change"
```

The `dco` check (`scripts/check-dco.sh`) runs on every pull request and
requires a `Signed-off-by:` line with each commit's author name and email.
To fix a missing one: `git rebase --signoff main` and
`git push --force-with-lease`.

## AI-assisted contributions

Socair's [AI-assisted contributions](https://github.com/defilantech/socair/blob/main/CONTRIBUTING.md#ai-assisted-contributions)
policy applies. A person signs off every commit and is accountable for the
change. Say in the pull request description which tool you used, what it
produced, and what you checked, for example
`Assisted-by: <tool> (generated the tests; I reviewed them and ran them)`.
Commit messages carry no attribution trailers.

## The rules a change is held to

- Every action that `action.yml` or a workflow uses is pinned by its full
  commit SHA, with the version in a comment.
- No `${{ }}` expression goes inside a `run:` script. Pass the value through
  `env:` and quote it.
- The action derives no status of its own: the promotion state, the rows,
  and their statuses come from the report Socair wrote.
- A binary runs only after every verification check passed. A change to
  verification keeps the falsification runs in `.github/workflows/test.yml`
  failing for the reason they name.
- Tests write their own fixtures (`test/fixtures.sh`); they never download a
  model.
- Before pushing, run `shellcheck scripts/*.sh test/*.sh` and, if you have
  it, `actionlint`.
