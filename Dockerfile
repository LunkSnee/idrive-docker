# IDrive for Linux in a container.
#
# Built in a single debian:trixie-slim stage:
# - Installs runtime dependencies, runs IDrive's installer using a temporary crontab stub
#   (removed in the same layer), trims unused platform/component files, and checks that the
#   installed programs start.
# - Packs the default contents of the config folder into idriveIt.orig.tar.gz and clears
#   /opt/IDriveForLinux/idriveIt so those files are not duplicated in the image.
# - docker/start.sh (the container's entry point) runs docker/idrive-init.py at every start,
#   which restores missing files from idriveIt.orig.tar.gz into the persistent config volume.
# - .image_version records the IDrive version this image installed.

# IDrive's installer, when the build is given one: CI passes its cached copy as the "installer"
# build context (--build-context installer=<dir>), so it does not depend on IDrive's download
# link answering. A plain `docker build` leaves this stage empty and the installer is downloaded.
FROM scratch AS installer

FROM debian:trixie-slim

ARG TARGETPLATFORM
ARG DEBIAN_FRONTEND=noninteractive

# C.UTF-8 is built into Debian, so no locales package is needed for UTF-8 file names.
ENV PYTHONDONTWRITEBYTECODE=1 \
    LC_ALL=C.UTF-8 \
    LANG=C.UTF-8 \
    LD_LIBRARY_PATH="/opt/IDriveForLinux/bin/Idrivelib/dependencies/python/lib" \
    PATH="${PATH}:/opt/IDriveForLinux/bin" \
    EDITOR=nano \
    TERM=xterm

# Run-time and installer dependencies:
# - libpopt0 must exist before the installer runs, or it deploys an older transfer helper
#   (idevsutil) that does not understand --cmd and fails every backup.
# - libexpat1 is needed by IDrive's bundled Python (checked below via `dashboard -v`).
# - curl: downloads the installer here and is checked by IDrive (with `tar`) at run time.
# - net-tools: IDrive builds its device ID from the MAC address reported by `ifconfig -a`.
# - procps: `pgrep`, used by the health check.
# - tzdata: so TZ works. nano: the editor IDrive opens for exclude lists.
# - python3: runs docker/idrive-init.py.
# - arm64 hosts run IDrive's 32-bit ARM build, which needs the armhf C library.
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
    rm -rf /var/lib/apt/lists/*

# CI passes the current release's (cache-busted) URL; the default always points at the latest.
ARG IDRIVE_URL=https://www.idrivedownloads.com/downloads/linux/linux-bin/idriveforlinux.bin
# IDrive's optional Cloud Drive component (~60 MB) is not needed for backups.
ARG INCLUDE_CLOUD_DRIVE=false

# Install, trim, pack the config defaults, then check that the installed programs start.
# - The installer refuses to run without `crontab`. IDrive brings its own scheduler
#   (/etc/idrivecron), so a temporary stub satisfies the check without installing cron and
#   systemd and is removed in the same layer.
# - The installer comes from the "installer" build context when given, otherwise from IDRIVE_URL
#   via scripts/idrive-fetch.sh, which retries when IDrive's link answers with a web page.
# - printf, not `echo -en`: RUN uses dash, whose echo prints -en literally. The installer is the
#   last command in its pipe, so its exit status already fails the build.
# hadolint ignore=DL4006
RUN --mount=type=bind,source=scripts/idrive-fetch.sh,target=/idrive-fetch.sh \
    --mount=type=bind,from=installer,target=/installer \
    case "$INCLUDE_CLOUD_DRIVE" in true|false) ;; \
        *) echo "INCLUDE_CLOUD_DRIVE must be true or false" >&2; exit 1 ;; esac && \
    printf '#!/bin/sh\nexit 0\n' > /usr/local/bin/crontab && \
    chmod +x /usr/local/bin/crontab && \
    if [ -f /installer/idriveforlinux.bin ]; then \
        echo "Using the given IDrive installer." && \
        cp /installer/idriveforlinux.bin /tmp/idriveforlinux.bin; \
    else \
        sh /idrive-fetch.sh "${IDRIVE_URL}" /tmp/idriveforlinux.bin '^#!'; \
    fi && \
    chmod a+x /tmp/idriveforlinux.bin && \
    printf 'A\n' | /tmp/idriveforlinux.bin --install && \
    rm -rf /tmp/* /var/tmp/* /usr/local/bin/crontab \
        /opt/IDriveForLinux/bin/Idrivelib/dependencies/pkg/* && \
    find /opt/IDriveForLinux/bin/Idrivelib/cronsetup/ -mindepth 1 -maxdepth 1 ! -name 'debian' -exec rm -rf {} + && \
    if [ "$INCLUDE_CLOUD_DRIVE" = false ]; then \
        rm -rf /opt/IDriveForLinux/bin/Idrivelib/dependencies/cloud-drive \
               /opt/IDriveForLinux/.config/cloud-drive && \
        if [ -d /opt/IDriveForLinux/.config ]; then rmdir --ignore-fail-on-non-empty /opt/IDriveForLinux/.config; fi; \
    fi && \
    ln -s /opt/IDriveForLinux/idriveIt/idrivecrontab.json /etc/idrivecrontab.json && \
    ln -s /opt/IDriveForLinux/bin/idrive /etc/idrivecron && \
    : > /opt/IDriveForLinux/idriveIt/user_profile/root/.trace/traceLog.txt && \
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

WORKDIR /opt/IDriveForLinux/bin

COPY --chmod=755 docker/idrive-init.py /usr/local/bin/idrive-init.py
COPY --chmod=755 docker/start.sh /start.sh

# IDrive's settings, saved login and logs. Mount a volume or host folder here.
VOLUME ["/opt/IDriveForLinux/idriveIt"]

# Healthy = IDrive's service runs and, once an account is set up, it is logged in with an
# active schedule, and its last 3 scheduled backups did not all fail (see collect_health_state
# in docker/idrive-init.py). The check keeps its own commands within 40 s, well inside the 60 s
# timeout.
HEALTHCHECK --interval=2m --timeout=60s --start-period=60s --retries=3 \
    CMD ["/usr/local/bin/idrive-init.py", "healthcheck"]

CMD ["/start.sh"]
