# Working on cloud-drive-restic-backup

Rules for anyone changing this repository, Claude included. This is a public repository: never commit anything
about a particular deployment (hosts, IPs, user names, account names or e-mails, folder names, client ids, paths of
a real server, keys, tokens).

## Changes, commits, pushes

- No commit, push or tag without an explicit OK from the maintainer ("commit", "push"). Changes stay in the
  working tree until then. Commits already made are not rolled back; later work goes on top of them.
- Never rewrite pushed history (no amend, rebase or force-push of pushed commits): deployments pin an image by its
  commit, which must stay reachable.
- Commit messages in English, in the style of the history: a short subject line and a body that says why. No
  `Co-Authored-By` or any other attribution trailer.
- One fix or feature per commit, with its README changes in the same commit.
- Edit files by hand in an editor (Claude: the Edit/Write tools), one place at a time. Don't patch files with sed,
  python or heredocs: escaping breaks and the change isn't visible as a diff.
- Long commands (image builds, the test run) go to the background; don't block the session on them.

## Review before pushing

Every change gets reviewed before it is pushed, and the review is repeated after each round of fixes until a round
finds nothing. Each finding gets a severity, a concrete failure scenario and a decision: fixed, accepted (with the
reason) or left for later. Check claims against facts (logs, a test run, rclone's documentation and source for the
version in the image) before fixing a "could happen": hypotheses are not bugs.

## CI and images

- `.github/workflows/build.yml`: tests on pushes to `main`, on `v*` tags and on PRs; on `main` and `v*` tags it
  builds amd64 and arm64 and pushes to `ghcr.io/adsdevdoo/cloud-drive-restic-backup` and, when the repository
  variable `DOCKERHUB_USERNAME` and the secret `DOCKERHUB_TOKEN` are set, to Docker Hub. Tags: `X.Y.Z`, `X.Y`, `X`
  and `latest` for a release, `edge` for `main`, `sha-<short>` and the full SHA for every build.
- The ghcr package of a public repository comes out public on its first push. If a fork's package starts private,
  set it to Public once (package settings → Change visibility).
- **A release** (with the maintainer's OK): move the `[Unreleased]` items of `CHANGELOG.md` under a new
  `## [X.Y.Z] - date` heading and fix the links at the bottom, commit, then tag that commit `vX.Y.Z` and push the
  tag. CI builds the release images and creates the GitHub Release from that CHANGELOG section (it fails if the
  section is missing). SemVer: a change users must act on (settings, data layout, metric names) is a new major.
- Every user-visible change goes into `CHANGELOG.md` under `[Unreleased]` in the same commit.

## Tests

- `sh tests/test.sh` builds the image and runs backup.sh against a stub rclone and a stub curl, without network
  (the first build needs it for the Alpine packages). All scenarios must pass; the script ends with `FAILED: 0`.
  The data directory carries over from one scenario to the next: order matters.
- New behavior gets a new scenario. A fix for a bug gets a scenario that failed before the fix.
- The rclone stub maps the remote `src:` of the run's config to a local directory chosen by the refresh token, and
  runs the real rclone for everything else: the real flags, `sync`, `--max-delete` and filters are exercised. It
  refuses anything but `lsf`, `sync` and `copy` into `/data/mirror`, and `backend drives`.
- The curl stub plays the token and "who am I" endpoints of the three services and checks the form (grant, client,
  secret, redirect). It refuses any other address.
- The tests fail if a client secret or a token shows up in the output.
- When a change touches how the image starts (Dockerfile, entrypoint), run the image's own command, not just
  `docker run … backup.sh`.
- Don't test against a real account casually: the services rate-limit, and a sync downloads everything. One careful
  run, read the log, stop.

## Code

- Bash with `set -euo pipefail` and `umask 077`. Each function starts with a comment `name <args> : what it does`;
  comments explain why, not what.
- `set -e` is off inside a function called as `f || …` or in `$(…)` (and in everything it calls). Such functions
  check each step explicitly (`|| return 1`) and replace files only after every step succeeded. A function whose
  stdout is captured logs to stderr.
- Arithmetic on settings only after the checks validated them as numbers without leading zeros.
- A source or account name goes into variable names, file names and metric labels: it is validated before any use
  (`^[a-z][a-z0-9_]{0,31}$`).
- **Never write to an account.** rclone runs only `lsf`, `sync` and `copy` with the account as the source and the
  local copy as the destination, and `backend drives`. No `move`, `delete`, `purge`, `mkdir`, no account as a
  destination. The OAuth clients ask for read-only access.
- **Never print a secret**: client secrets and tokens, not in logs, not on a command line (ps shows it), not in
  examples or commit messages. rclone gets them in its config file (600, in a 700 directory, one per source and
  command, removed afterwards);
  curl gets the form on stdin and the header from a file. rclone's stderr goes through `mask_secrets`, which masks
  them by value in all three forms (plain, Go `%q`, `%q` inside JSON). `--dump`, `--log-file` and `--config` are
  refused, and no `RCLONE_*` variable of the environment reaches rclone (the rclone stub checks it).
- rclone's stdout is a listing (`lsf` into `listing.tsv`): nothing else may write there. `-P` is refused for that;
  a function called with its stdout redirected logs to stderr.
- Versions in the image: Alpine 3.24, rclone 1.74, restic 0.18, supercronic 0.2, curl 8, jq 1.8, GNU gawk.

## What we learned about rclone (1.74)

- rclone keeps an OAuth token in the config file and saves a renewed one there (`token = {json}` in the section
  of the remote), re-reading the file before a renewal; a config from the environment could not be saved.
- The Dropbox backend asks for write scopes when it signs in (hard-coded), so `rclone authorize dropbox` can't get
  a token from a read-only app: `backup.sh auth` signs in without rclone. Refreshing a token doesn't ask for scopes.
- Google documents and Dropbox Paper documents are listed with the extension of their export format and size -1;
  sync and copy ignore the size of such a file and compare the modification time.
- `--max-delete N` lets N file deletions through and stops the sync with a fatal error at the next one; it counts
  files only (directories are removed regardless).
- Dropbox: only a path starting with `/` (`src:/…`) is taken from the root namespace of the account (for a team,
  the team space with the team folders); `src:` alone is the member's own folder.
- Yandex: the refresh token expires with the token (a year), and rclone renews only an expired token. `write_conf`
  hands rclone a token expiring within 275 days as expired. rclone's yandex backend rewrites a "bearer" token to
  "OAuth" and saves it.
- rclone names a download in progress `<name>.<8 hex digits>.partial`; a killed run leaves it in the copy.
- `rclone lsf --format tsp --separator $'\t'` puts the path last, so a tab in a name does not shift the columns.
