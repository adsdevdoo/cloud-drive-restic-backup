#!/bin/sh
# Tests: builds the image and runs backup.sh against a stub rclone and a stub curl. The rclone stub turns the remote
# "src:" of the run's config into a local directory and hands everything else to the real rclone, so the real flags,
# sync and --max-delete are exercised. The curl stub plays the token and "who am I" endpoints of Google, Dropbox and
# Yandex. No network, no account; the first `docker build` needs the internet for the Alpine packages. Needs Docker.
# Usage: sh tests/test.sh
# Each scenario prints its result; the script ends with "FAILED: N" (0 = all good) and exits non-zero on failures.
# The data directory (restic repository, copies, tokens, state) carries over from one scenario to the next.
set -u
cd "$(dirname "$0")/.." || exit 1
IMG=cloud-drive-restic-backup:test
docker build -q -t "$IMG" . >/dev/null || { echo "build failed"; exit 1; }

d=$(mktemp -d)
cleanup() {
  docker rm -f cdrb-sched-test >/dev/null 2>&1
  docker run --rm -v "$d:/d" alpine:3.24 rm -rf /d/data /d/metrics /d/secrets /d/secrets-none /d/secrets-half /d/bin /d/fake /d/env
  rmdir "$d" 2>/dev/null
}
trap cleanup EXIT
trap 'exit 130' INT TERM
mkdir -p "$d/data" "$d/secrets" "$d/secrets-none" "$d/secrets-half" "$d/metrics" "$d/bin"
# The accounts, by the refresh token their tokens carry (the curl stub hands them out): alice on Google Drive with a
# shared drive and files shared with her, bob on Dropbox, carol on Yandex Disk.
A=$d/fake/RT-alice-q9w2
mkdir -p "$A/docs" "$A.shared.0ABCteam1" "$A.with-me" "$d/fake/RT-bob-k2m8/Work" "$d/fake/RT-carol-z5x1"
echo a >"$A/a.txt"
echo b >"$A/b.txt"
echo c >"$A/docs/c.txt"
echo d >"$A/docs/d.txt"
echo t >"$A.shared.0ABCteam1/t.txt"
echo m >"$A.with-me/m.txt"
echo w >"$d/fake/RT-bob-k2m8/Work/w.txt"
echo o >"$d/fake/RT-bob-k2m8/other.txt"
echo y >"$d/fake/RT-carol-z5x1/y.txt"
# Client secrets and tokens must never show up in the output: the test looks for the fragments after the last dash.
printf 'CIDdrive-1' >"$d/secrets/drive_client_id"
printf 'CSdrive-8u4j2' >"$d/secrets/drive_client_secret"
printf 'CIDdropbox-2' >"$d/secrets/dropbox_client_id"
printf 'CSdropbox-3n6v1' >"$d/secrets/dropbox_client_secret"
printf 'CIDyandex-3' >"$d/secrets/yandex_client_id"
# A backslash and a quote: rclone escapes them in its log.
printf '%s' 'CSyan\q"z-5t0p' >"$d/secrets/yandex_client_secret"
head -c 32 /dev/urandom | base64 >"$d/secrets/restic_password"
cp "$d/secrets/restic_password" "$d/secrets-none/"
cp "$d/secrets/restic_password" "$d/secrets/drive_client_id" "$d/secrets-half/"
SECRETS_RE='8u4j2|3n6v1|5t0p|x7f3|q9w2|h4c6|k2m8|p1s9|z5x1|r3e7|v6b0|w8n4'
# Settings in an env file: a value with a space would not survive the word splitting of $E. A scenario changes a
# setting in its command: `SOURCES='a b' backup.sh check`.
cat >"$d/env" <<'EOF'
SOURCES=alice team withme bob carol
ALICE_TYPE=drive
TEAM_TYPE=drive
TEAM_ACCOUNT=alice
TEAM_SHARED_DRIVE=0ABCteam1
WITHME_TYPE=drive
WITHME_ACCOUNT=alice
WITHME_SHARED_WITH_ME=yes
BOB_TYPE=dropbox
BOB_ROOT=/Work/
CAROL_TYPE=yandex
CHECK_WEEKDAY=
EOF
E="--env-file $d/env"
# The stubs go ahead of the real rclone and curl in PATH. SEC: the secrets directory of the next scenarios.
SEC=$d/secrets
V="-v $d/data:/data -v $d/metrics:/metrics -v $d/fake:/fake:ro -v $d/bin/rclone:/usr/local/bin/rclone:ro -v $d/bin/curl:/usr/local/bin/curl:ro"
FAILED=0
ALL=""

# The rclone stub. It reads the config of the run: the account directory comes from the refresh token, a shared drive
# or "Shared with me" add to it. It prints what it saw on stderr; with -vv it also prints the client secret and the
# token, as rclone's debug log could, in the three forms the filter masks. It refuses (FORBIDDEN) anything but lsf,
# sync and copy into /data/mirror, and backend drives. The scenario in /data/scenario: ok; refresh (rclone renews the
# token); retype (rclone rewrites the token without renewing it); reauth:<account> (`auth` meanwhile, and rclone
# renews); refused (the service refuses the token); unauthorized (Yandex Disk answers 401); badclient (it refuses the
# client); netfail (the token can't be renewed for a network error); slow (4 seconds before each call to the
# account, for a signal meanwhile); <command>fail:<type>.
cat >"$d/bin/rclone" <<'EOF'
#!/bin/bash
s=$(cat /data/scenario 2>/dev/null)
[ "$1" = --config ] || { echo "FORBIDDEN rclone without --config first" >&2; exit 9; }
# RCLONE_* from the environment would bypass the config or the log filter (RCLONE_LOG_FILE).
env | grep -q '^RCLONE_' && { echo "FORBIDDEN rclone got RCLONE_* from the environment" >&2; exit 9; }
conf=$2; shift 2
[ "$1" = --log-format ] || { echo "FORBIDDEN rclone without --log-format" >&2; exit 9; }
val() { sed -n "s/^$1 = //p" "$conf"; }
type=$(val type); token=$(val token); td=$(val team_drive); swm=$(val shared_with_me); csec=$(val client_secret)
cmd=$3
case $cmd in
  lsf) case $4 in src:*|/data/mirror/*) ;; *) echo "FORBIDDEN lsf $4" >&2; exit 9;; esac;;
  sync|copy) case "$4|$5" in "src:"*"|/data/mirror/"*) ;; *) echo "FORBIDDEN $cmd $4 $5" >&2; exit 9;; esac;;
  backend) [ "$4 $5" = "drives src:" ] || { echo "FORBIDDEN backend $4 $5" >&2; exit 9; };;
  *) echo "FORBIDDEN rclone $cmd" >&2; exit 9;;
esac
client=none
[ -n "$csec" ] && { [ "$csec" = "$(cat "/run/secrets/${type}_client_secret")" ] && client=ok || client=bad; }
echo "seen $cmd $4 type=$type scope=$(val scope) shortcuts=$(val skip_shortcuts) team_drive=$td with_me=$swm client=$client expiry=$(printf '%s' "$token" | jq -r .expiry)" >&2
for a in "$@"; do
  if [ "$a" = -vv ]; then
    q=$(printf '%s' "$csec" | sed 's/[\\"]/\\&/g'); qq=$(printf '%s' "$q" | sed 's/[\\"]/\\&/g')
    printf 'DEBUG : plain client_secret=%s token=%s\n' "$csec" "$token" >&2
    printf 'DEBUG : quoted client_secret="%s"\n' "$q" >&2
    printf 'DEBUG : json client_secret=\\"%s\\"\n' "$qq" >&2
  fi
done
if [ "${4%%:*}" = src ] || [ "$cmd" = backend ]; then
  case $s in
    refresh) sed -i "s|^token = .*|token = $(printf '%s' "$token" | jq -c '.access_token = "AT2-r3e7" | .expiry = (now + 3600 | floor | todate)')|" "$conf";;
    retype) sed -i "s|^token = .*|token = $(printf '%s' "$token" | jq -c '.token_type = "Retyped"')|" "$conf";;
    unauthorized) echo "ERROR : : error listing: [401 - UnauthorizedError] Не авторизован." >&2; exit 1;;
    slow) sleep 4;;
    reauth:*)
      printf '%s\n' "$token" | jq -c '.access_token = "AT-reauth-w8n4"' >"/data/tokens/${s#reauth:}.json"
      sed -i "s|^token = .*|token = $(printf '%s' "$token" | jq -c '.access_token = "AT2-v6b0" | .expiry = (now + 3600 | floor | todate)')|" "$conf";;
    refused) echo "ERROR : Failed to create file system for \"src:\": couldn't fetch token: invalid_grant: maybe token expired?" >&2; exit 1;;
    badclient) echo "ERROR : Failed to create file system for \"src:\": couldn't fetch token: oauth2: \"invalid_client\" \"The OAuth client was not found.\"" >&2; exit 1;;
    netfail) echo "ERROR : Failed to create file system for \"src:\": couldn't fetch token: Post \"https://oauth2.googleapis.com/token\": dial tcp: lookup oauth2.googleapis.com: no such host" >&2; exit 1;;
    "${cmd}fail:$type") echo "ERROR : $cmd failed" >&2; exit 1;;
  esac
fi
if [ "$cmd" = backend ]; then
  echo '[{"id":"0ABCteam1","kind":"drive#drive","name":"Team One"}]'
  exit 0
fi
root=/fake/$(printf '%s' "$token" | jq -r .refresh_token)
[ -n "$td" ] && root=$root.shared.$td
[ "$swm" = true ] && root=$root.with-me
args=()
for a in "$@"; do
  case $a in src:*) a=$root/${a#src:};; esac
  args+=("$a")
done
exec /usr/bin/rclone --config /dev/null "${args[@]}"
EOF
chmod +x "$d/bin/rclone"

# The curl stub: the token endpoints (they check the form: grant, client, secret, redirect) and the "who am I"
# endpoints (they check the token in the header file). A code good-<account> gives the token of that account,
# write-<account> the same with a scope that can write, noref-<account> one without a refresh token; any other code is
# refused. It refuses (FORBIDDEN) any other address.
cat >"$d/bin/curl" <<'EOF'
#!/bin/bash
url=""; hdr=""; body=""
while [ $# -gt 0 ]; do
  case $1 in
    -H) hdr=${2#@}; shift;;
    --data-binary) [ "$2" = @- ] && body=$(cat); shift;;
    --max-time|-X) shift;;
    -*) ;;
    *) url=$1;;
  esac
  shift
done
who() {
  if grep -q "^Authorization: $1 AT-" "$hdr"; then echo "$2"; else echo '{"error":"unauthorized"}'; fi
}
case $url in
  https://oauth2.googleapis.com/token) type=drive;;
  https://api.dropboxapi.com/oauth2/token) type=dropbox;;
  https://oauth.yandex.ru/token) type=yandex;;
  "https://www.googleapis.com/drive/v3/about?fields=user(emailAddress)") who Bearer '{"user":{"emailAddress":"alice@example.com"}}'; exit 0;;
  https://api.dropboxapi.com/2/users/get_current_account) who Bearer '{"email":"bob@example.com"}'; exit 0;;
  https://cloud-api.yandex.net/v1/disk/) who OAuth '{"user":{"login":"carol"}}'; exit 0;;
  *) echo "FORBIDDEN curl $url" >&2; exit 9;;
esac
param() { printf '%s' "$body" | tr '&' '\n' | sed -n "s/^$1=//p"; }
secret=$(jq -rn --rawfile s "/run/secrets/${type}_client_secret" '$s | @uri')
redirect=""
[ $type = drive ] && redirect='http%3A%2F%2F127.0.0.1%3A53682%2F'
if [ "$(param grant_type)" != authorization_code ] || [ "$(param client_id)" != "$(cat "/run/secrets/${type}_client_id")" ] \
  || [ "$(param client_secret)" != "$secret" ] || [ "$(param redirect_uri)" != "$redirect" ]; then
  echo '{"error":"invalid_request","error_description":"bad form"}'
  exit 0
fi
code=$(param code)
echo "curl: token for code $code" >&2
case ${code#*-} in
  alice) at=AT-alice-x7f3 rt=RT-alice-q9w2;;
  bob) at=AT-bob-h4c6 rt=RT-bob-k2m8;;
  carol) at=AT-carol-p1s9 rt=RT-carol-z5x1;;
  *) code=bad;;
esac
case $type in
  drive) read_scope=https://www.googleapis.com/auth/drive.readonly write_scope=https://www.googleapis.com/auth/drive;;
  dropbox) read_scope='account_info.read files.content.read files.metadata.read' write_scope="$read_scope files.content.write";;
  yandex) read_scope="" write_scope="";;
esac
case ${code%%-*} in
  good) jq -cn --arg at $at --arg rt $rt --arg s "$read_scope" '{access_token: $at, token_type: "bearer", expires_in: 3600, refresh_token: $rt, scope: $s}';;
  write) jq -cn --arg at $at --arg rt $rt --arg s "$write_scope" '{access_token: $at, token_type: "bearer", expires_in: 3600, refresh_token: $rt, scope: $s}';;
  noref) jq -cn --arg at $at '{access_token: $at, token_type: "bearer", expires_in: 14400}';;
  *) echo '{"error":"invalid_grant","error_description":"Bad code"}';;
esac
EOF
chmod +x "$d/bin/curl"

# check <name> <expected rc> <regexes, ";;"-separated: all must match, !re must not> <scenario> [command]
check() {
  echo "$4" >"$d/data/scenario"
  out=$(docker run --rm --network none $E $V -v "$SEC:/run/secrets:ro" "$IMG" sh -c "( ${5:-backup.sh} ); echo rc=\$?" 2>&1)
  ALL="$ALL
$out"
  rc=$(echo "$out" | sed -n 's/^rc=//p')
  ok=yes
  [ "$rc" = "$2" ] || ok=no
  rest="$3;;"
  while [ -n "$rest" ]; do
    re="${rest%%;;*}"; rest="${rest#*;;}"
    case $re in
      "") ;;
      !*) echo "$out" | grep -qE -- "${re#!}" && ok=no;;
      *) echo "$out" | grep -qE -- "$re" || ok=no;;
    esac
  done
  if [ "$ok" = yes ]; then
    echo "ok   $1"
  else
    echo "FAIL $1 (rc=$rc, expected $2, wanted /$3/)"; echo "$out" | tail -8
    FAILED=$((FAILED + 1))
  fi
}

# Without the data volume: no run, no repository, no token in the container layer.
for c in "run alice" init "auth alice"; do
  out=$(docker run --rm --network none $E -v "$d/secrets:/run/secrets:ro" "$IMG" sh -c "backup.sh $c </dev/null; echo rc=\$?" 2>&1)
  if echo "$out" | grep -q '/data is not mounted' && echo "$out" | grep -q '^rc=1$'; then
    echo "ok   no data volume: $c refused"
  else
    echo "FAIL no data volume: $c refused"; echo "$out" | tail -3; FAILED=$((FAILED + 1))
  fi
done

FAIL_PROM="r=\$?; cat /metrics/cloud_drive_backup_source.alice.failure.prom; exit \$r"
check "no repository: a run fails"            1 'no restic repository;;!rclone: listing' ok "backup.sh run alice; $FAIL_PROM"
check "and the failure metric is written"     1 'cloud_drive_backup_last_failure_timestamp_seconds\{source="alice"\} [0-9]+' ok "backup.sh run alice; $FAIL_PROM"
check "init"                                  0 '' ok "backup.sh init"
check "init again does nothing"               0 'already exists' ok "backup.sh init"
check "check: good, not signed in is a warning" 0 'WARNING: alice is not signed in yet;;5 sources, all good' ok "backup.sh check"
check "not signed in: a run fails"            1 'account alice is not signed in yet: .*backup.sh auth alice;;backup failed' ok "backup.sh run alice"

# Sign-in. The link carries the client and the read-only scope; what comes back is pasted on stdin.
check "auth, Google: link, account, listing"  0 'accounts.google.com/o/oauth2/v2/auth\?client_id=CIDdrive-1&;;scope=https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fdrive.readonly;;access_type=offline;;prompt=consent;;state=[0-9a-f]{32};;token: saved;;account: alice@example.com;;src: holds 3 files and folders at the top' ok \
  "printf 'http://127.0.0.1:53682/?code=good%%2Dalice&scope=x\n' | backup.sh auth alice"
check "the token is kept as rclone keeps it"  0 '^access_token,expiry,refresh_token,token_type$;;^700 /data/tokens$;;^600 /data/tokens/alice.json$;;!\.conf' ok \
  "jq -r 'keys | join(\",\")' /data/tokens/alice.json; stat -c '%a %n' /data/tokens /data/tokens/alice.json; ls -A /data/tokens"
check "auth: an address from another sign-in" 1 'from another sign-in;;!token: saved' ok "printf 'http://127.0.0.1:53682/?state=0123&code=good-alice\n' | backup.sh auth alice"
check "auth: a refused code"                  1 'drive gave no token: invalid_grant: Bad code;;!token: saved' ok "printf 'nope\n' | backup.sh auth alice"
check "auth, Dropbox: offline, the app's scopes" 0 'www.dropbox.com/oauth2/authorize\?client_id=CIDdropbox-2&response_type=code&token_access_type=offline;;!oauth2/authorize.*scope;;account: bob@example.com;;src:/Work holds 1 files' ok \
  "printf 'good-bob' | backup.sh auth bob"
check "auth, Yandex: verification page"       0 'oauth.yandex.ru/authorize\?response_type=code&client_id=CIDyandex-3&redirect_uri=https%3A%2F%2Foauth.yandex.ru%2Fverification_code;;account: carol;;src: holds 1 files' ok \
  "printf '  good-carol  \n' | backup.sh auth carol"
check "a Yandex token is kept as OAuth"       0 '^OAuth$' ok "jq -r .token_type /data/tokens/carol.json"
check "auth: a token that can write is flagged" 0 'WARNING: the token can also write;;token: saved' ok "printf 'write-bob\n' | backup.sh auth bob"
check "auth: no refresh token, nothing saved" 1 'gave no refresh token;;!token: saved' ok "printf 'noref-carol\n' | backup.sh auth carol"
# A token for two years more, as rclone authorize prints it (Yandex tokens last a year; this one must not be renewed).
check "auth: a token from rclone authorize"   0 'token: saved;;account: carol' ok \
  "jq -cn --arg e \"\$(date -u -d '+2 years' +%Y-%m-%dT%H:%M:%SZ)\" '{access_token: \"AT-carol-p1s9\", token_type: \"bearer\", refresh_token: \"RT-carol-z5x1\", expiry: \$e}' | backup.sh auth carol"
check "auth: not a token"                     1 'that is not a token' ok "printf '{\"a\":1}\n' | backup.sh auth carol"
check "auth: a token without a refresh token" 1 'has no refresh token;;!token: saved' ok "printf '{\"access_token\":\"x\"}\n' | backup.sh auth carol"
check "auth: nothing pasted"                  1 'nothing pasted' ok "backup.sh auth carol </dev/null"
SEC=$d/secrets-none
check "auth without a client: a code is refused" 1 'only a token from `rclone authorize drive`;;a code needs the OAuth client' ok "printf 'good-alice\n' | backup.sh auth alice"
SEC=$d/secrets-half
check "client: id without secret"             1 'both or neither' ok "backup.sh check"
SEC=$d/secrets

# A Google token lasts an hour: it goes to rclone as expired, to be renewed (the stub only shows it).
check "one source"                            0 'seen lsf src: type=drive scope=drive.readonly shortcuts=true team_drive= with_me= client=ok expiry=2000-01-01T00:00:00Z;;done: account 4 files 8 bytes, copy 4 files;;restic: prune;;!\[bob\]' ok \
  "backup.sh run alice"
check "metrics of the source"                 0 'cloud_drive_backup_last_success_timestamp_seconds\{source="alice"\} [0-9]+;;cloud_drive_backup_account_files\{source="alice"\} 4;;cloud_drive_backup_deleted_files\{source="alice"\} 0;;cloud_drive_backup_guard_blocked_files\{source="alice"\} 0;;cloud_drive_backup_repository_bytes [0-9]+' ok \
  "backup.sh run alice >/dev/null; r=\$?; cat /metrics/cloud_drive_backup_source.alice.success.prom /metrics/cloud_drive_backup_source.alice.guard.prom /metrics/cloud_drive_backup_repository.prom; exit \$r"
check "listing of the account kept"           0 '	docs/c.txt$;;	a.txt$' ok "cat /data/state/alice/listing.tsv"
check "the rclone config is gone after the run" 0 '!\.conf;;alice.json' ok "ls -A /data/tokens"
check "tokens are not in the snapshots"       0 '/data/mirror/alice/a.txt;;!/data/tokens' ok "restic ls latest --tag alice"
check "shared drive, account of alice"        0 'seen lsf src: type=drive .*team_drive=0ABCteam1 with_me= client=ok;;done: account 1 files' ok "backup.sh run team"
check "shared with me"                        0 'seen lsf src: type=drive .*team_drive= with_me=true;;done: account 1 files' ok "backup.sh run withme"
check "drives: the shared drives of alice"    0 '^0ABCteam1	Team One$' ok "backup.sh drives team"
check "drives: Google only"                   1 'drives lists Google shared drives' ok "backup.sh drives bob"
check "drives leaves the config of a run alone" 0 '^\.team\.run\.conf$' ok \
  "touch /data/tokens/.team.run.conf; backup.sh drives team >/dev/null 2>&1; ls -A /data/tokens; rm /data/tokens/.team.run.conf"
# Dropbox from / : the root namespace, with a team the team space.
check "Dropbox, a folder of it"               0 'seen lsf src:/Work type=dropbox scope= shortcuts= team_drive= with_me= client=ok;;done: account 1 files' ok "backup.sh run bob"
check "only the folder is copied"             0 '^w.txt$;;!other' ok "ls /data/mirror/bob"
check "Yandex, a token for years goes as it is" 0 'seen lsf src: type=yandex .*expiry=20;;!expiry=2000-01-01;;done: account 1 files' ok "backup.sh run carol"
check "Go's zero time is no expiry"           0 'token: saved;;expiry=0001-01-01T00:00:00Z' ok \
  "printf '%s\n' '{\"access_token\":\"AT-carol-p1s9\",\"token_type\":\"OAuth\",\"refresh_token\":\"RT-carol-z5x1\",\"expiry\":\"0001-01-01T00:00:00Z\"}' | backup.sh auth carol"
# Expiry as rclone writes it: fractions, an offset. Within 275 days: rclone is to renew it.
check "a token expiring within 275 days goes as expired" 0 'token: saved;;seen lsf src: type=yandex .*expiry=2000-01-01T00:00:00Z' ok \
  "jq -cn --arg e \"\$(date -u -d '+100 days' +%Y-%m-%dT%H:%M:%S.123456789+00:00)\" '{access_token: \"AT-carol-p1s9\", token_type: \"OAuth\", refresh_token: \"RT-carol-z5x1\", expiry: \$e}' | backup.sh auth carol"
check "rclone flags: per source over global, on both lists" 0 'done: account 3 files .*copy 4 files .*\(0 deleted\)' ok \
  "RCLONE_FLAGS='--exclude b.txt' ALICE_RCLONE_FLAGS='--exclude a.txt' backup.sh run alice"
check "prune once a day"                      0 'done: ;;!restic: prune' ok "backup.sh run alice"
check "RCLONE_* of the environment don't reach rclone" 0 'done: ;;^no log file$' ok \
  "RCLONE_LOG_FILE=/data/leak.log RCLONE_VERBOSE=2 backup.sh run alice; [ -e /data/leak.log ] || echo 'no log file'"

# Deletions: within MAX_DELETE they reach the copy, beyond it nothing is deleted.
rm "$A/b.txt"
check "a deletion within MAX_DELETE"          0 '1 files gone from the account;;copy 3 files .*\(1 deleted\)' ok "ALICE_MAX_DELETE=50 backup.sh run alice"
check "and an older snapshot has the file"    0 '/data/mirror/alice/b.txt' ok "restic find --tag alice b.txt"
rm "$A/a.txt" "$A/docs/c.txt"
echo n >"$A/new.txt"
check "the guard: too many gone, none deleted" 1 '2 of the 3 files in the copy are gone from the account: more than MAX_DELETE 10% \(0 files\);;the copy stays as it is;;docker exec -e ALICE_MAX_DELETE=100 <container> backup.sh run alice;;without retention;;backup failed' ok \
  "backup.sh run alice"
# Nothing new either: after a sign-in to a wrong account it would be all of that account.
check "the copy kept them, took nothing new"  0 '^a.txt$;;^c.txt$;;!new.txt' ok "ls /data/mirror/alice /data/mirror/alice/docs"
check "the guard metric"                      0 'cloud_drive_backup_guard_blocked_files\{source="alice"\} 2' ok "cat /metrics/cloud_drive_backup_source.alice.guard.prom"
check "MAX_DELETE=100 lets them go"           0 'copy 2 files .*\(2 deleted\)' ok "ALICE_MAX_DELETE=100 backup.sh run alice"
check "the copy is the account again"         0 '^new.txt$;;^d.txt$;;!a.txt;;!c.txt;;guard_blocked_files\{source="alice"\} 0' ok \
  "ls /data/mirror/alice /data/mirror/alice/docs; cat /metrics/cloud_drive_backup_source.alice.guard.prom"
# A download a killed run left behind is not a file gone from the account.
check "a leftover .partial is cleared, not counted" 0 'done: ;;!more than MAX_DELETE;;!partial' ok \
  "touch /data/mirror/alice/zz.0123abcd.partial; backup.sh run alice; ls /data/mirror/alice"
# An emptied account: every file of the copy is gone (the listing is empty).
rm "$d/fake/RT-carol-z5x1/y.txt"
check "the guard: an emptied account"         1 '1 of the 1 files in the copy are gone from the account;;the copy stays as it is' ok "backup.sh run carol"
check "and the copy kept the file"            0 '^y.txt$' ok "ls /data/mirror/carol"
echo y >"$d/fake/RT-carol-z5x1/y.txt"

# Tokens: renewed by rclone, kept; a sign-in during the run wins; a refused token says what to do.
check "a renewed token is saved"              0 'token: renewed by rclone and saved;;done: ' refresh "backup.sh run alice"
check "the file has the renewed token"        0 '^true$' ok "jq -r '.access_token | startswith(\"AT2-\")' /data/tokens/alice.json"
# rclone rewrites a token without renewing it: saved, with the real expiry, not the one made up for rclone.
check "a rewritten token keeps its expiry"    0 'changed by rclone \(not renewed\) and saved;;done: ' retype "backup.sh run alice"
check "the file has it, with the real expiry" 0 '^Retyped$;;^20[0-9]{2}-;;!^2000-01-01' ok "jq -r '.token_type, .expiry' /data/tokens/alice.json"
check "-vv: client secret and tokens masked"  0 'plain client_secret=\*\*\* token=\{"access_token":"\*\*\*".*"refresh_token":"\*\*\*";;done: ' ok "ALICE_RCLONE_FLAGS=-vv backup.sh run alice"
check "-vv: a secret with \\ and \" masked in every form" 0 'plain client_secret=\*\*\*;;quoted client_secret="\*\*\*";;json client_secret=\\"\*\*\*\\";;done: ' ok \
  "CAROL_RCLONE_FLAGS=-vv backup.sh run carol"
check "a sign-in during the run is kept"      0 'changed during the run;;done: ' reauth:alice "backup.sh run alice"
check "the file has the sign-in's token"      0 '^true$' ok "jq -r '.access_token | startswith(\"AT-reauth\")' /data/tokens/alice.json"
check "a refused token: sign in again"        1 'drive refused the token of alice: sign in again with backup.sh auth alice;;could not list the account' refused "backup.sh run alice"
check "Yandex Disk 401: sign in again"        1 'yandex refused the token of carol: sign in again with backup.sh auth carol' unauthorized "backup.sh run carol"
check "a refused client: check the client"    1 'drive refused the OAuth client: check /run/secrets/drive_client_id;;!refused the token' badclient "backup.sh run alice"
check "a network error is not a refusal"      1 'could not list the account;;!refused' netfail "backup.sh run alice"

# Signals. bash takes TERM once the running rclone ends; the way out logs to the log, not to the listing file.
check "TERM during the listing: logged, not in the listing" 0 'backup failed \(exit code 143\);;^rc2=143$;;^in listing: 0$' slow \
  "backup.sh run alice & p=\$!; sleep 2; kill -TERM \$p; wait \$p; echo rc2=\$?; echo \"in listing: \$(cat /data/state/alice/listing.tmp.* | grep -c 'backup failed')\""
check "TERM during auth: its config removed"  0 '^rc2=143$;;!\.alice\.auth\.conf' slow \
  "printf 'good-alice\n' | backup.sh auth alice & p=\$!; sleep 2; kill -TERM \$p; wait \$p; echo rc2=\$?; ls -A /data/tokens"
# A leftover .partial and a failed listing: the snapshot of the run doesn't keep it.
check "a failed listing's snapshot has no leftover .partial" 0 'could not list the account;;^partial in snapshot: 0$' lsffail:drive \
  "touch /data/mirror/alice/zz.0123abcd.partial; backup.sh run alice; echo \"partial in snapshot: \$(restic ls latest --tag alice | grep -c partial)\""

check "all sources, one fails"                1 '\[alice\] .*done: ;;\[team\] .*done: ;;\[carol\] .*ERROR: rclone sync failed;;without retention;;\[carol\] .*backup failed' syncfail:yandex "backup.sh"
check "the failed source has its metric"      0 'source="carol"' ok "cat /metrics/cloud_drive_backup_source.carol.failure.prom"
check "a failed listing fails the run"        1 'could not list the account' lsffail:dropbox "backup.sh run bob"
check "and the old listing stays"             0 'w.txt;;!tmp' ok "cat /data/state/bob/listing.tsv; ls /data/state/bob"
check "weekly check, once a day"              0 'weekly check;;done: ' ok "CHECK_WEEKDAY=\$(date +%u) backup.sh run alice"
check "no second check the same day"          0 '!weekly check;;done: ' ok "CHECK_WEEKDAY=\$(date +%u) backup.sh run alice"
check "source busy: skipped"                  0 'skipping this one;;!rclone: listing' ok "flock /data/.lock-alice sleep 4 & sleep 1; backup.sh run alice"
check "source busy, WAIT_FOR_LOCK=yes: waits" 0 'done: ;;!skipping' ok "flock /data/.lock-alice sleep 3 & sleep 1; WAIT_FOR_LOCK=yes backup.sh run alice"
check "repository busy: waits"                0 'waiting for another run;;done: ' ok "flock /data/.restic.lock sleep 3 & sleep 1; backup.sh run alice"

check "unknown source"                        2 "'nope' is not in SOURCES" ok "backup.sh run nope"
check "unknown command"                       2 "unknown command 'bogus'" ok "backup.sh bogus"
check "auth without a source"                 2 'auth takes one source name' ok "backup.sh auth"
check "auth of an unknown source"             2 "'nope' is not in SOURCES" ok "backup.sh auth nope"
check "bad source name"                       1 "source name 'Alice'" ok "SOURCES=Alice backup.sh check"
check "source listed twice"                   1 'listed twice' ok "SOURCES='alice alice' backup.sh check"
check "empty SOURCES"                         1 'SOURCES is empty' ok "SOURCES= backup.sh check"
check "type not set"                          1 'EXTRA_TYPE must be drive, dropbox or yandex' ok "SOURCES='alice extra' backup.sh check"
check "bad type"                              1 "ALICE_TYPE must be drive, dropbox or yandex, got 'gdrive'" ok "ALICE_TYPE=gdrive backup.sh check"
check "bad account name"                      1 'ALICE_ACCOUNT must be' ok "ALICE_ACCOUNT=Bob backup.sh check"
check "a shared account, another type"        1 'share the account alice, so they must have the same TYPE' ok "TEAM_TYPE=dropbox TEAM_SHARED_DRIVE= backup.sh check"
check "shared drive on Dropbox"               1 'BOB_SHARED_DRIVE and BOB_SHARED_WITH_ME are for TYPE=drive only' ok "BOB_SHARED_DRIVE=x backup.sh check"
check "shared drive and shared with me"       1 'exclude each other' ok "TEAM_SHARED_WITH_ME=yes backup.sh check"
check "bad shared drive id"                   1 'must be the id of a shared drive' ok "TEAM_SHARED_DRIVE=a/b backup.sh check"
check "bad shared with me"                    1 'WITHME_SHARED_WITH_ME must be yes or no' ok "WITHME_SHARED_WITH_ME=true backup.sh check"
check "bad MAX_DELETE"                        1 'MAX_DELETE must be a whole number from 0 to 100' ok "MAX_DELETE=101 backup.sh check"
check "bad MAX_DELETE of a source"            1 'ALICE_MAX_DELETE must be a whole number' ok "ALICE_MAX_DELETE=08 backup.sh check"
check "bad number"                            1 'ALICE_KEEP_DAILY must be a number' ok "ALICE_KEEP_DAILY=08 backup.sh check"
check "retention all zero"                    1 'KEEP_\* settings of alice are all 0' ok "ALICE_KEEP_DAILY=0 ALICE_KEEP_WEEKLY=0 ALICE_KEEP_MONTHLY=0 backup.sh check"
check "--dump refused"                        1 'must not contain --dump' ok "ALICE_RCLONE_FLAGS='-v --dump headers' backup.sh check"
check "--log-file refused"                    1 'must not contain --dump, --log-file' ok "RCLONE_FLAGS='-vv --log-file=/data/x.log' backup.sh check"
check "--config refused"                      1 'must not contain --dump, --log-file, --config' ok "RCLONE_FLAGS='--config /data/x.conf' backup.sh check"
check "-P refused, also in a cluster"         1 'must not contain --dump, --log-file, --config or -P \(--progress\)' ok "ALICE_RCLONE_FLAGS='-vP' backup.sh check"
check "--progress refused"                    1 'or -P \(--progress\)' ok "RCLONE_FLAGS='--progress' backup.sh check"
check "--dump after a tab refused"            1 'must not contain --dump' ok "ALICE_RCLONE_FLAGS=\"\$(printf -- '-v\\t--dump\\tauth')\" backup.sh check"
for v in bogus 0% 150% 3/2 100 1/257; do
  check "bad CHECK_READ_SUBSET $v"            1 'CHECK_READ_SUBSET must be' ok "CHECK_READ_SUBSET=$v backup.sh check"
done
for v in 10% 2.5% 100% 1/5 5/5 500M; do
  check "good CHECK_READ_SUBSET $v"           0 'all good' ok "CHECK_READ_SUBSET=$v backup.sh check"
done
check "COPY_TARGET without colon"             1 'COPY_TARGET must be' ok "COPY_TARGET=nocolon backup.sh check"
check "COPY_TARGET without a key"             1 'copy_ssh_key or .* is missing' ok "COPY_TARGET=u@h: backup.sh check"

# Client secrets and tokens never show up in the output, in any escaped form: the fragments show up in all of them.
if echo "$ALL" | grep -qE "$SECRETS_RE"; then
  echo "FAIL a secret showed up in the output"; echo "$ALL" | grep -E "$SECRETS_RE" | head -3; FAILED=$((FAILED + 1))
else
  echo "ok   no secret in the output"
fi
if echo "$ALL" | grep -q FORBIDDEN; then
  echo "FAIL rclone or curl got something it must never get"; echo "$ALL" | grep FORBIDDEN | head -3; FAILED=$((FAILED + 1))
else
  echo "ok   rclone only listed and copied into the copy, curl only went to the services"
fi

# The scheduler starts as PID 1, with one crontab line per source, and stays up; not signed in is no reason to stop.
docker rm -f cdrb-sched-test >/dev/null 2>&1
docker run -d --name cdrb-sched-test $E -v "$d/secrets:/run/secrets:ro" -e CAROL_SCHEDULE='*/5 * * * *' "$IMG" >/dev/null
sleep 4
if docker ps --filter name=cdrb-sched-test --format '{{.Status}}' | grep -q '^Up' \
  && docker exec cdrb-sched-test cat /tmp/crontab | grep -qxF '30 4 * * * /usr/local/bin/backup.sh run alice' \
  && docker exec cdrb-sched-test cat /tmp/crontab | grep -qxF '*/5 * * * * /usr/local/bin/backup.sh run carol'; then
  echo "ok   scheduler stays up, a line per source"
else
  echo "FAIL scheduler"; docker logs cdrb-sched-test 2>&1 | tail -5; FAILED=$((FAILED + 1))
fi
docker rm -f cdrb-sched-test >/dev/null 2>&1

# Bad settings or a bad schedule stop the container at start.
for args in "-e SOURCES=" "-e ALICE_SCHEDULE=bogus" "-e ALICE_TYPE=gdrive"; do
  docker run -d --name cdrb-sched-test $E -v "$d/secrets:/run/secrets:ro" $args "$IMG" >/dev/null
  sleep 3
  if docker ps -a --filter name=cdrb-sched-test --format '{{.Status}}' | grep -q '^Exited (1)'; then
    echo "ok   container stops at start: $args"
  else
    echo "FAIL container should stop at start: $args"; docker logs cdrb-sched-test 2>&1 | tail -5; FAILED=$((FAILED + 1))
  fi
  docker rm -f cdrb-sched-test >/dev/null 2>&1
done

echo "FAILED: $FAILED"
[ "$FAILED" -eq 0 ]
