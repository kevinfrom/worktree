---
name: worktree
description: Spawn an isolated git worktree with its own Docker stack on kernel-assigned ports, implement a written plan on a new branch, and open a PR. Use when asked to implement an implementation plan in isolation, or in parallel with other agents. Do not use for single-file fixes, dependency bumps, or work the user is watching interactively.
---

# Isolated worktree implementation

Each task gets its own git worktree and its own Docker Compose project, so
several agents can work on the same repo at once without colliding on ports,
volumes, or files.

All commands go through `<skill-dir>/worktree.sh`. Run it with `help` for the
full reference.

## 1. Spawn

    <skill-dir>/worktree.sh spawn <branch> [base-ref]

Run from the main checkout. Base ref defaults to `main`. Branch names:
`feat/<short-slug>` or `fix/<short-slug>`.

It prints the worktree path, the Compose project name, and the host ports
Docker assigned. **All later commands run from that worktree path.**

Spawn also reports worktrees whose PR is already merged or closed. If any are
listed, tell the user and ask whether to tear them down. Never tear down one
flagged with uncommitted changes without asking.

## 2. Implement

Read the plan from the file path or issue reference you were given
(`gh issue view <n>` for an issue). If the plan lists the files it may touch,
stay inside that list; if you need to go outside it, say so rather than doing
it silently.

Work only inside the worktree. Never touch the main checkout.

Prefix docker commands with the printed project name:

    COMPOSE_PROJECT_NAME=<name> docker compose exec <service> <cmd>

## 3. Verify

Run the project's tests and lint inside the stack before committing.
Use the printed port if the change is user-facing.

## 4. Ship

Commit in logical chunks, push with `-u origin <branch>`, then
`gh pr create --fill --base <base-ref>`. Report the PR URL.

## 5. Merge and teardown

After a successful `gh pr merge`, run `worktree.sh list` to see whether the
merged branch still has a worktree. If it does, tell the user and offer:

    <skill-dir>/worktree.sh teardown <branch>

Teardown removes the containers, volumes, worktree, and local branch. It
refuses outright on uncommitted changes. Never run it without confirmation.
**After teardown, `cd` back to the main checkout** — your shell's working
directory no longer exists.

## Repo setup

Nothing is required. Spawn reads the resolved Compose config and generates a
`docker-compose.override.yml` inside the worktree that republishes every host
port on a kernel-assigned one. The main checkout is untouched.

Two things to check the first time you use it in a repo:

1. `docker compose version` is 2.24 or newer — the `!override` tag doesn't
   exist before that, and without it Compose merges ports additively and the
   original fixed mapping still binds.

2. `docker-compose.override.yml` is gitignored. Spawn refuses to run if it's
   committed to the repo, since it needs to generate that file.

Optionally add `.worktree-setup.sh` at the repo root if a fresh checkout needs
bootstrapping — dependency installs, secret loading, seeding, gitignored config.
Ask the user rather than guessing; this varies a lot between projects.

Verify with `worktree.sh spawn feat/worktree-smoke-test`, check the printed
ports respond, then tear it down. If the stack fails to come up, the usual
causes are a missing healthcheck (with `--wait`) or a hardcoded host port in
app config.
