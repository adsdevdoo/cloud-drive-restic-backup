#!/usr/bin/env bash
#
# cloud-drive-restic-backup: scheduled backup of Google Drive, Dropbox and Yandex Disk accounts into one restic
# repository. For each source (an account, a folder in one, a Google shared drive or "Shared with me") a run does:
#   1. rclone lists the account into /data/state/<source>/listing.tsv (what it held at that time) and syncs it into
#      /data/mirror/<source>: new and changed files are downloaded, files gone from the account are deleted from the
#      copy. Nothing is ever written to the account.
#   2. restic takes a snapshot of the copy and the listing into /data/restic and applies the source's retention. A
#      file deleted in the account stays in the snapshots taken before.
#   3. Optionally the repository files are copied to another host with rsync over SSH.
#
# The deletion guard. A run that would delete more than MAX_DELETE percent of the files in the copy leaves the copy
# as it is (nothing deleted, nothing downloaded) and fails. A mass deletion in the account (by mistake, by malware,
# or the token of a wrong account) shows up as a failed run instead of an emptied copy. The snapshots would keep the
# files either way; the guard is the alarm, and the copy need not be downloaded again if the files come back.
#
# Usage (inside the container):
#   backup.sh                   a run of every source in SOURCES, one after another
#   backup.sh run [source...]   a run of those sources (the scheduler runs one per crontab line)
#   backup.sh init              create the restic repository, once
#   backup.sh check             check the settings and secret files of every source (the entrypoint runs this)
#   backup.sh auth <source>     sign in to the account of a source, interactively (docker exec -it)
#   backup.sh drives <source>   list the shared drives of the Google account of a source, for <NAME>_SHARED_DRIVE
#
# Settings come from the environment, see .env.example. Per source <name>: <NAME>_TYPE and so on (the name in upper
# case); a per-source value falls back to the global one where there is one (SCHEDULE, KEEP_*, RCLONE_FLAGS,
# MAX_DELETE).
#
# Sign-in. Each service has an OAuth client (an app) of your own with read-only access:
# /run/secrets/<type>_client_id and <type>_client_secret, type drive, dropbox or yandex. `auth` gets a token for an
# account and keeps it in /data/tokens/<account>.json. The account is the source name, or <NAME>_ACCOUNT: sources in
# one account (a drive and its shared drives) share one sign-in. A run writes the rclone config of the source, token
# included, to /data/tokens/.<source>.run.conf (`auth` and `drives` to their own) and removes it at the end. rclone
# renews an expired token in that file, and the renewed token goes back to /data/tokens/<account>.json, unless that
# file changed meanwhile (`auth` again, or another source of the account). A token that expires within 275 days goes
# to rclone as expired, so that a year-long Yandex token is renewed while its refresh token still works. Tokens are
# neither in the snapshots nor in the off-host copy.
#
# Locks. Each source has its own lock (/data/.lock-<source>): runs of different sources sync at the same time.
# Everything that touches the repository (snapshot, forget, prune, check, off-host copy) runs under one more lock,
# /data/.restic.lock, waited for, so restic never runs twice at once and the off-host copy never sees a half-written
# repository.
#
# Comparing files. A file counts as changed when its size or modification time differs from the local file's; both
# come from the listing, so a run costs no request per file. Google documents have no size: they are exported (docx,
# xlsx, pptx by default) when their modification time changes. Dropbox Paper documents are exported (html) the same
# way.
#
set -euo pipefail
umask 077

# --- settings (environment) ---
# Not into SOURCES itself: bash does not export an array, and the runs of several sources start backup.sh again.
read -r -a SOURCE_LIST <<<"${SOURCES:-}"
KEEP_HOURLY="${KEEP_HOURLY:-0}"
KEEP_DAILY="${KEEP_DAILY:-30}"
KEEP_WEEKLY="${KEEP_WEEKLY:-8}"
KEEP_MONTHLY="${KEEP_MONTHLY:-24}"
# Extra rclone flags for every source, e.g. --bwlimit 10M or --drive-export-formats odt,ods; space-separated.
RCLONE_FLAGS="${RCLONE_FLAGS:-}"
# A run deletes at most this percentage of the files in the copy; above it, it leaves the copy as it is and fails.
MAX_DELETE="${MAX_DELETE:-10}"
# restic check on this weekday (date +%u, 1 = Monday; empty = never), reading this share of the data.
CHECK_WEEKDAY="${CHECK_WEEKDAY-7}"
CHECK_READ_SUBSET="${CHECK_READ_SUBSET:-10%}"
SNAPSHOT_HOST="${SNAPSHOT_HOST:-cloud-drive-backup}"
# yes: wait for a running backup of the same source instead of skipping (for loops of manual runs).
WAIT_FOR_LOCK="${WAIT_FOR_LOCK:-no}"
# Off-host copy: empty COPY_TARGET = off.
COPY_TARGET="${COPY_TARGET:-}"
COPY_PORT="${COPY_PORT:-22}"
COPY_KEY="${COPY_KEY_FILE:-/run/secrets/copy_ssh_key}"
COPY_KNOWN_HOSTS="${COPY_KNOWN_HOSTS_FILE:-/run/secrets/copy_known_hosts}"
SECRETS_DIR="/run/secrets"
# RESTIC_REPOSITORY, RESTIC_PASSWORD_FILE and RESTIC_CACHE_DIR come from the image.

# --- paths ---
MIRROR_ROOT="/data/mirror"
STATE_ROOT="/data/state"
TOKEN_ROOT="/data/tokens"
REPO_LOCK="/data/.restic.lock"
# The day of the last prune and of the last check (date +%F), so that several runs a day do it once.
PRUNE_STAMP="/data/.last-prune"
CHECK_STAMP="/data/.last-check"
# node_exporter textfile collector; nothing is written when it is not mounted.
METRICS_DIR="/metrics"

# --- OAuth of the services ---
# Google sends the browser back to the loopback address the client is registered with (the one rclone uses), where
# nothing listens: the code is in the address bar. Dropbox without a redirect, and Yandex with its own verification
# page, show the code. The scopes are read-only; Dropbox and Yandex give the token the permissions of the app.
GOOGLE_AUTH_URL="https://accounts.google.com/o/oauth2/v2/auth"
GOOGLE_TOKEN_URL="https://oauth2.googleapis.com/token"
GOOGLE_REDIRECT="http://127.0.0.1:53682/"
GOOGLE_SCOPE="https://www.googleapis.com/auth/drive.readonly"
GOOGLE_ABOUT_URL="https://www.googleapis.com/drive/v3/about?fields=user(emailAddress)"
DROPBOX_AUTH_URL="https://www.dropbox.com/oauth2/authorize"
DROPBOX_TOKEN_URL="https://api.dropboxapi.com/oauth2/token"
DROPBOX_ACCOUNT_URL="https://api.dropboxapi.com/2/users/get_current_account"
YANDEX_AUTH_URL="https://oauth.yandex.ru/authorize"
YANDEX_TOKEN_URL="https://oauth.yandex.ru/token"
YANDEX_REDIRECT="https://oauth.yandex.ru/verification_code"
YANDEX_DISK_URL="https://cloud-api.yandex.net/v1/disk/"

# The source of this run and its settings, set by load_source; the token of its account, set by load_token.
SRC=""
S_CONF=""
S_TOKEN=""
# The token as write_conf gave it to rclone: save_token sees a renewal by comparing with it.
S_GIVEN=""
# The command, a part of the name of the rclone config: `auth` or `drives` must not remove the config of a run of the
# same source going on meanwhile (runs of one source never overlap, they take the source lock).
CMD="run"
# A token that expires sooner than this goes to rclone as expired, so that rclone renews it. Yandex gives a token and a
# refresh token that both expire in a year and asks to renew every three months; rclone renews only an expired token,
# when the refresh token is gone too. Google and Dropbox tokens last hours and are renewed every run anyway.
RENEW_BEFORE=$(( 275 * 86400 ))
# Files gone from the account that this run deleted from the copy, for the metrics.
DELETED=0


log() {
    echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') ${SRC:+[$SRC] }$*"
}


# write_prom <file> : stdin -> METRICS_DIR/<file>, atomically, readable by node_exporter.
write_prom() {
    local tmp

    if [[ ! -d "$METRICS_DIR" ]]; then
        cat >/dev/null
        return 0
    fi
    tmp="$(mktemp "$METRICS_DIR/.${1%.prom}.XXXXXX")" || return 1
    cat >"$tmp" && chmod 644 "$tmp" && mv "$tmp" "$METRICS_DIR/$1" || { rm -f "$tmp"; return 1; }
}


# source_prom <success|failure|guard> : a metric file of this source. The dots keep it apart from the files of the
# repository and of the copy, and from the files of other sources (a source x_failure must not overwrite the failure
# file of x): a source name has no dot.
source_prom() {
    printf 'cloud_drive_backup_source.%s.%s.prom' "$SRC" "$1"
}


# cleanup_conf : removes the rclone config of the source (it holds the client secret and the token), the files kept
# next to it (the refused mark, the header of whoami_account), and what rclone leaves there if killed while saving
# the config (<file><digits>, <file>.old<digits>).
cleanup_conf() {
    [[ -z "$S_CONF" ]] || rm -f "$S_CONF" "$S_CONF"*
}


# finish_conf : on the way out, saves a token rclone renewed (a run stopped by a signal ends inside rclone_src,
# before it saves), then removes the config. Stops a signal's way out from logging into a listing file: stdout may
# still go to one.
finish_conf() {
    exec >&2
    [[ -z "$S_GIVEN" ]] || save_token || true
    cleanup_conf
}


on_exit() {
    local rc=$?

    finish_conf
    if (( rc != 0 )); then
        log "ERROR: backup failed (exit code $rc)."
        write_prom "$(source_prom failure)" <<EOF || true
# HELP cloud_drive_backup_last_failure_timestamp_seconds When the last backup run of a source failed.
# TYPE cloud_drive_backup_last_failure_timestamp_seconds gauge
cloud_drive_backup_last_failure_timestamp_seconds{source="$SRC"} $(date +%s)
EOF
    fi
}


# upper <name> : the name in upper case, the prefix of its settings.
upper() {
    printf '%s' "${1^^}"
}


# setting <name> <key> [default] : the value of <NAME>_<key>, or the default when it is unset or empty.
setting() {
    local var
    var="$(upper "$1")_$2"
    printf '%s' "${!var:-${3:-}}"
}


# load_source <name> : the settings of that source into the S_* variables. Paths built from the type and the account
# are used only after check_source validated them.
load_source() {
    SRC="$1"
    S_TYPE="$(setting "$1" TYPE)"
    S_ROOT="$(setting "$1" ROOT)"
    S_ACCOUNT="$(setting "$1" ACCOUNT "$1")"
    S_SHARED_DRIVE="$(setting "$1" SHARED_DRIVE)"
    S_SHARED_WITH_ME="$(setting "$1" SHARED_WITH_ME no)"
    S_RCLONE_FLAGS="$(setting "$1" RCLONE_FLAGS "$RCLONE_FLAGS")"
    S_MAX_DELETE="$(setting "$1" MAX_DELETE "$MAX_DELETE")"
    S_KEEP_HOURLY="$(setting "$1" KEEP_HOURLY "$KEEP_HOURLY")"
    S_KEEP_DAILY="$(setting "$1" KEEP_DAILY "$KEEP_DAILY")"
    S_KEEP_WEEKLY="$(setting "$1" KEEP_WEEKLY "$KEEP_WEEKLY")"
    S_KEEP_MONTHLY="$(setting "$1" KEEP_MONTHLY "$KEEP_MONTHLY")"
    S_CLIENT_ID_FILE="$SECRETS_DIR/${S_TYPE}_client_id"
    S_CLIENT_SECRET_FILE="$SECRETS_DIR/${S_TYPE}_client_secret"
    MIRROR="$MIRROR_ROOT/$1"
    STATE_DIR="$STATE_ROOT/$1"
    LISTING="$STATE_DIR/listing.tsv"
    SOURCE_LOCK="/data/.lock-$1"
    TOKEN_FILE="$TOKEN_ROOT/$S_ACCOUNT.json"
    TOKEN_LOCK="$TOKEN_ROOT/.$S_ACCOUNT.lock"
    S_CONF="$TOKEN_ROOT/.$1.$CMD.conf"
}


# fail <message> : logs the error and exits 1.
fail() {
    log "ERROR: $*"
    exit 1
}


# number <name> <value> : fails unless the value is a number without leading zeros (bash arithmetic reads 08 as
# octal).
number() {
    [[ "$2" =~ ^(0|[1-9][0-9]*)$ ]] || fail "$1 must be a number, got '$2'."
}


# percent <name> <value> : fails unless the value is a whole number from 0 to 100.
percent() {
    [[ "$2" =~ ^(0|[1-9][0-9]?|100)$ ]] || fail "$1 must be a whole number from 0 to 100, got '$2'."
}


# valid_name <name> : whether a source or account name is good for variable names, file names and metric labels.
valid_name() {
    [[ "$1" =~ ^[a-z][a-z0-9_]{0,31}$ ]]
}


# check_read_subset : whether restic check --read-data-subset takes CHECK_READ_SUBSET: a percentage above 0 and at
# most 100, n/t with n at most t and t at most 256, or a size with a unit. A bad value would fail every run on the
# check day, after the snapshot.
check_read_subset() {
    local v="$CHECK_READ_SUBSET"

    if [[ "$v" =~ ^([0-9]{1,3}(\.[0-9]+)?)%$ ]]; then
        V="${BASH_REMATCH[1]}" gawk 'BEGIN { v = ENVIRON["V"] + 0; exit !(v > 0 && v <= 100) }'
    elif [[ "$v" =~ ^([1-9][0-9]{0,8})/([1-9][0-9]{0,8})$ ]]; then
        (( BASH_REMATCH[1] <= BASH_REMATCH[2] && BASH_REMATCH[2] <= 256 ))
    else
        [[ "$v" =~ ^[1-9][0-9]{0,8}[KMGT]$ ]]
    fi
}


check_global_settings() {
    local v name seen=" "

    (( ${#SOURCE_LIST[@]} > 0 )) || fail "SOURCES is empty: list the source names, e.g. SOURCES=gdrive dropbox."
    for name in "${SOURCE_LIST[@]}"; do
        # The name goes into variable names, file names and metric labels.
        valid_name "$name" \
            || fail "source name '$name' must be lower-case letters, digits and _, starting with a letter, up to 32."
        [[ "$seen" != *" $name "* ]] || fail "source '$name' is listed twice in SOURCES."
        seen+="$name "
    done
    for v in KEEP_HOURLY KEEP_DAILY KEEP_WEEKLY KEEP_MONTHLY COPY_PORT; do
        number "$v" "${!v}"
    done
    percent MAX_DELETE "$MAX_DELETE"
    [[ "$CHECK_WEEKDAY" =~ ^[1-7]?$ ]] || fail "CHECK_WEEKDAY must be 1-7 or empty, got '$CHECK_WEEKDAY'."
    check_read_subset || fail "CHECK_READ_SUBSET must be like 10% (above 0, at most 100), 1/5 (n at most t, t at most 256) or 500M, got '$CHECK_READ_SUBSET'."
    [[ "$WAIT_FOR_LOCK" =~ ^(yes|no)$ ]] || fail "WAIT_FOR_LOCK must be yes or no, got '$WAIT_FOR_LOCK'."
    # Without a colon rsync copies to a local path inside the container and reports success.
    if [[ -n "$COPY_TARGET" && "$COPY_TARGET" != *:* ]]; then
        fail "COPY_TARGET must be user@host:path (an empty path after the colon is fine)."
    fi
    if [[ -n "$COPY_TARGET" ]]; then
        [[ -s "$COPY_KEY" && -s "$COPY_KNOWN_HOSTS" ]] || fail "COPY_TARGET is set, but $COPY_KEY or $COPY_KNOWN_HOSTS is missing or empty."
    fi
    [[ -s "$RESTIC_PASSWORD_FILE" ]] || fail "$RESTIC_PASSWORD_FILE is missing or empty."
}


# check_source <name> : the settings and client files of that source (loads it). The token is checked by the run:
# a source not signed in yet must not stop the container, `auth` runs in it.
check_source() {
    local v up flags s

    load_source "$1"
    up="$(upper "$1")"
    for v in "$S_TYPE" "$S_ROOT" "$S_ACCOUNT" "$S_SHARED_DRIVE" "$S_SHARED_WITH_ME" "$S_RCLONE_FLAGS"; do
        [[ "$v" != *$'\n'* ]] || fail "a setting of $1 contains a newline."
    done
    [[ "$S_TYPE" =~ ^(drive|dropbox|yandex)$ ]] || fail "${up}_TYPE must be drive, dropbox or yandex, got '$S_TYPE'."
    valid_name "$S_ACCOUNT" \
        || fail "${up}_ACCOUNT must be lower-case letters, digits and _, starting with a letter, up to 32, got '$S_ACCOUNT'."
    # One token, one service.
    for s in "${SOURCE_LIST[@]}"; do
        if [[ "$s" != "$1" && "$(setting "$s" ACCOUNT "$s")" == "$S_ACCOUNT" && "$(setting "$s" TYPE)" != "$S_TYPE" ]]; then
            fail "$1 and $s share the account $S_ACCOUNT, so they must have the same TYPE."
        fi
    done
    [[ "$S_SHARED_WITH_ME" =~ ^(yes|no)$ ]] || fail "${up}_SHARED_WITH_ME must be yes or no, got '$S_SHARED_WITH_ME'."
    if [[ "$S_TYPE" != drive && ( -n "$S_SHARED_DRIVE" || "$S_SHARED_WITH_ME" == yes ) ]]; then
        fail "${up}_SHARED_DRIVE and ${up}_SHARED_WITH_ME are for TYPE=drive only."
    fi
    [[ -z "$S_SHARED_DRIVE" || "$S_SHARED_WITH_ME" == no ]] \
        || fail "${up}_SHARED_DRIVE and ${up}_SHARED_WITH_ME exclude each other: make two sources."
    [[ -z "$S_SHARED_DRIVE" || "$S_SHARED_DRIVE" =~ ^[A-Za-z0-9_-]+$ ]] \
        || fail "${up}_SHARED_DRIVE must be the id of a shared drive (backup.sh drives $1 lists them), got '$S_SHARED_DRIVE'."
    # --dump prints requests, the token in their headers; --log-file writes the log past the filter of rclone_src;
    # --config would replace the config of the run, and with it the account; -P (--progress, or in a cluster like -vP)
    # writes to stdout, which is the listing of the account.
    # Split as rclone_src splits them: a tab separates flags too.
    read -r -a flags <<<"$S_RCLONE_FLAGS"
    for v in "${flags[@]}"; do
        [[ "$v" != --dump* && "$v" != --log-file* && "$v" != --config* && "$v" != --progress* \
            && ! "$v" =~ ^-[A-Za-z]*P ]] \
            || fail "the rclone flags of $1 must not contain --dump, --log-file, --config or -P (--progress)."
    done
    percent "${up}_MAX_DELETE" "$S_MAX_DELETE"
    number "${up}_KEEP_HOURLY" "$S_KEEP_HOURLY"
    number "${up}_KEEP_DAILY" "$S_KEEP_DAILY"
    number "${up}_KEEP_WEEKLY" "$S_KEEP_WEEKLY"
    number "${up}_KEEP_MONTHLY" "$S_KEEP_MONTHLY"
    # All zero: restic forget would remove nothing and say so, every run.
    (( S_KEEP_HOURLY + S_KEEP_DAILY + S_KEEP_WEEKLY + S_KEEP_MONTHLY > 0 )) || fail "the KEEP_* settings of $1 are all 0."
    # Without both, rclone uses its own client: works with a token from rclone authorize, not with `auth`.
    if [[ -e "$S_CLIENT_ID_FILE" || -e "$S_CLIENT_SECRET_FILE" ]]; then
        [[ -s "$S_CLIENT_ID_FILE" && -s "$S_CLIENT_SECRET_FILE" ]] \
            || fail "$S_CLIENT_ID_FILE and $S_CLIENT_SECRET_FILE: both or neither, and not empty."
    fi
}


# check_data : fails unless /data is a mount: without it the repository, the copies and the tokens would go into the
# container.
check_data() {
    mountpoint -q /data || fail "/data is not mounted: mount the data directory (DATA_DIR in compose)."
}


check_repository() {
    if [[ ! -f "$RESTIC_REPOSITORY/config" ]]; then
        fail "no restic repository in $RESTIC_REPOSITORY. Is the data volume mounted? First install: backup.sh init."
    fi
}


# valid_token <json> : whether it is a token as rclone keeps it: a JSON object on one line with an access token.
valid_token() {
    [[ -n "$1" && "$1" != *$'\n'* ]] \
        && printf '%s' "$1" | jq -e 'type == "object" and (.access_token | type == "string" and length > 0)' >/dev/null 2>&1
}


# load_token : the token of the source's account into S_TOKEN.
load_token() {
    [[ -s "$TOKEN_FILE" ]] || fail "the account $S_ACCOUNT is not signed in yet: docker exec -it <container> backup.sh auth $SRC"
    S_TOKEN="$(<"$TOKEN_FILE")"
    valid_token "$S_TOKEN" || fail "$TOKEN_FILE is not a token: sign in again with backup.sh auth $SRC."
}


# store_token <json> : the token file of the account, replaced atomically. The caller holds TOKEN_LOCK.
store_token() {
    local tmp

    mkdir -p "$TOKEN_ROOT" || return 1
    tmp="$(mktemp "$TOKEN_ROOT/.$S_ACCOUNT.json.XXXXXX")" || return 1
    printf '%s\n' "$1" >"$tmp" && mv "$tmp" "$TOKEN_FILE" || { rm -f "$tmp"; return 1; }
}


# write_conf : the rclone config of the run into S_CONF: the remote "src:" with the client and the token. A token
# expiring within RENEW_BEFORE goes in as expired (see there); the token given is in S_GIVEN.
write_conf() {
    local id="" secret="" expiry secs

    if [[ -s "$S_CLIENT_ID_FILE" ]]; then
        id="$(<"$S_CLIENT_ID_FILE")"
        secret="$(<"$S_CLIENT_SECRET_FILE")"
    fi
    [[ "$id$secret" != *$'\n'* ]] || fail "$S_CLIENT_ID_FILE or $S_CLIENT_SECRET_FILE has more than one line."
    S_GIVEN="$S_TOKEN"
    # rclone writes the expiry in RFC 3339 with fractions and the offset of TZ; GNU date reads that. No expiry, or
    # Go's zero time (year 1): a token that never expires.
    expiry="$(printf '%s' "$S_TOKEN" | jq -r '.expiry // empty')"
    if [[ -n "$expiry" ]] && secs="$(date -d "$expiry" +%s 2>/dev/null)" \
        && (( secs > 0 && secs < $(date +%s) + RENEW_BEFORE )); then
        S_GIVEN="$(printf '%s' "$S_TOKEN" | jq -c '.expiry = "2000-01-01T00:00:00Z"')"
    fi
    mkdir -p "$TOKEN_ROOT"
    {
        printf '[src]\ntype = %s\n' "$S_TYPE"
        [[ -z "$id" ]] || printf 'client_id = %s\nclient_secret = %s\n' "$id" "$secret"
        printf 'token = %s\n' "$S_GIVEN"
        if [[ "$S_TYPE" == drive ]]; then
            printf 'scope = drive.readonly\n'
            # A shortcut would copy its target once more, and a shortcut to a big shared folder all of it.
            printf 'skip_shortcuts = true\n'
            [[ -z "$S_SHARED_DRIVE" ]] || printf 'team_drive = %s\n' "$S_SHARED_DRIVE"
            [[ "$S_SHARED_WITH_ME" == no ]] || printf 'shared_with_me = true\n'
        fi
    } >"$S_CONF"
}


# save_token : when rclone changed the token in S_CONF (renewed it), writes it to the token file of the account,
# unless that file changed since this run read it (`auth` meanwhile, or another source of the account): the newer
# sign-in wins.
save_token() {
    local raw new what="renewed by rclone"

    [[ -f "$S_CONF" ]] || return 0
    # rclone rewrites the whole file when it saves a token: the token line of the [src] section.
    raw="$(gawk '/^\[/ { in_src = ($0 == "[src]"); next } in_src && sub(/^token[ \t]*=[ \t]*/, "") { print; exit }' "$S_CONF")" || return 1
    [[ -n "$raw" && "$raw" != "$S_GIVEN" ]] || return 0
    valid_token "$raw" || { log "ERROR: rclone left something that is not a token in $S_CONF; not saved."; return 1; }
    new="$raw"
    # The same expiry: rclone did not renew it (a renewal always sets a new expiry), it only rewrote it (its yandex
    # backend sets the token type). The expiry is then the one write_conf may have made up: back to the real one.
    if [[ "$(printf '%s' "$raw" | jq -c .expiry)" == "$(printf '%s' "$S_GIVEN" | jq -c .expiry)" ]]; then
        new="$(printf '%s' "$raw" | S="$S_TOKEN" jq -c '(env.S | fromjson) as $s
            | if $s | has("expiry") then .expiry = $s.expiry else del(.expiry) end')" || return 1
        what="changed by rclone (not renewed)"
    fi
    if [[ "$new" != "$S_TOKEN" ]]; then
        (
            exec 7>"$TOKEN_LOCK" && flock 7 || exit 1
            if [[ "$(cat "$TOKEN_FILE" 2>/dev/null)" != "$S_TOKEN" ]]; then
                log "token: the token of $S_ACCOUNT changed during the run (auth, or another source of the account); keeping that one"
                exit 0
            fi
            store_token "$new" || exit 1
            log "token: $what and saved"
        ) || return 1
        S_TOKEN="$new"
    fi
    S_GIVEN="$raw"
}


# mask_secrets : stdin -> stderr, each line prefixed with the source, with the client secret and the tokens of the
# run replaced by ***. They are masked by value: as they are, quoted once (Go %q: \ and " escaped) and quoted twice
# (that inside a JSON log line). A line saying the service refused the token or the client writes "token" or "client"
# to the file <S_CONF>.refused.
mask_secrets() {
    local secret="" at="" rt=""

    [[ ! -s "$S_CLIENT_SECRET_FILE" ]] || secret="$(<"$S_CLIENT_SECRET_FILE")"
    at="$(printf '%s' "$S_TOKEN" | jq -r '.access_token // empty' 2>/dev/null)" || at=""
    rt="$(printf '%s' "$S_TOKEN" | jq -r '.refresh_token // empty' 2>/dev/null)" || rt=""
    K1="$secret" K2="$at" K3="$rt" M="$S_CONF.refused" P="[$SRC] " gawk '
        function esc(s,    i, c, out) {
            out = ""
            for (i = 1; i <= length(s); i++) {
                c = substr(s, i, 1)
                out = out (c == "\\" || c == "\"" ? "\\" : "") c
            }
            return out
        }
        # hide <line> <text> : the line with every occurrence of the text replaced by ***; no regex involved.
        function hide(s, k,    i, out) {
            out = ""
            while ((i = index(s, k)) > 0) {
                out = out substr(s, 1, i - 1) "***"
                s = substr(s, i + length(k))
            }
            return out s
        }
        BEGIN {
            n = 0
            for (j = 1; j <= 3; j++) {
                k = ENVIRON["K" j]
                if (k != "") {
                    key[++n] = esc(esc(k)); key[++n] = esc(k); key[++n] = k
                }
            }
        }
        # The OAuth errors only: the "fetch token" error of rclone comes for a network error too. A token:
        # invalid_grant (revoked, expired, password changed), Dropbox expired_access_token and invalid_access_token,
        # Yandex Disk UnauthorizedError (a 401), rclone "no refresh token". The client: its id or secret is wrong, or
        # it was deleted.
        /invalid_grant|expired_access_token|invalid_access_token|UnauthorizedError|no refresh token/ { print "token" >ENVIRON["M"] }
        /invalid_client|unauthorized_client/ { print "client" >ENVIRON["M"] }
        {
            for (j = 1; j <= n; j++)
                $0 = hide($0, key[j])
            print ENVIRON["P"] $0; fflush()
        }' >&2
}


# rclone_src <rclone args...> : runs rclone with the config of the run, the remote "src:". rclone's log (stderr) goes
# to stderr through mask_secrets, its stdout as is. Afterwards a renewed token is saved. Returns rclone's exit code.
rclone_src() {
    local flags rc=0

    read -r -a flags <<<"$S_RCLONE_FLAGS"
    rm -f "$S_CONF.refused"
    # rclone's stderr into the pipe to the filter, its stdout to the stdout of rclone_src (fd 3). A pipeline, not a
    # process substitution: it ends with the filter, so its lines and the refused mark come before what follows.
    # With pipefail the status is rclone's unless the filter fails.
    {
        (
            # Only the config of the run and the flags reach rclone: an RCLONE_* variable from the environment
            # (env_file) could send the log past the filter (RCLONE_LOG_FILE) or change the remote.
            local v
            for v in $(compgen -e); do
                [[ "$v" != RCLONE_* ]] || unset "$v"
            done
            exec rclone --config "$S_CONF" --log-format date,time,UTC "$@" "${flags[@]}"
        ) 2>&1 1>&3 3>&- | mask_secrets 3>&-
    } 3>&1 || rc=$?
    # Messages to stderr: stdout is rclone's, often a listing going to a file.
    save_token >&2 || rc=1
    if grep -qx client "$S_CONF.refused" 2>/dev/null; then
        log "ERROR: $S_TYPE refused the OAuth client: check $S_CLIENT_ID_FILE and $S_CLIENT_SECRET_FILE, then sign in again with backup.sh auth $SRC" >&2
    elif grep -qx token "$S_CONF.refused" 2>/dev/null; then
        log "ERROR: $S_TYPE refused the token of $S_ACCOUNT: sign in again with backup.sh auth $SRC" >&2
    fi
    return "$rc"
}


# remote_path : the rclone path of the source: src:<root>. For Dropbox it starts with /: rclone then works from the
# root of the account's namespace, which for a Dropbox team holds the team folders besides the member's own folder;
# without the / it is the member's folder only.
remote_path() {
    local root="${S_ROOT#/}"

    root="${root%/}"
    if [[ "$S_TYPE" == dropbox ]]; then
        printf 'src:/%s' "$root"
    else
        printf 'src:%s' "$root"
    fi
}


# sync_source : 0 when rclone listed the account and synced the copy with it, 1 otherwise (the snapshot is taken
# either way). The listing replaces the previous one when it is complete. When the sync would delete more files of
# the copy than MAX_DELETE percent, the copy stays as it is and the run fails.
sync_source() {
    local tmp copy_list files gone allowed blocked=0 max=()

    DELETED=0
    mkdir -p "$MIRROR" "$STATE_DIR" || return 1
    rm -f "$STATE_DIR"/*.tmp.*
    # rclone downloads into <name>.<8 hex digits>.partial and renames it when done; a run killed meanwhile (out of
    # memory, a container stop) leaves it behind, and it would count as a file gone from the account. First thing,
    # so that a snapshot after a failed listing doesn't keep it either.
    find "$MIRROR" -type f -regextype posix-extended -regex '.*\.[0-9a-f]{8}\.partial' -delete || return 1

    # time <TAB> size <TAB> path: the path last, so a tab in a name does not shift the columns. A Google or Paper
    # document has the extension of its export format and no size (-1).
    tmp="$(mktemp "$STATE_DIR/listing.tmp.XXXXXX")" || return 1
    log "rclone: listing $(remote_path)"
    if ! rclone_src lsf "$(remote_path)" --recursive --files-only --fast-list \
        --format tsp --separator $'\t' --time-format RFC3339 >"$tmp"; then
        rm -f "$tmp"
        log "ERROR: rclone could not list the account"
        return 1
    fi
    mv "$tmp" "$LISTING" || return 1

    # The copy, listed by rclone too, with the same flags: the names come out as in the listing of the account, and
    # a filter leaves out the same files.
    copy_list="$(mktemp "$STATE_DIR/copy.tmp.XXXXXX")" || return 1
    if ! rclone_src lsf "$MIRROR" --recursive --files-only --format p >"$copy_list"; then
        rm -f "$copy_list"
        log "ERROR: rclone could not list the copy"
        return 1
    fi
    files="$(gawk 'END { print NR }' "$copy_list")" || { rm -f "$copy_list"; return 1; }
    # ARGIND, not NR == FNR: an empty listing (an emptied account) would make the copy's lines count as the listing.
    gone="$(gawk 'ARGIND == 1 { sub(/^[^\t]*\t[^\t]*\t/, ""); have[$0] = 1; next } !($0 in have) { n++ } END { print n + 0 }' \
        "$LISTING" "$copy_list")" || { rm -f "$copy_list"; return 1; }
    rm -f "$copy_list"
    allowed=$(( files * S_MAX_DELETE / 100 ))
    (( gone <= allowed )) || blocked="$gone"
    write_prom "$(source_prom guard)" <<EOF || log "ERROR: could not write the metrics to $METRICS_DIR."
# HELP cloud_drive_backup_guard_blocked_files Files gone from the account that the last run did not delete from the copy, being more than MAX_DELETE percent of it; 0 = none held back.
# TYPE cloud_drive_backup_guard_blocked_files gauge
cloud_drive_backup_guard_blocked_files{source="$SRC"} $blocked
EOF

    # Nothing new is copied either: after a sign-in to a wrong account it would be all of that account, after
    # malware the files it wrote.
    if (( blocked > 0 )); then
        log "ERROR: $gone of the $files files in the copy are gone from the account: more than MAX_DELETE ${S_MAX_DELETE}% ($allowed files)."
        log "ERROR: the copy stays as it is, nothing deleted, nothing copied. If the deletions are expected, run once with $(upper "$SRC")_MAX_DELETE=100: docker exec -e $(upper "$SRC")_MAX_DELETE=100 <container> backup.sh run $SRC"
        return 1
    fi

    # The guard counted before the sync; --max-delete holds to it if more files go meanwhile. 100% means no limit.
    (( S_MAX_DELETE == 100 )) || max=(--max-delete "$allowed")
    log "rclone: syncing $(remote_path) to $MIRROR ($gone files gone from the account)"
    if ! rclone_src sync "$(remote_path)" "$MIRROR" --fast-list "${max[@]}" \
        --stats 5m --stats-one-line --stats-log-level NOTICE; then
        log "ERROR: rclone sync failed"
        return 1
    fi
    DELETED="$gone"
    log "rclone: done; the account holds $(listing_files) files, $(listing_bytes) bytes"
}


listing_files() {
    gawk 'END { print NR }' "$LISTING"
}


# listing_bytes : the size of the files in the listing; documents (size -1) count as 0.
listing_bytes() {
    gawk -F'\t' '$2 > 0 { s += $2 } END { printf "%.0f\n", s }' "$LISTING"
}


# snapshot <retention: yes|no> : under the repository lock, snapshot, forget, the daily prune, the weekly check and
# the off-host copy.
snapshot() {
    exec 8>"$REPO_LOCK"
    if ! flock -n 8; then
        log "restic: waiting for another run to finish with the repository"
        flock 8
    fi

    # Always the same paths, even when empty: restic picks the parent snapshot by the exact path set.
    mkdir -p "$MIRROR" "$STATE_DIR"
    log "restic: snapshot of $MIRROR $STATE_DIR"
    restic backup --quiet --host "$SNAPSHOT_HOST" --tag "$SRC" "$MIRROR" "$STATE_DIR"

    if [[ "$1" == yes ]]; then
        log "restic: retention (hourly $S_KEEP_HOURLY, daily $S_KEEP_DAILY, weekly $S_KEEP_WEEKLY, monthly $S_KEEP_MONTHLY)"
        restic forget --quiet --host "$SNAPSHOT_HOST" --tag "$SRC" --group-by host,tags \
            --keep-hourly "$S_KEEP_HOURLY" --keep-daily "$S_KEEP_DAILY" --keep-weekly "$S_KEEP_WEEKLY" \
            --keep-monthly "$S_KEEP_MONTHLY"
        # Once a day, by the first good run of any source: prune rewrites packs and takes the whole repository.
        if [[ "$(cat "$PRUNE_STAMP" 2>/dev/null)" != "$(date +%F)" ]]; then
            log "restic: prune (once a day)"
            restic prune --quiet
            date +%F >"$PRUNE_STAMP"
        fi
        if [[ -n "$CHECK_WEEKDAY" && "$(date +%u)" == "$CHECK_WEEKDAY" \
            && "$(cat "$CHECK_STAMP" 2>/dev/null)" != "$(date +%F)" ]]; then
            log "restic: weekly check, reading $CHECK_READ_SUBSET of the data"
            restic check --read-data-subset="$CHECK_READ_SUBSET"
            date +%F >"$CHECK_STAMP"
        fi
    fi

    if [[ -n "$COPY_TARGET" ]]; then
        copy_offsite || copy_failed
    fi
    exec 8>&-
}


# copy_offsite : sends the repository files COPY_TARGET does not have yet. Repository files never change once
# written, so adding new ones keeps the copy a valid repository (a superset: pruned packs stay there). Runs under
# the repository lock, so restic writes nothing meanwhile. rsync sorts the list: data/ and index/ go before
# snapshots/, so an interrupted copy never holds a snapshot whose data is missing. A failure does not fail the run.
copy_offsite() {
    local started list

    started="$(date +%s)"
    list="$(mktemp)" || return 1
    (cd "$RESTIC_REPOSITORY" && find . -type f ! -path './locks/*' | sed 's,^\./,,') >"$list" || { rm -f "$list"; return 1; }
    log "copy: restic repository to $COPY_TARGET ($(wc -l <"$list") files, those already there are skipped)"
    if ! rsync --recursive --times --ignore-existing --chmod=D700,F600 --files-from="$list" \
        -e "ssh -i '$COPY_KEY' -p $COPY_PORT -o BatchMode=yes -o StrictHostKeyChecking=yes -o 'UserKnownHostsFile=$COPY_KNOWN_HOSTS'" \
        "$RESTIC_REPOSITORY/" "$COPY_TARGET"; then
        rm -f "$list"
        return 1
    fi
    rm -f "$list"

    write_prom cloud_drive_backup_copy.prom <<EOF || return 1
# HELP cloud_drive_backup_copy_last_success_timestamp_seconds When the restic repository was last copied off-host.
# TYPE cloud_drive_backup_copy_last_success_timestamp_seconds gauge
cloud_drive_backup_copy_last_success_timestamp_seconds $(date +%s)
# HELP cloud_drive_backup_copy_last_duration_seconds How long the last off-host copy took.
# TYPE cloud_drive_backup_copy_last_duration_seconds gauge
cloud_drive_backup_copy_last_duration_seconds $(( $(date +%s) - started ))
EOF
    log "copy: done"
}


copy_failed() {
    log "ERROR: copy to $COPY_TARGET failed; the next run tries again."
    write_prom cloud_drive_backup_copy_failure.prom <<EOF || true
# HELP cloud_drive_backup_copy_last_failure_timestamp_seconds When the last off-host copy failed.
# TYPE cloud_drive_backup_copy_last_failure_timestamp_seconds gauge
cloud_drive_backup_copy_last_failure_timestamp_seconds $(date +%s)
EOF
}


write_metrics() {
    local duration="$1" files bytes copy_files copy_bytes repo_bytes

    # The snapshot is already taken: a failed count must not turn the run into a failure.
    files="$(listing_files)" || files=NaN
    bytes="$(listing_bytes)" || bytes=NaN
    copy_files="$(find "$MIRROR" -type f | wc -l)" || copy_files=NaN
    copy_bytes="$(du -sb "$MIRROR" | cut -f1)" || copy_bytes=NaN
    repo_bytes="$(du -sb "$RESTIC_REPOSITORY" | cut -f1)" || repo_bytes=NaN

    write_prom "$(source_prom success)" <<EOF || log "ERROR: could not write the metrics to $METRICS_DIR."
# HELP cloud_drive_backup_last_success_timestamp_seconds When the last backup run of a source (rclone + restic snapshot) succeeded.
# TYPE cloud_drive_backup_last_success_timestamp_seconds gauge
cloud_drive_backup_last_success_timestamp_seconds{source="$SRC"} $(date +%s)
# HELP cloud_drive_backup_last_duration_seconds How long the last good run of a source took.
# TYPE cloud_drive_backup_last_duration_seconds gauge
cloud_drive_backup_last_duration_seconds{source="$SRC"} ${duration}
# HELP cloud_drive_backup_account_files Files in the account (the source's part of it) at the last good run.
# TYPE cloud_drive_backup_account_files gauge
cloud_drive_backup_account_files{source="$SRC"} ${files}
# HELP cloud_drive_backup_account_bytes Size of those files; documents exported on download (no size) count as 0.
# TYPE cloud_drive_backup_account_bytes gauge
cloud_drive_backup_account_bytes{source="$SRC"} ${bytes}
# HELP cloud_drive_backup_mirror_files Files in the local copy.
# TYPE cloud_drive_backup_mirror_files gauge
cloud_drive_backup_mirror_files{source="$SRC"} ${copy_files}
# HELP cloud_drive_backup_mirror_bytes Size of the local copy.
# TYPE cloud_drive_backup_mirror_bytes gauge
cloud_drive_backup_mirror_bytes{source="$SRC"} ${copy_bytes}
# HELP cloud_drive_backup_deleted_files Files gone from the account that the last good run deleted from the copy.
# TYPE cloud_drive_backup_deleted_files gauge
cloud_drive_backup_deleted_files{source="$SRC"} ${DELETED}
EOF
    write_prom cloud_drive_backup_repository.prom <<EOF || log "ERROR: could not write the metrics to $METRICS_DIR."
# HELP cloud_drive_backup_repository_bytes Size of the restic repository.
# TYPE cloud_drive_backup_repository_bytes gauge
cloud_drive_backup_repository_bytes ${repo_bytes}
EOF
    log "done: account $files files $bytes bytes, copy $copy_files files $copy_bytes bytes ($DELETED deleted), repository $repo_bytes bytes, ${duration}s"
}


# run_one <source> : one run of one source.
run_one() {
    local started synced=yes

    load_source "$1"
    check_data
    exec 9>"$SOURCE_LOCK"
    if [[ "$WAIT_FOR_LOCK" == yes ]]; then
        flock 9
    elif ! flock -n 9; then
        # Not a failure: a long first sync may still be running at the scheduled time.
        log "another run of $1 holds $SOURCE_LOCK, skipping this one."
        exit 0
    fi

    trap on_exit EXIT
    # A signal would run the EXIT trap with $? = 0: no error, no failure metric.
    trap 'exit 143' TERM
    trap 'exit 130' INT
    started="$(date +%s)"
    check_source "$1"
    check_repository
    load_token
    write_conf
    sync_source || synced=no
    if [[ "$synced" != yes ]]; then
        log "ERROR: taking the snapshot of what is there, without retention."
    fi
    snapshot "$synced"
    [[ "$synced" == yes ]] || exit 1
    write_metrics "$(( $(date +%s) - started ))"
}


# init : creates the restic repository, once.
init() {
    check_data
    if [[ -f "$RESTIC_REPOSITORY/config" ]]; then
        log "restic: repository in $RESTIC_REPOSITORY already exists, nothing to do"
        return 0
    fi
    restic init
}


# auth_url <state> : stdout the link that signs in to the source's service and asks for read-only access.
auth_url() {
    CID="$(<"$S_CLIENT_ID_FILE")" STATE="$1" T="$S_TYPE" \
        GA="$GOOGLE_AUTH_URL" GR="$GOOGLE_REDIRECT" GS="$GOOGLE_SCOPE" DA="$DROPBOX_AUTH_URL" \
        YA="$YANDEX_AUTH_URL" YR="$YANDEX_REDIRECT" jq -rn '
        def query: to_entries | map("\(.key)=\(.value | @uri)") | join("&");
        if env.T == "drive" then
            # prompt=consent: Google gives a refresh token only on a consent, and the account may have consented before.
            env.GA + "?" + ({client_id: env.CID, redirect_uri: env.GR, response_type: "code", scope: env.GS,
                             access_type: "offline", prompt: "consent", state: env.STATE} | query)
        elif env.T == "dropbox" then
            # offline: a refresh token; the access token alone lasts 4 hours.
            env.DA + "?" + ({client_id: env.CID, response_type: "code", token_access_type: "offline"} | query)
        else
            env.YA + "?" + ({response_type: "code", client_id: env.CID, redirect_uri: env.YR, force_confirm: "yes"} | query)
        end'
}


# query_param <name> : stdin a URL or a query string; stdout the decoded value of that parameter, empty if none.
query_param() {
    LC_ALL=C N="$1" gawk '
        function decode(s,    out) {
            gsub(/\+/, " ", s)
            out = ""
            while (match(s, /%[0-9A-Fa-f][0-9A-Fa-f]/)) {
                out = out substr(s, 1, RSTART - 1) sprintf("%c", strtonum("0x" substr(s, RSTART + 1, 2)))
                s = substr(s, RSTART + 3)
            }
            return out s
        }
        {
            q = $0
            sub(/^[^?]*\?/, "", q)
            sub(/#.*/, "", q)
            n = split(q, kv, "&")
            for (i = 1; i <= n; i++) {
                k = kv[i]; v = ""
                if ((p = index(k, "=")) > 0) {
                    v = substr(k, p + 1); k = substr(k, 1, p - 1)
                }
                if (k == ENVIRON["N"]) {
                    print decode(v)
                    exit
                }
            }
        }'
}


# exchange_code <code> : stdout the token, as rclone keeps it, that the service gives for the code. Errors go to
# stderr: stdout is the token.
exchange_code() {
    local url redirect="" resp token err scope

    case "$S_TYPE" in
        drive) url="$GOOGLE_TOKEN_URL"; redirect="$GOOGLE_REDIRECT" ;;
        dropbox) url="$DROPBOX_TOKEN_URL" ;;
        yandex) url="$YANDEX_TOKEN_URL" ;;
    esac
    # The form goes to curl on stdin: the client secret and the code stay off the command line.
    resp="$(CODE="$1" CID="$(<"$S_CLIENT_ID_FILE")" CSEC="$(<"$S_CLIENT_SECRET_FILE")" REDIRECT="$redirect" jq -rn '
        [["grant_type", "authorization_code"], ["code", env.CODE], ["client_id", env.CID], ["client_secret", env.CSEC]]
        + (if env.REDIRECT == "" then [] else [["redirect_uri", env.REDIRECT]] end)
        | map("\(.[0])=\(.[1] | @uri)") | join("&")' \
        | curl -sS --globoff --max-time 60 --data-binary @- "$url")" || { log "ERROR: could not reach $url" >&2; return 1; }
    # Yandex: rclone's backend turns a "bearer" token into an "OAuth" one on first use and saves it; given as such,
    # the first run doesn't look like a renewal.
    token="$(printf '%s' "$resp" | T="$S_TYPE" jq -c 'select(type == "object" and (.access_token | type == "string") and .access_token != "")
        | {access_token, token_type: (if env.T == "yandex" then "OAuth" else (.token_type // "Bearer") end), refresh_token,
           expiry: (now + (.expires_in // 3600) | floor | todate)}
        | with_entries(select(.value != null))' 2>/dev/null)" || token=""
    if ! valid_token "$token"; then
        # The answer itself is not printed: only the error fields, which carry no token.
        err="$(printf '%s' "$resp" | jq -r '[.error, .error_description] | map(select(type == "string")) | join(": ")' 2>/dev/null)" || err=""
        log "ERROR: $S_TYPE gave no token: ${err:-the answer is not a token}" >&2
        return 1
    fi
    if [[ "$(printf '%s' "$token" | jq -r '.refresh_token // empty')" == "" ]]; then
        log "ERROR: $S_TYPE gave no refresh token: the access token alone would stop working within hours." >&2
        return 1
    fi
    # Not a failure, the backup only reads; but a token that can write is worth knowing about.
    scope="$(printf '%s' "$resp" | jq -r '.scope // empty' 2>/dev/null)" || scope=""
    if [[ " $scope " == *" https://www.googleapis.com/auth/drive "* || "$scope" == *.write* ]]; then
        log "WARNING: the token can also write ($scope). The backup only reads; a read-only app is safer, see the README." >&2
    fi
    printf '%s\n' "$token"
}


# whoami_account : stdout the account the token of the source is of (e-mail or login), as the service says.
whoami_account() {
    local at hdr resp filter

    at="$(printf '%s' "$S_TOKEN" | jq -r '.access_token')" || return 1
    # Next to the config, so that cleanup_conf removes it even when a Ctrl-C ends this function midway.
    hdr="$S_CONF.header"
    : >"$hdr" || return 1
    # The header comes from a file: the token stays off the command line. A failed curl leaves resp empty, and jq
    # then fails.
    case "$S_TYPE" in
        drive)
            printf 'Authorization: Bearer %s\n' "$at" >"$hdr"
            resp="$(curl -sS --globoff --max-time 30 -H @"$hdr" "$GOOGLE_ABOUT_URL")"
            filter='.user.emailAddress'
            ;;
        dropbox)
            printf 'Authorization: Bearer %s\n' "$at" >"$hdr"
            resp="$(curl -sS --globoff --max-time 30 -X POST -H @"$hdr" "$DROPBOX_ACCOUNT_URL")"
            filter='.email'
            ;;
        yandex)
            printf 'Authorization: OAuth %s\n' "$at" >"$hdr"
            resp="$(curl -sS --globoff --max-time 30 -H @"$hdr" "$YANDEX_DISK_URL")"
            filter='.user.login'
            ;;
    esac
    rm -f "$hdr"
    printf '%s' "$resp" | jq -er "$filter | strings" 2>/dev/null
}


# auth <source> : signs in to the account of the source and keeps its token. Prints a link to open in any browser,
# reads what the service shows after the sign-in (a code, or the address the browser ended up at), or a token from
# `rclone authorize`, from stdin; then says which account it is and what the source sees there.
auth() {
    local state url input code got token who list

    load_source "$1"
    check_data
    check_source "$1"
    trap finish_conf EXIT
    # As in run_one: bash takes a signal after the running rclone ends, and only then removes its config.
    trap 'exit 143' TERM
    trap 'exit 130' INT
    mkdir -p "$TOKEN_ROOT"
    state="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    if [[ -s "$S_CLIENT_ID_FILE" ]]; then
        url="$(auth_url "$state")" || fail "could not make the sign-in link."
        echo "Open this link in a browser, sign in to the account to back up and allow read-only access:"
        echo
        echo "  $url"
        echo
        case "$S_TYPE" in
            drive) echo "Google then sends the browser to http://127.0.0.1:53682/, which does not open: that is expected. Copy the whole address from the address bar." ;;
            dropbox) echo "Dropbox then shows a code: copy it." ;;
            yandex) echo "Yandex then shows a code: copy it." ;;
        esac
    else
        echo "There is no OAuth client of your own for $S_TYPE ($S_CLIENT_ID_FILE, $S_CLIENT_SECRET_FILE), so only a token from \`rclone authorize $S_TYPE\` can be used."
    fi
    echo "A token from \`rclone authorize\` (its JSON) is taken as well."
    printf 'Paste it here and press Enter (it is not shown): '
    # read fails on input without a line end, having read it all the same.
    IFS= read -r -s input || [[ -n "$input" ]] || fail "nothing pasted."
    echo
    # Spaces and line ends around what was pasted.
    input="${input#"${input%%[![:space:]]*}"}"
    input="${input%"${input##*[![:space:]]}"}"
    [[ -n "$input" ]] || fail "nothing pasted."

    if [[ "$input" == \{* ]]; then
        token="$(printf '%s' "$input" | jq -c . 2>/dev/null)" || token=""
        valid_token "$token" || fail "that is not a token: paste the JSON that rclone authorize printed, on one line."
        [[ "$(printf '%s' "$token" | jq -r '.refresh_token // empty')" != "" ]] \
            || fail "that token has no refresh token: it would stop working within hours."
    else
        [[ -s "$S_CLIENT_ID_FILE" ]] || fail "a code needs the OAuth client: $S_CLIENT_ID_FILE and $S_CLIENT_SECRET_FILE."
        code="$input"
        if [[ "$input" == *code=* ]]; then
            code="$(printf '%s' "$input" | query_param code)"
            got="$(printf '%s' "$input" | query_param state)"
            [[ -z "$got" || "$got" == "$state" ]] || fail "that address is from another sign-in: use the link above."
        fi
        [[ -n "$code" ]] || fail "no code in what was pasted."
        token="$(exchange_code "$code")" || exit 1
    fi
    ( exec 7>"$TOKEN_LOCK" && flock 7 && store_token "$token" ) || fail "could not write $TOKEN_FILE."
    S_TOKEN="$token"
    log "token: saved to $TOKEN_FILE"

    if who="$(whoami_account)"; then
        log "account: $who"
    else
        log "WARNING: could not ask $S_TYPE which account this is."
    fi
    write_conf
    list="$(mktemp)"
    rclone_src lsf "$(remote_path)" --max-depth 1 >"$list" \
        || { rm -f "$list"; fail "rclone could not list $(remote_path) with the new token."; }
    log "rclone: $(remote_path) holds $(wc -l <"$list") files and folders at the top"
    rm -f "$list"
}


# drives <source> : lists the shared drives the Google account of the source can see: id <TAB> name.
drives() {
    local out

    load_source "$1"
    check_data
    check_source "$1"
    [[ "$S_TYPE" == drive ]] || fail "drives lists Google shared drives: $1 is TYPE=$S_TYPE."
    trap finish_conf EXIT
    trap 'exit 143' TERM
    trap 'exit 130' INT
    load_token
    write_conf
    out="$(mktemp)"
    rclone_src backend drives src: >"$out" || { rm -f "$out"; fail "rclone could not list the shared drives."; }
    jq -r '.[] | "\(.id)\t\(.name)"' "$out" || { rm -f "$out"; fail "rclone gave something that is not a list of drives."; }
    rm -f "$out"
}


# is_source <name> : whether the name is listed in SOURCES.
is_source() {
    local s

    for s in "${SOURCE_LIST[@]}"; do
        [[ "$s" == "$1" ]] && return 0
    done
    return 1
}


main() {
    local cmd="${1:-run}" s rc=0

    case "$cmd" in
        init|check|run|auth|drives) ;;
        *) log "ERROR: unknown command '$cmd' (run, init, check, auth, drives)"; exit 2 ;;
    esac
    (( $# == 0 )) || shift
    check_global_settings

    case "$cmd" in
        init) init; return ;;
        check)
            for s in "${SOURCE_LIST[@]}"; do
                (
                    check_source "$s"
                    [[ -s "$TOKEN_FILE" ]] || log "WARNING: $s is not signed in yet: docker exec -it <container> backup.sh auth $s"
                ) || rc=1
            done
            (( rc == 0 )) && log "settings: ${#SOURCE_LIST[@]} sources, all good"
            return "$rc"
            ;;
        auth|drives)
            (( $# == 1 )) || { log "ERROR: $cmd takes one source name"; exit 2; }
            is_source "$1" || { log "ERROR: '$1' is not in SOURCES (${SOURCE_LIST[*]})"; exit 2; }
            CMD="$cmd"
            "$cmd" "$1"
            return
            ;;
    esac

    for s in "$@"; do
        is_source "$s" || { log "ERROR: '$s' is not in SOURCES (${SOURCE_LIST[*]})"; exit 2; }
    done
    if (( $# == 1 )); then
        run_one "$1"
        return
    fi
    # Several sources: each in its own process, so that a failure of one (set -e) does not skip the others.
    (( $# > 0 )) || set -- "${SOURCE_LIST[@]}"
    for s in "$@"; do
        "$0" run "$s" || rc=1
    done
    return "$rc"
}


main "$@"
