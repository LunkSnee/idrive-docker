# IDrive for Linux in a container.
#
# Two stages keep the published image small:
#   builder - downloads IDrive's installer, runs it, checks that the installed programs start,
#             and packs the default contents of the config folder into idriveIt.orig.tar.gz
#   runtime - a clean debian:trixie-slim with only what IDrive needs at run time, plus the
#             installed /opt/IDriveForLinux copied from the builder
#
# docker/start.sh (the container's entry point) runs docker/idrive-init.py at every start,
# which restores missing files from idriveIt.orig.tar.gz into the persistent config volume.
# .image_version records the IDrive version this image installed.

# ---------------------------------------------------------------------------------------------
# Stage 1: run IDrive's installer
# ---------------------------------------------------------------------------------------------
FROM debian:trixie-slim AS builder

ARG TARGETPLATFORM
ARG DEBIAN_FRONTEND=noninteractive

ENV PYTHONDONTWRITEBYTECODE=1 \
    LC_ALL=C.UTF-8 \
    LANG=C.UTF-8 \
    LANGUAGE=C.UTF-8 \
    LD_LIBRARY_PATH="/opt/IDriveForLinux/bin/Idrivelib/dependencies/python/lib" \
    PATH="${PATH}:/opt/IDriveForLinux/bin"

# What the installer and the build checks need:
# - libpopt0 must exist before the installer runs, or it deploys an older transfer helper
#   (idevsutil) that does not understand --cmd and fails every backup.
# - libexpat1 is needed by IDrive's bundled Python (checked below via `dashboard -v`).
# - The installer refuses to run without `crontab`. IDrive brings its own scheduler
#   (/etc/idrivecron), so a stub satisfies the check without installing cron and systemd.
# - arm64 hosts run IDrive's 32-bit ARM build, which needs the armhf C library.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates curl procps libpopt0 libexpat1 && \
    if [ "${TARGETPLATFORM:-}" = "linux/arm64" ] || { [ -z "${TARGETPLATFORM:-}" ] && [ "$(uname -m)" = "aarch64" ]; }; then \
        dpkg --add-architecture armhf && \
        apt-get update && \
        apt-get install -y --no-install-recommends libc6:armhf libpopt0:armhf && \
        ln -sf /lib/ld-linux-armhf.so.3 /lib/ld-linux.so.3; \
    fi && \
    rm -rf /var/lib/apt/lists/* && \
    printf '#!/bin/sh\nexit 0\n' > /usr/local/bin/crontab && \
    chmod +x /usr/local/bin/crontab

# CI passes the current release's (cache-busted) URL; the default always points at the latest.
ARG IDRIVE_URL=https://www.idrivedownloads.com/downloads/linux/linux-bin/idriveforlinux.bin
# IDrive's optional Cloud Drive component (~60 MB) is not needed for backups.
ARG INCLUDE_CLOUD_DRIVE=false

# Install, trim, pack the config defaults, then check that the installed programs start.
# printf, not `echo -en`: RUN uses dash, whose echo prints -en literally. The installer is the
# last command in its pipe, so its exit status already fails the build.
# hadolint ignore=DL4006
RUN case "$INCLUDE_CLOUD_DRIVE" in true|false) ;; \
        *) echo "INCLUDE_CLOUD_DRIVE must be true or false" >&2; exit 1 ;; esac && \
    mkdir -p /opt/IDriveForLinux/idriveIt/cache /opt/IDriveForLinux/bin \
             /opt/IDriveForLinux/idriveIt/user_profile/root/.trace && \
    touch /opt/IDriveForLinux/idriveIt/inst.track \
          /opt/IDriveForLinux/idriveIt/idrivecrontab.json \
          /opt/IDriveForLinux/idriveIt/user_profile/root/.trace/traceLog.txt && \
    ln -s /opt/IDriveForLinux/idriveIt/idrivecrontab.json /etc/idrivecrontab.json && \
    ln -s /opt/IDriveForLinux/bin/idrive /etc/idrivecron && \
    curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 --connect-timeout 20 \
        -o /tmp/idriveforlinux.bin "${IDRIVE_URL}" && \
    chmod a+x /tmp/idriveforlinux.bin && \
    printf 'A\n\n\n\n' | /tmp/idriveforlinux.bin --install && \
    rm -rf /tmp/* /var/tmp/* /opt/IDriveForLinux/bin/Idrivelib/dependencies/pkg/* && \
    find /opt/IDriveForLinux/bin/Idrivelib/cronsetup/ -mindepth 1 -maxdepth 1 ! -name 'debian' -exec rm -rf {} + && \
    if [ "$INCLUDE_CLOUD_DRIVE" = false ]; then \
        rm -rf /opt/IDriveForLinux/bin/Idrivelib/dependencies/cloud-drive \
               /opt/IDriveForLinux/.config/cloud-drive; \
    fi && \
    echo "" > /opt/IDriveForLinux/idriveIt/user_profile/root/.trace/traceLog.txt && \
    tar -czf /opt/IDriveForLinux/idriveIt.orig.tar.gz -C /opt/IDriveForLinux idriveIt && \
    /opt/IDriveForLinux/bin/idrive --version | tr -d '\r\n' > /opt/IDriveForLinux/.image_version && \
    test -s /opt/IDriveForLinux/.image_version && \
    for bin in /opt/IDriveForLinux/idriveIt/idevsutil*; do "$bin" --help >/dev/null; done && \
    if [ -x /opt/IDriveForLinux/bin/Idrivelib/dependencies/python/dashboard ]; then \
        /opt/IDriveForLinux/bin/Idrivelib/dependencies/python/dashboard -v >/dev/null; \
    fi && \
    # The defaults live in the archive; leaving them in the image as well would duplicate
    # the idevsutil programs (start.sh restores them into the volume).
    rm -rf /opt/IDriveForLinux/idriveIt/*

# ---------------------------------------------------------------------------------------------
# Stage 2: runtime image
# ---------------------------------------------------------------------------------------------
FROM debian:trixie-slim AS runtime

ARG TARGETPLATFORM
ARG DEBIAN_FRONTEND=noninteractive

# C.UTF-8 is built into Debian, so no locales package is needed for UTF-8 file names.
ENV PYTHONDONTWRITEBYTECODE=1 \
    LC_ALL=C.UTF-8 \
    LANG=C.UTF-8 \
    LANGUAGE=C.UTF-8 \
    LD_LIBRARY_PATH="/opt/IDriveForLinux/bin/Idrivelib/dependencies/python/lib" \
    PATH="${PATH}:/opt/IDriveForLinux/bin" \
    EDITOR=nano \
    TERM=xterm

# Run-time packages:
# - curl: IDrive checks for `curl` and `tar` before every backup and schedule change.
# - net-tools: IDrive builds its device ID from the MAC address reported by `ifconfig -a`.
# - procps: `pgrep`, used by the health check.
# - tzdata: so TZ works. nano: the editor IDrive opens for exclude lists.
# - python3: runs docker/idrive-init.py.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates curl python3 tzdata \
        net-tools nano procps libpopt0 libexpat1 && \
    if [ "${TARGETPLATFORM:-}" = "linux/arm64" ] || { [ -z "${TARGETPLATFORM:-}" ] && [ "$(uname -m)" = "aarch64" ]; }; then \
        dpkg --add-architecture armhf && \
        apt-get update && \
        apt-get install -y --no-install-recommends libc6:armhf libpopt0:armhf && \
        ln -sf /lib/ld-linux-armhf.so.3 /lib/ld-linux.so.3; \
    fi && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* && \
    ln -s /opt/IDriveForLinux/idriveIt/idrivecrontab.json /etc/idrivecrontab.json && \
    ln -s /opt/IDriveForLinux/bin/idrive /etc/idrivecron

COPY --from=builder /opt/IDriveForLinux /opt/IDriveForLinux

WORKDIR /opt/IDriveForLinux/bin

COPY --chmod=755 docker/idrive-init.py /usr/local/bin/idrive-init.py
COPY --chmod=755 docker/start.sh /start.sh

# IDrive's settings, saved login and logs. Mount a volume or host folder here.
VOLUME ["/opt/IDriveForLinux/idriveIt"]

# Healthy = IDrive's service runs and, once an account is set up, it is logged in with an
# active schedule (see collect_health_state in docker/idrive-init.py). The check keeps its
# own commands within 40 s, well inside the 60 s timeout.
HEALTHCHECK --interval=2m --timeout=60s --start-period=60s --retries=3 \
    CMD ["/usr/local/bin/idrive-init.py", "healthcheck"]

CMD ["/start.sh"]
