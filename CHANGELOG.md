# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html): a new major version means a change you have to act
on (settings, data layout, metric names).

## [Unreleased]

### Fixed
- Google sign-in: `backup.sh auth` failed for every Google account, Google refusing to exchange the code pasted
  from the browser's address bar ("doesn't comply with Google's OAuth 2.0 policy for keeping apps secure"). It now
  runs `rclone authorize`, which takes Google's answer on `127.0.0.1:53682` of the host; the client reaches it in
  its environment. A new `sign-in` service in `compose.yml` runs it on the host's network; the browser reaches it
  through an SSH tunnel (README, Sign-in). A sign-in nobody finishes ends after 15 minutes.
- Dropbox and Yandex sign-in: the form `auth` sent to the token endpoint ended with a line end, which became a part
  of its last value, the client secret: Yandex answered "Wrong client secret" to a right one.
- docs/google-drive.md: *Publish app* needs a home page, a privacy policy link and an authorized domain on the
  Branding page; which of the Drive scopes to pick; the client secret is shown only once.

### Added
- `backup.sh auth <source> --paste`: a token from `rclone authorize` run elsewhere, as its JSON or as the base64
  block rclone 1.74 prints when given a base64 config.

### Changed
- `backup.sh auth` takes a token from `rclone authorize` only with `--paste`. Without it, `auth` of Google runs
  `rclone authorize` and reads nothing from stdin; `auth` of Dropbox and Yandex takes only a code (or an address
  with it).

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
