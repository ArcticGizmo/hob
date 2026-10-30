---
name: bump-version
description: Bump the hob version by writing the next CHANGELOG.md section. Determines the next version from the LAST GIT TAG, backfills changelog sections for any tagged versions that were never documented, summarises every change since the last tag into a new CHANGELOG.md section (keeping the dry humour), clears the Unreleased section, and prints the new version plus its changelog entries. Use when the user says "bump version", "bump the version", "/bump-version", or wants to cut a new release entry.
---

# Bump Version

Bumps hob to the next patch version by adding its section to `CHANGELOG.md`.

## Where the version lives

hob has no version in its project files: `src/Hob.Cli/Hob.Cli.csproj` stays at `<Version>0.0.0</Version>` and the release build takes its version from the tag (`release.yml` passes it to `build/pack.ps1`). The **last git tag is the source of truth** for what has shipped; the **newest `## [vX.Y.Z]` heading in `CHANGELOG.md`** is what ships next, and `/release-next-version` tags whatever that heading says. Don't touch the csproj.

The changelog is for reading, not for the app: nothing embeds or displays it.

## Steps

### 1. Gather everything in one batch

Run this single block first. It collects the tag, the new commits, and the dates for any backfill, so you don't make repeated round-trips:

```bash
LAST_TAG=$(git tag --sort=-v:refname | head -1)
echo "LAST_TAG=$LAST_TAG"
echo "=== all tags (oldest→newest) ==="; git tag --sort=v:refname
echo "=== changelog headings ==="; grep -n '^## \[' CHANGELOG.md 2>&1
echo "=== new commits on HEAD since $LAST_TAG ==="
git log $LAST_TAG..HEAD --no-merges --date=short --pretty=format:'%h %ad %s'
```

Parse `LAST_TAG` as `vMAJOR.MINOR.PATCH`. The next version is the same with **PATCH + 1** (e.g. `v0.1.1` → `v0.1.2`). Call it `$NEXT`. If there are no tags at all, start at `v0.1.0` and say so.

If there are no commits since `LAST_TAG` and `[Unreleased]` is empty, stop and say there is nothing to release.

**Scope is `HEAD`, deliberately.** Only commits reachable from `HEAD` are releasing. Do **not** use `--all`; it drags in unmerged branch WIP that isn't shipping.

**hob's commits are squash-merged PRs** (`Build/smaller install (#3)`), so the subject is usually a branch name and says little. Read the body of each one; the squash body lists the original commits, and those are what you summarise:

```bash
git log $LAST_TAG..HEAD --no-merges --format='=== %h %s%n%b'
```

Skip noise entirely: `Co-authored-by` trailers, pure-WIP commits, and plumbing a user would never notice. Collapse related commits into the single *net* change they add up to (see "What to write" in step 3).

### 2. Backfill any missing tagged versions

A version can be tagged without ever getting a changelog section. From the step 1 output, find tags with **no** matching `## [v…]` heading. For each missing tag (oldest first), get its commits and date in one call, scoped to that tag's range:

```bash
# fill in <prev_tag> and <tag> (for the first tag ever, drop "<prev_tag>.."); the last line gives the heading date
git log <prev_tag>..<tag> --no-merges --format='=== %h %ad %s%n%b' --date=short; \
  git log -1 --format='HEADING_DATE=%cd' --date=short <tag>
```

Insert each backfilled `## [v<tag>] - YYYY-MM-DD` (using its own tag date, not today) in the correct reverse-chronological slot, applying the same summarising and dry-humour rules below. Do every missing tag, not just the latest.

### 3. Write the changelog

If `CHANGELOG.md` doesn't exist, create it with this header and nothing else, then carry on:

```markdown
# Changelog

All notable changes to hob are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [Unreleased]

---
```

Then:

- **Create a new section** directly under `## [Unreleased]`, titled `## [v$NEXT] - YYYY-MM-DD` using today's date.
- Fill it with the summarised, user-facing bullets from step 1. **Fold in** anything already sitting in the `[Unreleased]` section; those changes are part of this release.
- **Clear the `[Unreleased]` section** so it sits empty (keep the `## [Unreleased]` heading and the `---` separators; just remove its bullets).
- Preserve the existing file format exactly: heading style, the `---` separators, and the reverse-chronological order (newest version on top).

#### What to write

- **Write for the person using hob, not the developer.** Describe what changed for someone typing `hob`/`hb` in a shell or installing it. Mention implementation details only when they genuinely matter to them (e.g. "data folder moved to `%USERPROFILE%\.hob`; the old one isn't migrated"). Internal refactors, file moves, CI and plumbing don't get a bullet at all.
- **Keep bullets snappy. This is the rule that gets ignored most, so enforce it hard.** Aim for a short phrase, roughly ten words or fewer; one line, never two. Cut "now", "the ability to", "you can now". Drop the trailing "so you can…" rationale; keep an aside only when it earns the dry humour. Prefer "Installer is 60% smaller" over "The installer has been trimmed so that it downloads faster". After drafting, reread every bullet and shorten any that runs long.
- **Describe the cumulative change, not the commit trail.** A version's section is the net difference from the previous version: the end state, not the journey. If a feature was added, then fixed, then tweaked across several commits, that's *one* bullet describing the finished feature. Never list intra-version fixes to something that didn't exist in the last release; nobody saw the broken version.

#### Tone: keep the dry humour

The changelog has a deadpan, self-aware voice. Match it. The register, from a sibling project:

> - Immediately reverted in-app configuration settings (a bold 3-minute experiment)
> - Hid git worktrees from the session list (they are not sessions; they are a trap)
> - Made the remote control icon more noticeable (it was there before, quietly)

Write straight bullets for ordinary changes; reserve the parenthetical asides and dry understatement for the moments that earn them. Don't force a joke into every line; the humour lands because most lines are plain. Never invent changes that didn't happen for the sake of a punchline.

### 4. Report back

Print, plainly:

- The next version number (e.g. `v0.1.2`).
- The exact changelog entries you wrote for that version.
- If you backfilled any missing tagged versions, list which ones and show their entries too.

## Notes

- This skill does **not** commit, tag, or push. It only edits `CHANGELOG.md` and reports. Commit the bump on the release branch, then `/release-next-version` PRs, merges and tags it.
- Only the patch component is bumped. If the user wants a minor/major bump, they'll say so; follow their instruction instead of auto-incrementing patch.
