#!/usr/bin/env bash
# Runs floor.yml's own step scripts against throwaway repos with a local gitleaks.
# usage: tests/run.sh [path/to/floor.yml]   (needs gitleaks 8.30.x and uv on PATH)
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
wf="${1:-$here/draft/floor.yml}"
work="$(mktemp -d)"
uv run -q --no-project --with pyyaml python -I - "$wf" "$work" <<'EOF'
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["jobs"]["floor"]["steps"]
for s in steps:
    if s.get("id") == "range": open(sys.argv[2] + "/range.sh", "w").write(s["run"])
    elif s["name"].startswith("Secrets"): open(sys.argv[2] + "/secrets.sh", "w").write(s["run"])
    elif s["name"].startswith("Guarded"): open(sys.argv[2] + "/guarded.sh", "w").write(s["run"])
EOF

canary="REVIEWLOOP_CANARY_$(openssl rand -hex 10 | tr 'a-f' 'A-F')"
fails=0

# new_repo <name>: main with one clean commit; prints the repo path.
new_repo() {
  local r="$work/$1"
  git init -q -b main "$r"
  echo "hello" > "$r/README.md"
  git -C "$r" add -A
  git -C "$r" update-ref HEAD "$(git -C "$r" commit-tree "$(git -C "$r" write-tree)" -m "chore: init")"
  echo "$r"
}
# Plumbing, not `git commit`: fixture commits hold a canary, which the global pre-commit hook refuses.
commit() {
  git -C "$1" add -A
  git -C "$1" update-ref HEAD "$(git -C "$1" commit-tree "$(git -C "$1" write-tree)" -p HEAD -m "feat: change")"
}

# run_floor <repo> <event> <base> <head> <before>: range + secrets (+ guarded on PRs); echoes pass/fail.
run_floor() {
  local r="$1" out rc=0
  out="$work/out-$RANDOM"; : > "$out"
  export RUNNER_TEMP="$work/tmp-$RANDOM" GITHUB_OUTPUT="$out"; mkdir -p "$RUNNER_TEMP"
  ( cd "$r" && EVENT="$2" PR_BASE="$3" PR_HEAD="$4" PUSH_BEFORE="$5" PUSH_AFTER="$4" bash "$work/range.sh" >/dev/null ) || return 9
  local base head; base="$(sed -n 's/^base=//p' "$out")"; head="$(sed -n 's/^head=//p' "$out")"
  ( cd "$r" && BASE="$base" HEAD_SHA="$head" bash "$work/secrets.sh" >/dev/null 2>&1 ) || rc=1
  if [ "$2" = pull_request ] && [ $rc = 0 ]; then
    ( cd "$r" && BASE="$base" HEAD_SHA="$head" bash "$work/guarded.sh" >/dev/null 2>&1 ) || rc=2
  fi
  echo $rc
}

check() {  # check <name> <expected rc> <actual rc>
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (expected $2, got $3)"; fails=$((fails+1)); fi
}

# 1. clean PR passes
r="$(new_repo clean)"; base="$(git -C "$r" rev-parse HEAD)"
git -C "$r" switch -q -c feat/x; echo "const a = 1" > "$r/x.ts"; commit "$r"
check "clean PR passes" 0 "$(run_floor "$r" pull_request "$base" "$(git -C "$r" rev-parse HEAD)" "")"

# 2. canary in a PR fails, even with gitleaks:allow and a repo .gitleaksignore/.gitleaks.toml that try to hide it
r="$(new_repo canary)"; base="$(git -C "$r" rev-parse HEAD)"
git -C "$r" switch -q -c feat/x
echo "const k = \"$canary\" // gitleaks:allow" > "$r/x.ts"
printf '[allowlist]\npaths = ["x.ts"]\n' > "$r/.gitleaks.toml"
commit "$r"
printf '%s\n' "x.ts:reviewloop-canary:1" "$(git -C "$r" rev-parse HEAD):x.ts:reviewloop-canary:1" > "$r/.gitleaksignore"
check "canary PR fails despite gitleaks:allow, .gitleaks.toml, .gitleaksignore" 1 "$(run_floor "$r" pull_request "$base" "$(git -C "$r" rev-parse HEAD)" "")"

# 3. canary pushed straight to main (as with --no-verify or a web edit) fails on push
r="$(new_repo push)"; before="$(git -C "$r" rev-parse HEAD)"
echo "k=$canary" > "$r/.env.example"; commit "$r"
check "canary pushed to main fails" 1 "$(run_floor "$r" push "" "$(git -C "$r" rev-parse HEAD)" "$before")"

# 4. first push of a branch (before = zeros) scans all history, so an old canary is found
r="$(new_repo firstpush)"; echo "k=$canary" > "$r/old.txt"; commit "$r"; echo "x" > "$r/new.txt"; commit "$r"
check "first push scans all history" 1 "$(run_floor "$r" push "" "$(git -C "$r" rev-parse HEAD)" 0000000000000000000000000000000000000000)"

# 5. PR touching a workflow, .gitleaksignore or husky hook fails the guarded-path step
for f in .github/workflows/ci.yml .gitleaksignore .husky/pre-push .review-loop.toml; do
  r="$(new_repo "guard-$(echo "$f" | tr '/.' '__')")"; base="$(git -C "$r" rev-parse HEAD)"
  git -C "$r" switch -q -c feat/x; mkdir -p "$r/$(dirname "$f")"; echo "x" > "$r/$f"; commit "$r"
  check "PR touching $f fails guarded paths" 2 "$(run_floor "$r" pull_request "$base" "$(git -C "$r" rev-parse HEAD)" "")"
done

# 6. a PR whose base moved on (main got commits after the branch point) only scans the PR's own commits
r="$(new_repo moved)"; bp="$(git -C "$r" rev-parse HEAD)"
git -C "$r" switch -q -c feat/x; echo "y" > "$r/y.ts"; commit "$r"; head="$(git -C "$r" rev-parse HEAD)"
git -C "$r" switch -q main; echo "k=$canary" > "$r/main-only.txt"; commit "$r"; mainhead="$(git -C "$r" rev-parse HEAD)"
check "moved base: main's own commits aren't blamed on the PR" 0 "$(run_floor "$r" pull_request "$mainhead" "$head" "")"

echo "fails=$fails"
[ "$fails" = 0 ]
