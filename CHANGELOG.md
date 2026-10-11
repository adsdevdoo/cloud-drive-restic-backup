# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html): a new major version means a change you have to act
on (settings, data layout, metric names).

## [Unreleased]

## [1.0.0] - 2026-10-11

First release.

### Added
- Any number of sources (`SOURCES`): Google Drive (My Drive, a shared drive, "Shared with me"), Dropbox and Yandex
  Disk accounts, or a folder of one, each with its own schedule, retention and rclone flags. Sources in one account
  share a sign-in (`<NAME>_ACCOUNT`).
- `backup.sh auth <source>`: sign-in in any browser with a read-only OAuth client of your own; the code (or the
  address Google ends on) is pasted into the container. A token from `rclone authorize` is taken too. The token
  stays in the data directory; rclone's renewals are saved back.
- `backup.sh drives <source>`: the shared drives of a Google account, for `<NAME>_SHARED_DRIVE`.
- `rclone sync` of each account into a local copy, with a deletion guard: a run that would delete more than
  `MAX_DELETE` percent of the copy (default 10) leaves the copy as it is and fails. A listing of the
  account is kept with every snapshot.
- One restic repository for all sources: snapshots tagged by source, per-source retention, prune once a day,
  weekly `restic check`.
- Client secrets and tokens masked in everything rclone logs; `--dump`, `--log-file`, `--config` and `-P` refused.
- Optional off-host copy of the repository with rsync over SSH (`COPY_TARGET`).
- Metrics for the node_exporter textfile collector, per source; Grafana dashboard in `grafana/`.
- Offline tests (`tests/test.sh`) against a stub rclone over the real one and a stub curl; images for amd64 and
  arm64 on ghcr.io.

[Unreleased]: https://github.com/adsdevdoo/cloud-drive-restic-backup/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/adsdevdoo/cloud-drive-restic-backup/releases/tag/v1.0.0
