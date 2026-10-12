# cloud-drive-restic-backup

[![build](https://github.com/adsdevdoo/cloud-drive-restic-backup/actions/workflows/build.yml/badge.svg)](https://github.com/adsdevdoo/cloud-drive-restic-backup/actions/workflows/build.yml)
[![ghcr.io](https://img.shields.io/badge/ghcr.io-adsdevdoo%2Fcloud--drive--restic--backup-blue?logo=github)](https://github.com/adsdevdoo/cloud-drive-restic-backup/pkgs/container/cloud-drive-restic-backup)
[![Docker Hub](https://img.shields.io/docker/v/adsdevdoo/cloud-drive-restic-backup?sort=semver&logo=docker&label=docker%20hub)](https://hub.docker.com/r/adsdevdoo/cloud-drive-restic-backup)
[![Docker pulls](https://img.shields.io/docker/pulls/adsdevdoo/cloud-drive-restic-backup?logo=docker)](https://hub.docker.com/r/adsdevdoo/cloud-drive-restic-backup)
[![image size](https://img.shields.io/docker/image-size/adsdevdoo/cloud-drive-restic-backup/latest?logo=docker)](https://hub.docker.com/r/adsdevdoo/cloud-drive-restic-backup)
![platforms](https://img.shields.io/badge/platforms-amd64%20%7C%20arm64-lightgrey)
[![release](https://img.shields.io/github/v/release/adsdevdoo/cloud-drive-restic-backup?sort=semver)](https://github.com/adsdevdoo/cloud-drive-restic-backup/releases)
[![license](https://img.shields.io/github/license/adsdevdoo/cloud-drive-restic-backup)](LICENSE)
[![last commit](https://img.shields.io/github/last-commit/adsdevdoo/cloud-drive-restic-backup)](https://github.com/adsdevdoo/cloud-drive-restic-backup/commits/main)

Scheduled backup of any number of Google Drive, Dropbox and Yandex Disk accounts into one restic repository, in a
single Docker container.

[rclone](https://rclone.org/) syncs each account into a local directory, and [restic](https://restic.net/)
snapshots it. Optionally, the restic repository is copied to a second host over SSH. Access is read-only: the
backup signs in with an OAuth app of your own that can only read, and never writes to an account. Each account (a
*source*) has its own schedule and retention; all of them share one repository, so the same file in two accounts
is stored once.

restic can't read from a cloud drive, only store into one, hence the local copy. It costs disk space equal to the
accounts, and saves traffic: each run downloads only new and changed files.

## Features

- **Read-only.** OAuth apps with read-only scopes; the backup lists and downloads, nothing else.
- **Any number of accounts.** Google Drive (My Drive, shared drives, "Shared with me"), Dropbox (team folders
  included), Yandex Disk; a whole account or a folder of it, each with its own schedule and retention.
- **Snapshots, not a mirror.** restic keeps hourly, daily, weekly and monthly snapshots, deduplicated across all
  accounts and encrypted. A file deleted or overwritten in the account stays in the older snapshots.
- **Deletion guard.** A run that would delete more than 10% of the copy leaves it as it is and fails: a mass
  deletion in the account is an alert, not an emptied copy.
- **Sign-in from your computer.** `backup.sh auth` prints a link: sign in in your browser (for Google through an
  SSH tunnel to the server). No browser needed on the server; the client secret never leaves it.
- **Documents too.** Google Docs, Sheets and Slides are exported to docx, xlsx and pptx; Dropbox Paper to html.
- **Secrets stay secret.** Client secrets and tokens never on a command line, masked in rclone's logs.
- **Off-host copy** to a second machine over SSH, with a key that can only add files (rrsync).
- **Metrics and a Grafana dashboard** per source.
- **One container**, amd64 and arm64, settings in `.env`.

## Quick start

1. Make a read-only OAuth app for each service you back up, step by step:
   [Google Drive](docs/google-drive.md), [Dropbox](docs/dropbox.md), [Yandex Disk](docs/yandex-disk.md).
2. Install and sign in:

```sh
git clone https://github.com/adsdevdoo/cloud-drive-restic-backup.git && cd cloud-drive-restic-backup
cp .env.example .env                 # DATA_DIR, SOURCES and <NAME>_TYPE per source
mkdir -p secrets && chmod 700 secrets
read -rs v && printf '%s' "$v" > secrets/drive_client_id; unset v       # per service: the app's client id…
read -rs v && printf '%s' "$v" > secrets/drive_client_secret; unset v   # …and secret
head -c 32 /dev/urandom | base64 > secrets/restic_password && chmod 600 secrets/*
mkdir -p /srv/cloud-drive-backup     # the DATA_DIR from .env
docker compose pull && docker compose up -d && docker exec cloud-drive-backup backup.sh init
docker compose run --rm sign-in backup.sh auth gdrive     # per account: sign in (Google: see Sign-in)
```

The first backup then runs on the schedule (04:30); to start it now, see [Install](#install). Details, and what to
save in your password manager, are there too.

## What a run of a source does

1. **List.** rclone lists the account (or its folder) into `DATA_DIR/state/<source>/listing.tsv`: time, size and
   path of every file at that time.
2. **Sync.** `rclone sync` downloads the files that are new or changed since the last run into
   `DATA_DIR/mirror/<source>` and deletes from there the files gone from the account. A file counts as changed when
   its size or modification time differs; both come from the listing, so a run costs list requests (one per folder;
   for Google Drive, one per batch of folders or per 1000 files), not one request per file. If the sync would delete
   more than `MAX_DELETE` percent (default 10) of the files in the copy, the copy stays as it is, and the run fails
   (see [Deletion guard](#deletion-guard)).
3. **Snapshot.** restic snapshots the copy and the listing into `DATA_DIR/restic`, tagged with the source name.
   Retention, by default: 30 daily, 8 weekly, 24 monthly. Once a day `restic prune` removes the data no snapshot
   needs any more; once a week `restic check` reads 10% of the data. If the sync failed, the snapshot is still
   taken, but retention is skipped and the run counts as failed.
4. **Copy off-host** (optional). rsync sends the repository files the second host doesn't have yet.

The scheduler (supercronic) runs each source on its own schedule, daily at 04:30 by default. Two runs of the same
source never overlap; runs of different sources sync at the same time and take turns with the repository.

## Image tags

Images for `linux/amd64` and `linux/arm64`, the same in both registries:

- `ghcr.io/adsdevdoo/cloud-drive-restic-backup`
- [`adsdevdoo/cloud-drive-restic-backup`](https://hub.docker.com/r/adsdevdoo/cloud-drive-restic-backup) (Docker Hub)

| Tag | What it is | Use it when |
|---|---|---|
| `latest` | the newest release | you want releases, no pinning |
| `1`, `1.2`, `1.2.3` | the newest `1.x.x`, the newest `1.2.x`, exactly `1.2.3` | `1`: updates without breaking changes; `1.2.3`: nothing changes until you decide |
| `edge` | the current `main`, not released yet | trying what's coming |
| `sha-abc1234`, full commit SHA | one exact commit | pinning a deployment to a commit |

`compose.yml` runs `latest`; set `IMAGE` in `.env` to pick another tag, or your own build
(`docker build -t cloud-drive-restic-backup:local .`, then `IMAGE=cloud-drive-restic-backup:local`).

Versions follow [Semantic Versioning](https://semver.org/): a new major version means something you have to act on
(settings, data layout, metric names). Changes are listed in [CHANGELOG.md](CHANGELOG.md) and on the
[releases page](https://github.com/adsdevdoo/cloud-drive-restic-backup/releases).

## Install

You need Docker with Compose, a directory for the data with room for all the accounts twice over (the copy and the
repository), and, for each service you back up, an OAuth app of your own with read-only access:
[Google Drive](docs/google-drive.md), [Dropbox](docs/dropbox.md), [Yandex Disk](docs/yandex-disk.md). One app per
service serves all the accounts of that service.

```sh
git clone https://github.com/adsdevdoo/cloud-drive-restic-backup.git
cd cloud-drive-restic-backup
cp .env.example .env               # set DATA_DIR, SOURCES and the settings of each source
mkdir -p secrets && chmod 700 secrets
# For each service (drive, dropbox, yandex) two files: type the value, Enter.
read -rs v && printf '%s' "$v" > secrets/drive_client_id; unset v
read -rs v && printf '%s' "$v" > secrets/drive_client_secret; unset v
head -c 32 /dev/urandom | base64 > secrets/restic_password
chmod 600 secrets/*
mkdir -p /srv/cloud-drive-backup   # the DATA_DIR from .env
docker compose up -d
docker exec cloud-drive-backup backup.sh init
```

**Save `secrets/restic_password` in your password manager.** Without it the snapshots can't be opened. Save the
client ids and secrets of the apps there too; the tokens need no saving, a new sign-in makes new ones.

Then sign in each source, see [Sign-in](#sign-in).

The container checks the settings and the client files when it starts and exits if something is wrong (and Docker
starts it again, and again): `docker logs cloud-drive-backup` says what. A source that is not signed in yet doesn't
stop it (the sign-in of Dropbox and Yandex runs in it); its runs fail until it is. To run every source now instead
of waiting for the schedule, detached from your shell, with the output going to `docker logs`:

```sh
docker exec -d cloud-drive-backup sh -c 'backup.sh >/proc/1/fd/1 2>&1'
docker logs -f cloud-drive-backup
```

A run of a source ends with `[<source>] done: account N files …`. `backup.sh run gdrive` runs one source. The first
run of a big account downloads all of it and can take hours; a scheduled run of the same source meanwhile is
skipped.

The data directory must exist before `up`. Compose won't create it, so that a backup never lands on the root disk
when the backup disk isn't mounted. For the same reason a run never creates the repository; only `init` does.

## Sign-in

`auth` gets the token, keeps it in `DATA_DIR/tokens/<account>.json` (600), and shows which account it is (its e-mail
or login) and how many files and folders the source sees at its top. If it shows another account than you meant,
the browser was signed in to it: sign in again from a private window.

**Google.** `auth` runs `rclone authorize`, which serves the sign-in on `http://127.0.0.1:53682/` of the host and
takes Google's answer there (the client reaches rclone in its environment, not on its command line). Run it on the
host's network, with the `sign-in` service of `compose.yml`, and reach that port from your browser through an SSH
tunnel:

```sh
ssh -L 53682:127.0.0.1:53682 you@backup-host        # on your computer; PuTTY: Connection → SSH → Tunnels
docker compose run --rm sign-in backup.sh auth gdrive  # in that session, in the directory of compose.yml
```

Open the `http://127.0.0.1:53682/auth?state=…` link it prints in the browser on your computer, sign in to the
account to back up and allow read-only access; the page then says *Success*. With a browser on the backup host
itself, no tunnel is needed. A sign-in nobody finishes ends after 15 minutes; Ctrl-C ends it at once. If the SSH
session drops meanwhile, the sign-in goes on waiting, the port taken, until then: `docker ps` shows its container
as `…-sign-in-run-…`, and `docker stop` ends it.

**Dropbox, Yandex.**

```sh
docker exec -it cloud-drive-backup backup.sh auth <source>
```

prints a link. Open it in a browser on any device, sign in to the account and allow read-only access. The service
shows a code: paste it into the terminal (it is not shown) and press Enter.

**A token from elsewhere.** `rclone authorize` run on any computer with a browser works too:

```sh
docker exec -it cloud-drive-backup backup.sh auth <source> --paste   # then paste what rclone printed, Enter
```

It takes the token's JSON, or the line between the arrows (rclone 1.74 prints a base64 block there when given a
base64 config, the headless form `rclone config` suggests). The token must have been made with the client in
`secrets/`, or, with none there, with rclone's own (shared by all rclone users and rate-limited). For Google, have it
ask for read-only access: `rclone authorize drive` asks for full access unless told the scope, e.g. by
`RCLONE_DRIVE_SCOPE=drive.readonly` (with the client in `RCLONE_DRIVE_CLIENT_ID` and `RCLONE_DRIVE_CLIENT_SECRET`,
off the command line). For Dropbox, use `auth` itself: rclone asks for write access, which a read-only app refuses.

Sources in one account share a sign-in: set `<NAME>_ACCOUNT` to the source that signs in (say, a Google shared
drive's source to the one of My Drive). Sign in again (`auth` of any of them) when a run says `refused the token`:
the password was changed, access was revoked, or a Google app is still in "Testing" (its tokens expire after 7
days, see [docs/google-drive.md](docs/google-drive.md)).

rclone renews the access token when it expires and the renewed token is saved back. A Yandex token lasts a year and
so does its refresh token: the backup has rclone renew it once it is three months old, long before both expire.
Tokens are neither in the snapshots nor in the off-host copy.

## Settings

All settings are in `.env`; see `.env.example`.

| Variable | Default | |
|---|---|---|
| `DATA_DIR` | — | host directory for the copies, the repository, the tokens and the state |
| `SOURCES` | — | source names, space-separated: lower-case letters, digits, `_` |
| `SCHEDULE`, `TZ` | `30 4 * * *`, UTC | default schedule, time zone of all schedules |
| `MAX_DELETE` | 10 | a run deletes at most this percentage of the files in the copy of a source (0-100; 100 = no limit) |
| `KEEP_HOURLY`, `KEEP_DAILY`, `KEEP_WEEKLY`, `KEEP_MONTHLY` | 0, 30, 8, 24 | default snapshot retention |
| `CHECK_WEEKDAY`, `CHECK_READ_SUBSET` | 7, 10% | weekly `restic check` (1 = Monday; empty = never) |
| `RCLONE_FLAGS` | — | extra rclone flags, e.g. `--bwlimit 10M` or `--drive-export-formats odt,ods,odp` |
| `COPY_TARGET`, `COPY_PORT` | off, 22 | off-host copy, `user@host:path`; the colon is required |
| `COPY_KEY_FILE`, `COPY_KNOWN_HOSTS_FILE` | `/run/secrets/copy_ssh_key`, `…/copy_known_hosts` | SSH key and host key of the off-host copy |
| `SNAPSHOT_HOST` | `cloud-drive-backup` | host name of the snapshots; retention only touches snapshots with this one, so don't change it later |
| `WAIT_FOR_LOCK` | `no` | `yes`: a run waits for a running run of the same source instead of skipping (for manual loops) |

Per source `<name>`, the settings are `<NAME>_…`, the name in upper case (`gdrive` → `GDRIVE_TYPE`):

| Variable | Default | |
|---|---|---|
| `<NAME>_TYPE` | — | `drive` (Google Drive), `dropbox` or `yandex` (Yandex Disk) |
| `<NAME>_ROOT` | whole account | only this folder of it, e.g. `Photos/2024` |
| `<NAME>_ACCOUNT` | the source itself | share the sign-in of the source of that name (same type) |
| `<NAME>_SHARED_DRIVE` | — | `drive` only: a shared drive instead of My Drive, by its id (`backup.sh drives <name>` lists them) |
| `<NAME>_SHARED_WITH_ME` | `no` | `drive` only: `yes` = the files others shared with the account instead of My Drive |
| `<NAME>_MAX_DELETE` | `MAX_DELETE` | deletion guard of this source |
| `<NAME>_SCHEDULE` | `SCHEDULE` | cron schedule of this source |
| `<NAME>_KEEP_HOURLY` … `_KEEP_MONTHLY` | `KEEP_*` | retention of this source |
| `<NAME>_RCLONE_FLAGS` | `RCLONE_FLAGS` | extra rclone flags of this source |

OAuth clients: `secrets/<type>_client_id` and `secrets/<type>_client_secret`, one pair per service (`drive`,
`dropbox`, `yandex`). rclone gets them, and the token, in a config file of the run
(`DATA_DIR/tokens/.<source>.run.conf`, 600, removed afterwards), never on a command line. With `-vv` rclone may log
what it reads; the script replaces the client secret and the tokens with `***` in everything rclone logs, plain or
JSON (`--use-json-log`). `--dump`, `--log-file` and `--config` are refused: they would print the token or bypass the
mask; so is `-P` (`--progress`), which would write into the listings. `RCLONE_*` variables in `.env` don't reach
rclone; put flags in `RCLONE_FLAGS`.

The rclone flags apply to the listing of the account and of the copy too: a filter (`--exclude`, `--max-age`, …)
narrows the sync, the guard and the account metrics alike. Files a filter leaves out are not deleted from the copy.
Size filters are the exception: Google and Paper documents have no size in the account but one in the copy. Don't
use `--min-size`: it leaves the documents out of the account, not of the copy, and they count as gone from the
account. With `--max-size` a document exported above the limit is downloaded again on every run.

Retention applies to the snapshots of one source; a schedule more often than daily keeps one snapshot a day unless
`KEEP_HOURLY` is set. After changing `.env`, run `docker compose up -d`; to update to the latest image,
`docker compose pull && docker compose up -d`. Both recreate the container: not during a run (`docker logs` shows
when one ends).

## The services

**Google Drive.** A source is My Drive, or with `<NAME>_SHARED_DRIVE` a shared drive, or with
`<NAME>_SHARED_WITH_ME=yes` the files others shared with the account; give the extra ones `<NAME>_ACCOUNT` of the
first so that one sign-in serves all. `backup.sh drives <name>` lists the shared drives the account sees.
- Google Docs, Sheets, Slides and Drawings are exported to docx, xlsx, pptx and svg (rclone's default; change with
  `--drive-export-formats` in the rclone flags). They are exported again when they change. Forms, Sites and Maps
  have no export and are left out. Changing the export formats renames every document in the copy: expect the
  deletion guard to stop that run (see below).
- Shortcuts are skipped: their targets are backed up where they live, and a shortcut to a big shared folder would
  copy all of it once more.
- The trash is not backed up.
- Drive allows two files of the same name in one folder; rclone copies one of them and logs a NOTICE
  `Duplicate object found`. Rename one in Drive to have both.
- Google Photos is not a part of Drive: its API no longer lets apps read a library. Use Google Takeout for it.

**Dropbox.** The source starts at the root of the account: with a Dropbox team that is the team space, the team
folders and your member folder in it; `<NAME>_ROOT` is a path from there (`Marketing`, or `Jane Doe/Projects` for a
folder in the member folder). The shared folders added to the account are a part of it. Paper documents are exported
to html.

**Yandex Disk.** The whole Disk, shared folders included, or a folder of it.

**A file that can't be downloaded** (a shared file whose owner turned downloads off, a file Google flagged as
malware) fails every run: rclone reports it and deletes nothing from the copy that run. Leave it out with a filter,
e.g. `<NAME>_RCLONE_FLAGS=--exclude /Shared/locked.pdf` (the flags are split at spaces and not unquoted: for a name
with a space, use `?` or `*` in its place).

## Deletion guard

Before syncing, a run counts the files of the copy that are gone from the account. If they are more than
`MAX_DELETE` percent of the files in the copy (rounded down; default 10), the run leaves the copy as it is: it
deletes nothing and downloads nothing (after a sign-in to a wrong account that would be all of that account, after
malware the files it wrote). It takes the snapshot without retention and fails, with
`ERROR: N of the M files in the copy are gone from the account` in the log and
`cloud_drive_backup_guard_blocked_files` above 0. The snapshots have the files either way; the guard turns a mass
deletion (by mistake, by malware, a sign-in to a wrong account) into an alert, and keeps the copy, so the files
need not be downloaded again if they come back. Until the files are back or a run goes without the limit, nothing
new of the source is backed up.

If the deletions are expected (you reorganised the account, renamed a big folder, changed the export formats), run
the source once without the limit:

```sh
docker exec -e GDRIVE_MAX_DELETE=100 cloud-drive-backup backup.sh run gdrive
```

The limit is rounded down: with fewer than ten files in the copy one deletion is already too many, with 25 files
three (25 × 10% = 2.5, so 2 are allowed). Give a small source a higher `<NAME>_MAX_DELETE`.

## Restore

```sh
docker exec cloud-drive-backup restic snapshots --tag gdrive
docker exec cloud-drive-backup restic restore latest --tag gdrive --target /data/restore
docker exec cloud-drive-backup restic restore latest --tag gdrive --target /data/restore --include /data/mirror/gdrive/Projects
```

The result lands in `DATA_DIR/restore/data/mirror/gdrive/`; the files are root-only (600). Upload them back with
the service's app or website, or with rclone and a remote that can write.

A file deleted in the account is in the snapshots taken before its deletion: `restic find --tag gdrive <name>`
finds them. The listing in each snapshot (`state/<source>/listing.tsv`) says what the account held at that time.

To restore from the off-host copy: get the directory to any machine with restic and run
`restic -r <dir> restore latest --tag gdrive --target …` with the same password.

## Off-host copy

Set `COPY_TARGET` and put an SSH key in `secrets/copy_ssh_key` and the target's host key in
`secrets/copy_known_hosts`:

```sh
ssh-keygen -t ed25519 -N '' -f secrets/copy_ssh_key
ssh-keyscan -p 22 -t ed25519 backup-host.example > secrets/copy_known_hosts    # same port as COPY_PORT
ssh-keygen -lf secrets/copy_known_hosts     # compare with the fingerprint shown on the target
```

With the rrsync line below, use an empty path: `COPY_TARGET=bkcopy@backup-host.example:` (a user of its own; not
`backup`, a system user on Debian and Ubuntu). The files then land right in the rrsync directory.

On the target, restrict the key to adding files in one directory, with `rrsync` (it comes with rsync on Debian and
Ubuntu and needs python3, which a minimal system may lack; on Alpine `apk add rrsync`):

```
restrict,from="10.0.0.5",command="/usr/bin/rrsync -wo -no-del -no-overwrite -munge /srv/cloud-drive-backup-copy" ssh-ed25519 AAAA… cloud-drive-backup
```

- `-munge` is what keeps the key inside the directory: without it a compromised backup host can upload a symbolic
  link and write through it outside the directory, e.g. into the user's `~/.ssh`, and get a shell on the target
  (rsync older than 3.5 lets it). Keep it.
- `-no-del` blocks deletion, `-no-overwrite` overwriting a file that is there. `-no-overwrite` needs rsync 3.3 or
  newer on the target; with an older one (Debian 12, Ubuntu 24.04) use `-wo -no-del -munge`, and protect the
  received files with `chattr +i` if a compromised backup host must not be able to spoil the copy.

Repository files never change once written, so adding the new ones keeps the copy a valid restic repository. It is
a superset: snapshots pruned locally stay there. Nothing prunes the copy, so pick the snapshot by date when you
restore from it.

A failed copy doesn't fail the run. It has its own metric (below).

## Metrics

Mount a node_exporter textfile collector directory at `/metrics` (see `compose.yml`) to get, per source (label
`source`):

| Metric | |
|---|---|
| `cloud_drive_backup_last_success_timestamp_seconds` | last good run |
| `cloud_drive_backup_last_failure_timestamp_seconds` | last failed run |
| `cloud_drive_backup_last_duration_seconds` | how long the last good run took |
| `cloud_drive_backup_account_files`, `cloud_drive_backup_account_bytes` | what the account (the source's part) held at the last good run; exported documents have no size and count as 0 bytes |
| `cloud_drive_backup_mirror_files`, `cloud_drive_backup_mirror_bytes` | the local copy |
| `cloud_drive_backup_deleted_files` | files gone from the account that the last good run deleted from the copy |
| `cloud_drive_backup_guard_blocked_files` | files gone from the account that the last run did not delete, being too many; 0 = none |

and for the whole repository `cloud_drive_backup_repository_bytes`,
`cloud_drive_backup_copy_last_success_timestamp_seconds`, `cloud_drive_backup_copy_last_duration_seconds`,
`cloud_drive_backup_copy_last_failure_timestamp_seconds`.

The metrics of a source are in `cloud_drive_backup_source.<source>.success.prom`, `….failure.prom` and
`….guard.prom`. When you remove a source from `SOURCES`, delete its three files, or it stays on dashboards and in
alerts with an ever older last run.

Useful alerts:
- no success for longer than the schedule plus a margin:
  `time() - cloud_drive_backup_last_success_timestamp_seconds > 26*3600` for daily sources;
- the last run failed: failure newer than success;
- the guard held back deletions: `cloud_drive_backup_guard_blocked_files > 0`.

## Files

| | |
|---|---|
| `backup.sh` | everything a run and a sign-in do; the comments at the top explain the less obvious parts |
| `entrypoint.sh` | checks the settings, writes the crontab (a line per source) and starts supercronic |
| `Dockerfile` | Alpine with rclone, restic, supercronic, curl, jq, rsync |
| `.github/workflows/build.yml` | tests on pushes to `main`, release tags and pull requests; images for amd64 and arm64 on `main` and on release tags; GitHub Releases from `CHANGELOG.md` |
| `CHANGELOG.md` | what changed in each release |
| `docs/google-drive.md`, `docs/dropbox.md`, `docs/yandex-disk.md` | a read-only OAuth app for each service, step by step |
| `compose.yml`, `.env.example` | how to run it |
| `tests/test.sh` | tests against a stub rclone over the real one and a stub curl, no account needed: `sh tests/test.sh` (Docker; the first build downloads Alpine packages) |
| `grafana/cloud-drive-backup.json` | Grafana dashboard: a table of the sources, repository, off-host copy, trends; pick the Prometheus data source in the dropdown at the top |
| `CLAUDE.md` | rules for changing the code |

Inside `DATA_DIR`:

| | |
|---|---|
| `mirror/<source>/` | the copy of each source |
| `state/<source>/listing.tsv` | the last listing of the account; in every snapshot of the source |
| `tokens/<account>.json` | the token of each signed-in account (600); not in the snapshots |
| `restic/` | the repository |
| `cache/` | restic's cache |

## License

MIT
