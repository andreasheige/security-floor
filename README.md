# security-floor

The server-side check a local bypass can't skip (security plan 11.1). Local hooks, the
review-loop gate and eot all run on Andreas's Mac; `--no-verify`, a husky repo, a web edit,
another machine or a cloud agent goes around them. This reusable workflow runs the same
deterministic checks on GitHub.

- **Secrets:** gitleaks 8.30.1 (pinned by sha256) with its default rules plus the review-loop
  canary, over the PR's own commits or the pushed range. Repo-local `.gitleaks.toml`,
  `.gitleaksignore` and inline `gitleaks:allow` are ignored.
- **Guarded paths (PRs):** a PR that changes CI, scanner, git-hook or `.review-loop.toml`
  config fails; an admin merges it past the required check on purpose.
- No LLM, no secrets, `contents: read`, actions pinned by SHA.

## Use it

1. Copy `draft/caller-security-floor.yml` to `.github/workflows/security-floor.yml` in the repo,
   with `<SHA>` set to a full commit SHA of this repo.
2. Make `security-floor / floor` a required status check on `main`.

Callers pin a SHA, so a change here reaches a repo only when its pin is bumped.

## Layout

- `draft/floor.yml`: the reusable workflow. It belongs at `.github/workflows/floor.yml`;
  agents can't write workflow files, so Andreas moves it there.
- `tests/run.sh`: runs the workflow's own step scripts against throwaway repos with a local
  gitleaks (needs gitleaks 8.30.x and uv).
