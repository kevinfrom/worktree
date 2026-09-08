#!/usr/bin/env bash
#
# worktree.sh — isolated git worktrees with their own Docker Compose stacks.
#
set -euo pipefail

# ---------------------------------------------------------------- helpers ---

die() { echo "error: $*" >&2; exit 1; }

require() {
  local missing=()
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  if [[ " $* " == *" docker "* ]]; then
    docker compose version >/dev/null 2>&1 || missing+=("docker-compose-plugin")
  fi
  [ "${#missing[@]}" -gt 0 ] && die "missing dependencies: ${missing[*]}"
  return 0
}

# Sets ROOT, NAME, SLUG, DIR, PROJECT for a branch. Single source of truth for
# how a branch name maps to a directory and a Compose project.
resolve() {
  local branch="$1"
  ROOT="$(git rev-parse --show-toplevel)" || die "not inside a git repo"
  NAME="$(basename "$ROOT")"
  SLUG="$(printf '%s' "$branch" | tr '[:upper:]/' '[:lower:]-' | tr -cd '[:alnum:]-')"
  [ -n "$SLUG" ] || die "branch name '$branch' produced an empty slug"
  DIR="$ROOT/../worktrees/$NAME-$SLUG"
  PROJECT="$NAME-$SLUG"
}

# Echoes the -f flags for compose: the base file Compose would pick itself,
# plus the worktree override if present. Compose requires that if you pass any
# -f, you pass them all — hence detecting the base rather than assuming.
compose_files() {
  local base="" override="" f
  for f in compose.yaml compose.yml docker-compose.yaml docker-compose.yml; do
    [ -f "$f" ] && { base="$f"; break; }
  done
  [ -n "$base" ] || die "no compose file found in $PWD"
  printf '%s\n' -f "$base"

  for f in compose.worktree.yaml compose.worktree.yml \
           docker-compose.worktree.yaml docker-compose.worktree.yml; do
    [ -f "$f" ] && { override="$f"; break; }
  done
  [ -n "$override" ] && printf '%s\n' -f "$override"
  return 0
}

# ------------------------------------------------------------------ usage ---

usage() {
  cat <<'EOF'
worktree.sh — isolated git worktrees with their own Docker Compose stacks

USAGE
  worktree.sh spawn <branch> [base-ref]   create worktree + branch, start stack
  worktree.sh teardown <branch>           stop stack, remove worktree + branch
  worktree.sh reap                        list worktrees whose PR is merged/closed
  worktree.sh list                        list all worktrees and stack status
  worktree.sh help                        this text

SPAWN
  Creates ../worktrees/<repo>-<slug> from <base-ref> (default: main), runs the
  repo's .worktree-setup.sh if present, brings up the Compose stack under an
  isolated project name, and prints the host ports Docker assigned.

TEARDOWN
  Refuses if the worktree has uncommitted changes. Otherwise removes containers,
  volumes, the worktree, and the local branch. cd back to the main checkout
  afterwards — your working directory will no longer exist.

PER-REPO CONVENTIONS (both optional, both at repo root)
  <base>.worktree.yml    layered over your compose file; republish ports on
                         kernel-assigned host ports:
                           services:
                             app:
                               ports: !override ["3000"]
                         The !override matters — without it Compose merges
                         ports additively and the fixed mapping collides.
                         Needs Compose 2.24+. Name it to match your base file:
                         compose.worktree.yml or docker-compose.worktree.yml.

  .worktree-setup.sh     run inside the fresh worktree before the stack starts;
                         dependency install, secret loading, seeding, etc.

COMPOSE FILE
  The base file is detected in Compose's own order: compose.yaml, compose.yml,
  docker-compose.yaml, docker-compose.yml.

REQUIRES
  git, docker (with compose plugin), jq. gh is needed for reap and for
  opening PRs.
EOF
}

# --------------------------------------------------------------- commands ---

cmd_reap() {
  for c in git gh; do
    if ! command -v "$c" >/dev/null 2>&1; then
      echo "warning: $c not found — skipping stale-worktree check" >&2
      [ "$c" = gh ] && echo "         gh is also needed later for 'gh pr create'." >&2
      return 0
    fi
  done

  local root found=0 dir branch state dirty
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || return 0

  while read -r dir; do
    [ "$dir" = "$root" ] && continue
    branch="$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null)" || continue

    state="$(gh pr view "$branch" --json state -q .state 2>/dev/null || echo "")"
    [ "$state" = "MERGED" ] || [ "$state" = "CLOSED" ] || continue

    if [ "$found" = 0 ]; then echo "Stale worktrees:"; found=1; fi

    dirty=""
    [ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ] && dirty="  ** UNCOMMITTED CHANGES **"
    echo "  $branch — PR $state$dirty"
  done < <(git worktree list --porcelain | awk '/^worktree /{print $2}')

  [ "$found" = 1 ] && { echo "Run: worktree.sh teardown <branch>"; echo; }
  return 0
}

cmd_list() {
  require git docker
  local root dir branch
  root="$(git rev-parse --show-toplevel)"
  while read -r dir; do
    branch="$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null || echo '(detached)')"
    if [ "$dir" = "$root" ]; then
      echo "  $branch — $dir (main checkout)"
    else
      resolve "$branch"
      local up
      up="$(docker compose ls --filter "name=$PROJECT" --format json 2>/dev/null \
            | jq -r '.[0].Status // "stopped"')"
      echo "  $branch — $dir [$up]"
    fi
  done < <(git worktree list --porcelain | awk '/^worktree /{print $2}')
}

cmd_spawn() {
  local branch="${1:-}" base="${2:-main}"
  [ -n "$branch" ] || die "usage: worktree.sh spawn <branch> [base-ref]"
  require git docker jq

  resolve "$branch"
  [ -e "$DIR" ] && die "$DIR already exists"

  cmd_reap || true

  git -C "$ROOT" fetch --quiet origin "$base" || true
  git -C "$ROOT" worktree add -b "$branch" "$DIR" "$base"
  cd "$DIR"

  export COMPOSE_PROJECT_NAME="$PROJECT"
  [ -f .worktree-setup.sh ] && bash .worktree-setup.sh

  mapfile -t FILES < <(compose_files)
  docker compose "${FILES[@]}" up -d --wait

  echo
  echo "worktree: $DIR"
  echo "project:  $PROJECT"
  docker compose ps --format json \
    | jq -r '.Publishers[]? | select(.PublishedPort > 0)
             | "\(.TargetPort) -> http://localhost:\(.PublishedPort)"' \
    | sort -u
}

cmd_teardown() {
  local branch="${1:-}"
  [ -n "$branch" ] || die "usage: worktree.sh teardown <branch>"
  require git docker

  resolve "$branch"
  [ -d "$DIR" ] || die "no worktree at $DIR"

  if [ -n "$(git -C "$DIR" status --porcelain)" ]; then
    die "$branch has uncommitted changes in $DIR — commit, stash, or remove manually"
  fi

  cd "$DIR"
  mapfile -t FILES < <(compose_files)
  COMPOSE_PROJECT_NAME="$PROJECT" docker compose "${FILES[@]}" down -v --remove-orphans || true

  cd "$ROOT"
  git worktree remove --force "$DIR"
  git branch -D "$branch" 2>/dev/null || true

  echo "removed $branch — cd back to $ROOT"
}

# -------------------------------------------------------------- dispatch ---

case "${1:-help}" in
  spawn)            shift; cmd_spawn "$@" ;;
  teardown|down)    shift; cmd_teardown "$@" ;;
  reap)             shift; cmd_reap ;;
  list|ls)          shift; cmd_list ;;
  help|-h|--help)   usage ;;
  *)                echo "unknown command: $1" >&2; echo >&2; usage >&2; exit 1 ;;
esac
