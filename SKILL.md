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

## Per-repo conventions

Both optional, both at repo root: a `*.worktree.yml` override for republishing
ports (named to match your compose file — `compose.worktree.yml` or
`docker-compose.worktree.yml`), and `.worktree-setup.sh` for project
bootstrapping. See `worktree.sh help` for details.

## Setting up a repo for this skill

Run this once per project, when asked to configure a repo for isolated
worktrees. Do not spawn a worktree as part of setup.

1. Check `docker compose version` is 2.24 or newer. The `!override` tag does
   not exist before that, and without it Compose merges ports additively and
   the original fixed mapping still binds. If it's older, stop and tell the
   user — there is no clean workaround.

2. Read the repo's compose file. List every service with a fixed host port mapping
   (`"3000:3000"`), and ignore services that only expose ports internally —
   those need no override. Show the user the list and confirm which ones they
   actually need to reach from the host. Databases usually don't need one
   unless they connect a GUI client.

3. Write the override file — name it to match the base file (`compose.worktree.yml`
   or `docker-compose.worktree.yml`) — with a `ports: !override ["<container-port>"]`
   entry per confirmed service. A bare container port means "publish to a
   kernel-assigned host port".

4. Check whether the repo needs bootstrapping in a fresh checkout: gitignored
   config files, dependency installs, secret loading, database seeding. Ask
   the user rather than guessing — this varies a lot. If anything is needed,
   write `.worktree-setup.sh`; if not, skip the file entirely.

5. Confirm the worktrees directory is ignored if it would land inside a
   tracked tree.

6. Verify: run `worktree.sh spawn feat/worktree-smoke-test`, check the printed
   ports respond, then `worktree.sh teardown feat/worktree-smoke-test`. Report
   what worked. If the stack failed to come up, the usual causes are a missing
   healthcheck (with `--wait`), a hardcoded host or port in app config, or a
   service that needs an override you skipped in step 2.
