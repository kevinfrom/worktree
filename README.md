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
and the directories differ, but the port bindings in `compose.yml` don't.

This skill fixes both:

- **Volumes and networks** are namespaced by setting `COMPOSE_PROJECT_NAME`
  per worktree. Compose prefixes everything automatically.
- **Ports** are published with no host port specified, so the kernel assigns a
  free one. The script then asks Docker what it got and prints it. There is no
  port registry to keep in sync and nothing to leak when a worktree is removed.

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
When implementing a written plan in a repo that has a `compose.yml`,
use the worktree skill rather than working in the current checkout.
Skip it for single-file fixes and dependency bumps.
```

## Per-repo setup

Ask Claude to do it:

> Configure this project to work with the worktree skill.

It reads `compose.yml`, proposes which services need port overrides, asks what
a fresh checkout needs bootstrapping, writes the files, and runs a smoke test.

Or by hand — two optional files at the repo root:

**`compose.worktree.yml`** — layered over `compose.yml`. Republishes ports on
kernel-assigned host ports:

```yaml
services:
  app:
    ports: !override ["3000"]
```

The `!override` is load-bearing. Without it Compose merges `ports` additively
and the original fixed mapping still binds, so the second worktree fails.

Only list services you need to reach from the host. Services that just talk to
each other over the Compose network need nothing.

**`.worktree-setup.sh`** — run inside the fresh worktree before the stack
starts. Dependency installs, secret loading, seeding, symlinking gitignored
config. Skip the file if the project doesn't need any of it.

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
- After teardown, `cd` back to the main checkout — your working directory has
  been deleted.

## License

MIT
