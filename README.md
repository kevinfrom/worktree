# worktree

A Claude Code skill for running several agents against the same repo at once.

Each task gets its own git worktree and its own Docker Compose project, so
parallel work can't collide on ports, volumes, or files. The agent spawns the
worktree, implements a written plan on a new branch, opens a PR, and cleans up
after the merge.

## Why

Git worktrees solve file isolation, but not much else. Two agents running
`docker compose up` in two worktrees will fight over host ports and share
named volumes, because Compose derives its project name from the directory —
and the directories differ, but the port bindings in the compose file don't.

This skill fixes both:

- **Volumes and networks** are namespaced by setting `COMPOSE_PROJECT_NAME`
  per worktree. Compose prefixes everything automatically.
- **Ports** are republished with no host port specified, so the kernel assigns
  a free one. The script then asks Docker what it got and prints it. There is
  no port registry to keep in sync and nothing to leak when a worktree is
  removed.

Spawn reads your resolved Compose config, finds every service with a fixed host
port, and writes a `docker-compose.override.yml` into the worktree that
republishes each one. Compose auto-loads that file, so no `-f` juggling — and
because it only ever exists inside a worktree, your main checkout keeps its
usual predictable ports.

## Requirements

- git
- Docker with the Compose plugin, **2.24 or newer** (the `!override` YAML tag
  doesn't exist before that)
- jq
- gh — for opening PRs and for the stale-worktree check

## Install

Globally, for every project:

```bash
git clone <this-repo> ~/.claude/skills/worktree
chmod +x ~/.claude/skills/worktree/worktree.sh
```

Or per repo, committed so your team gets it too:

```bash
git clone <this-repo> .claude/skills/worktree
chmod +x .claude/skills/worktree/worktree.sh
```

Optionally add to your global `CLAUDE.md`:

```markdown
When implementing a written plan in a repo that has a Docker Compose file,
use the worktree skill rather than working in the current checkout.
Skip it for single-file fixes and dependency bumps.
```

## Repo setup

Nothing required. Add `docker-compose.override.yml` to `.gitignore` if it isn't
already — spawn generates that file and refuses to run if the repo commits one.

Optionally add `.worktree-setup.sh` at the repo root, sourced inside the fresh
worktree before the stack starts: dependency installs, secret loading, seeding,
symlinking gitignored config. Skip the file if you don't need it.

Commit it. `git worktree add` populates a new worktree from git, so an
untracked setup script is absent there and spawn proceeds without it — silently,
if it exports a compose wrapper: the stack starts, reports healthy and serves
200 with every interpolated value blank.

If the repo's Compose files need environment injected before Docker can even
read them (varlock, dotenvx, sops), export a command prefix from
`.worktree-setup.sh` and every `docker compose` call is made through it:

```bash
export WORKTREE_COMPOSE_WRAPPER="varlock run --no-redact-stdout --"
```

Disable the wrapper's stdout redaction, as above. Spawn parses `docker compose
config` as JSON, and a redacting wrapper will mask any value that collides with
a secret — including a service *name*, which comes back as `db*****` and yields
a garbage override file.

## Usage

```
worktree.sh spawn <branch> [base-ref]   create worktree + branch, start stack
worktree.sh teardown <branch>           stop stack, remove worktree + branch
worktree.sh reap                        list worktrees whose PR is merged/closed
worktree.sh list                        list all worktrees and stack status
worktree.sh help                        full reference
```

A typical session:

```
> Read issues #142 and #143 and write an implementation plan as a comment on
  each. Include the files each will touch. Don't implement anything.
```

Check the two file lists for overlap. If they collide, run them sequentially.
Otherwise, two sessions in parallel:

```
> Implement the plan in issue #142 using the worktree skill.
  Branch feat/session-refresh.
```

The agent spawns and reports:

```
worktree: /Users/you/code/worktrees/planbase-feat-session-refresh
project:  planbase-feat-session-refresh
3000 -> http://localhost:54312
```

You can open that URL while it works. When it's done it opens a PR; merge with
`gh pr merge` in the same session and it will offer to tear the worktree down.

## Layout

Worktrees live in `../worktrees/<repo>-<branch-slug>`, beside the repo rather
than inside it, so they never show up in `git status` or get picked up by file
watchers.

## Notes

- `teardown` refuses outright on uncommitted changes.
- `teardown` removes the container volumes (`down -v`). Anything you want to
  keep should live outside the stack.
- `spawn` runs the stale-worktree check first, so merged branches get flagged
  the next time you start work rather than accumulating silently.
- The generated override is rewritten on every spawn, so port changes in your
  compose file are picked up automatically.
- After teardown, `cd` back to the main checkout — your working directory has
  been deleted.

## License

MIT
