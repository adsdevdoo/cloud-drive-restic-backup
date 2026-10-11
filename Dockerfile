FROM alpine:3.24

# GNU gawk: backup.sh needs awk the busybox applet does not have. util-linux-misc: mountpoint (flock is busybox's,
# with the options backup.sh uses). curl and jq: the sign-in (backup.sh auth) and the tokens. rsync and
# openssh-client: the optional off-host copy.
RUN apk add --no-cache bash ca-certificates coreutils curl findutils gawk jq openssh-client rclone restic rsync supercronic tzdata util-linux-misc

COPY backup.sh entrypoint.sh /usr/local/bin/
RUN chmod 755 /usr/local/bin/backup.sh /usr/local/bin/entrypoint.sh

ENV TZ=UTC \
    RESTIC_REPOSITORY=/data/restic \
    RESTIC_PASSWORD_FILE=/run/secrets/restic_password \
    RESTIC_CACHE_DIR=/data/cache
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
