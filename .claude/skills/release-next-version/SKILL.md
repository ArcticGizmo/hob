---
name: release-next-version
description: Ship the current branch as the next hob release. Packs the release locally as a build gate (hob has no PR CI), opens (or reuses) a PR for the current branch, waits for any PR checks, stops and reports a FAIL if the build or a check fails, otherwise squash-merges it, then tags the new main head with the version from the newest CHANGELOG.md heading (vX.Y.Z) and pushes the tag, which kicks off the Release workflow, and watches that workflow until the GitHub Release is published or the build fails. Use when the user says "release next version", "release this", "/release-next-version", or wants to merge the current branch and cut the tagged release.
---

# Release Next Version

Takes the current branch from "done" to "published release": local pack → PR → checks → squash-merge → tag the new `main` head → push the tag → watch the Release workflow to completion. Pushing a `v*` tag triggers `.github/workflows/release.yml`, which builds and publishes the GitHub Release.

Invoking this skill is the user's go-ahead for the outward-facing steps (pushing the branch, opening the PR, merging, pushing the tag). Anything *not* listed here (force-pushes, bypassing checks, deleting branches, re-tagging) is out of scope; stop and ask.

## Repo facts this relies on

- Repo is `ArcticGizmo/hob`; **squash-merge only** (merge commits and rebase are disabled) and the remote branch is auto-deleted on merge.
- Tags are **lightweight**, `vMAJOR.MINOR.PATCH`. There is no version in the project files (the csproj stays at `0.0.0`; the release build takes its version from the tag), so the version to release is the **newest `## [vX.Y.Z]` heading in `CHANGELOG.md`**, written by `/bump-version`.
- **There is no PR CI.** `release.yml` is the only workflow, so a PR normally has no checks. Step 2 packs locally instead, with the same `build/pack.ps1` the Release workflow runs, so a broken build is caught before anything is tagged. If a PR workflow is added later, step 4 waits for it.
- The Release workflow has two jobs: `build-windows`, then `release` (`needs` it), which is the **only** job that creates the GitHub Release. A failed build means no Release is published at all, never a half-populated one. A tag-triggered run's `headBranch` is the tag name (e.g. `v0.1.2`). A healthy run takes roughly 5–10 minutes.
- Use the Bash tool (Git Bash) for the snippets below.

## Steps

### 1. Preflight: gather everything in one batch

```bash
BRANCH=$(git rev-parse --abbrev-ref HEAD); echo "BRANCH=$BRANCH"
echo "=== status ==="; git status --porcelain
git fetch origin --tags --quiet
VERSION=$(sed -n 's/^## \[v\([0-9][0-9.]*\)\].*/\1/p' CHANGELOG.md | head -1); echo "VERSION=$VERSION"
echo "LAST_TAG=$(git tag --sort=-v:refname | head -1)"
echo "TAG_EXISTS_LOCAL=$(git tag -l "v$VERSION")"
echo "TAG_EXISTS_REMOTE=$(git ls-remote --tags origin "refs/tags/v$VERSION")"
echo "=== commits on $BRANCH not on origin/main ==="
git log origin/main..HEAD --no-merges --pretty=format:'%h %s'
echo; echo "=== existing PR ==="; gh pr view --json number,state,url,title 2>&1
```

Stop and report (don't try to fix it yourself) if any of these hold:

- `BRANCH` is `main` (or detached `HEAD`); there's nothing to PR. Say so.
- The working tree is dirty; uncommitted changes wouldn't be in the release. List them and ask whether to commit them first.
- There are no commits on the branch ahead of `origin/main`.
- `VERSION` is empty, `v$VERSION` already exists (locally or on the remote), or `VERSION` isn't greater than `LAST_TAG`: the version hasn't been bumped. Suggest running `/bump-version` (and committing its `CHANGELOG.md` edit) first. Never move or overwrite an existing tag.
- An existing PR for the branch is `CLOSED` or `MERGED`; ask rather than open a second one.

### 2. Pack locally

The same script the Release workflow runs, with the version about to be tagged. `-Clean` is needed because vpk won't pack a version that isn't newer than one already in `artifacts\releases` (build output, gitignored). It takes a minute or two:

```bash
powershell.exe -NoProfile -ExecutionPolicy Bypass -File build/pack.ps1 -Version "$VERSION" -Clean
echo "RESULT=EXIT_$?"
ls artifacts/releases
```

`EXIT_0` with `Hob-win-Setup.exe` in the listing means carry on. Anything else: **stop, this is a FAIL that needs fixing.** Nothing has been pushed yet. Report back headed **`RELEASE FAILED: local pack did not succeed`** with the relevant tail of the output (compiler errors, trim warnings, which are errors here, or the vpk message). Don't attempt a fix unless the user asks.

### 3. Push the branch and open (or reuse) the PR

```bash
git push -u origin HEAD
```

If step 1 found an `OPEN` PR, reuse it. Otherwise create one against `main`:

- **Title:** a concise summary of the branch's net change (if the branch is a single feature, its name; otherwise the headline items), ending with `; bump to $VERSION` when the branch carries the bump.
- **Body:** a short `## Summary` of the user-facing changes (from the commit list in step 1 and the `## [v$VERSION]` section in `CHANGELOG.md`), a `## Test plan` noting that the release packed locally and anything still unverified live (e.g. an actual install or `hob update` from the previous version), then the PR attribution line.

Write the body to a temp file and pass it with `--body-file` (avoids quoting trouble):

```bash
gh pr create --base main --head "$BRANCH" --title "<title>" --body-file <file>
```

Record the PR number and URL.

### 4. Wait for any checks

Checks can take a few seconds to register after the PR opens, hence the short lead-in loop. With no PR workflow this takes about a minute to conclude `NO_CHECKS`; if a workflow has been added, run this with the Bash tool's `run_in_background: true` and a timeout of about 45 minutes (`2700000` ms), then wait for the completion notification rather than polling:

```bash
PR=<number>
found=0
for i in $(seq 1 6); do
  if gh pr checks "$PR" 2>&1 | grep -q 'no checks reported'; then sleep 10; else found=1; break; fi
done
if [ "$found" = 0 ]; then echo "RESULT=NO_CHECKS"; exit 0; fi
gh pr checks "$PR" --watch --fail-fast --interval 30
echo "RESULT=EXIT_$?"
```

Then branch on the result:

- **`NO_CHECKS`**: expected while hob has no PR CI; step 2's local pack is the gate. Continue to step 5.
- **`EXIT_0`**: all checks passed. Continue to step 5.
- **Any other exit**: a check failed (or was cancelled). **Stop: this is a FAIL that needs fixing.** Do not merge, do not tag. Gather the evidence:

  ```bash
  gh pr checks "$PR"
  gh run list --branch "$BRANCH" --limit 1 --json databaseId,url,conclusion,workflowName
  gh run view <databaseId> --log-failed | tail -80
  ```

  Report back headed **`RELEASE FAILED: checks did not pass`**, with the PR URL, which job/step failed, the run URL, and the relevant tail of the failed log. Leave the PR open. Don't attempt a fix unless the user asks.

### 5. Squash-merge

```bash
gh pr merge "$PR" --squash
```

Don't pass `--delete-branch` (the remote branch is auto-deleted; leave the local branch alone, since after a squash it can only be force-deleted, which is the user's call). Don't pass `--admin` or `--auto`. If the merge is refused (branch protection, merge conflict), stop and report the message.

Then confirm the merge and capture the squash commit:

```bash
gh pr view "$PR" --json state,mergeCommit -q '.state + " " + .mergeCommit.oid'
git fetch origin --tags --quiet
git checkout main && git pull --ff-only origin main
echo "MAIN_HEAD=$(git rev-parse HEAD)"
```

`state` must be `MERGED`. Normally `MAIN_HEAD` equals the merge commit. If it doesn't, something else landed on `main` in the meantime; stop and ask which commit to tag rather than guessing.

If `git pull --ff-only` fails (local `main` had diverged), stop and report; don't reset it.

### 6. Tag the new main head and push the tag

```bash
git tag "v$VERSION" "$MAIN_HEAD"
git push origin "v$VERSION"
```

(Lightweight tag, matching the existing ones.) Then find the Release run the tag triggered, filtering on the tag so a stale or concurrent run can't be picked up. It can take a few seconds to register:

```bash
RUN=""
for i in $(seq 1 24); do
  RUN=$(gh run list --workflow release.yml --branch "v$VERSION" --event push --limit 1 --json databaseId -q '.[0].databaseId')
  [ -n "$RUN" ] && break
  sleep 5
done
echo "RUN=$RUN"
[ -n "$RUN" ] && gh run view "$RUN" --json url -q .url
```

If `RUN` is still empty after ~2 minutes, stop and report: the tag is pushed but no Release run started (check the Actions tab; the workflow may be disabled). Don't re-push or re-tag.

### 7. Watch the Release workflow

Run the watch with the Bash tool's `run_in_background: true` and a timeout of 30 minutes (`1800000` ms), then wait for the completion notification; don't poll. The watch output is redirected because `gh run watch` redraws the whole job table every interval; the summary after it is what you read:

```bash
RUN=<id>
gh run watch "$RUN" --exit-status --interval 30 > /dev/null 2>&1
echo "RESULT=EXIT_$?"
gh run view "$RUN" --json status,conclusion,url,jobs \
  -q '"run: " + .status + " " + (.conclusion // "-") + "  " + .url, (.jobs[] | "  " + .name + ": " + .status + " " + (.conclusion // "-"))'
```

Then branch on the result:

- **`EXIT_0`**: the run succeeded. Confirm the Release really exists with the assets the install path depends on:

  ```bash
  gh release view "v$VERSION" --json url,isDraft,assets \
    -q '.url, ("draft: " + (.isDraft|tostring)), (.assets[] | "  " + .name)'
  ```

  `Hob-win-Setup.exe`, `SHA256SUMS.txt` and `releases.win.json` must all be listed (`install.ps1` resolves the first and verifies it against the second; `hob update` reads the third). If any is missing, or the Release is a draft, report it as a problem: the run went green but installs or updates can't use this release.
- **Any other exit**: a job failed or was cancelled. **Stop: this is a RELEASE BUILD FAILURE.** The tag is pushed but, because `release` needs the build, **no GitHub Release was published**. Gather the evidence:

  ```bash
  gh run view "$RUN" --log-failed | tail -80
  ```

  Report back headed **`RELEASE BUILD FAILED: v$VERSION tagged, no Release published`**, with the run URL, which job/step failed, and the relevant tail of the failed log. Don't re-run, re-tag, delete the tag or push a fix on your own; say that the usual recovery once the cause is understood is `gh run rerun "$RUN" --failed` (a flaky runner) or a fix plus a new patch version (a real break), and let the user choose.
- **The background task timed out** (no `RESULT` line after 30 minutes): the run is still going or stuck. Report the run URL and the current job statuses (the `gh run view` line above), and don't wait further unless asked.

### 8. Report back

Print, plainly:

- **`Released v$VERSION`**
- The PR URL (merged) and the squash commit SHA that was tagged.
- The Release workflow run URL and its outcome (both jobs green).
- The GitHub Release URL and confirmation that `Hob-win-Setup.exe`, `SHA256SUMS.txt` and `releases.win.json` are attached.
- That local `main` is checked out and up to date, and the local branch `$BRANCH` still exists (the remote one was auto-deleted).

On any stop in steps 1–7, report exactly which step stopped, why, and what state things were left in (e.g. "PR #5 open, not merged, no tag", or "PR #5 merged, v0.1.2 tagged, Release build failed in build-windows; no Release published").
