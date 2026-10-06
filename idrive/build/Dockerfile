# Specify the exact, minimal base image
FROM debian:trixie-slim

# OCI image labels are applied by the build workflow, not here, so they derive from
# whichever repository builds the image and stay correct in a fork.

# URL of the iDrive script package, with a fallback if the version-check couldn't resolve one.
ARG IDRIVE_URL=https://www.idrivedownloads.com/downloads/linux/linux-bin/idriveforlinux.bin

# Supplied automatically by buildx (e.g. linux/amd64, linux/arm64). Used below to add
# the 32-bit runtime that iDrive's ARM helper binaries need.
ARG TARGETPLATFORM

# Build-time only: keeps apt quiet during the build without changing apt's behaviour
# for anyone running it inside the finished container.
ARG DEBIAN_FRONTEND=noninteractive

# Consolidate all environment variables into a single layer.
# PYTHONDONTWRITEBYTECODE prevents Python from generating .pyc files on disk at runtime.
ENV PYTHONDONTWRITEBYTECODE=1 \
    LC_ALL=en_US.UTF-8 \
    LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LD_LIBRARY_PATH="/opt/IDriveForLinux/bin/Idrivelib/dependencies/python/lib" \
    PATH="${PATH}:/opt/IDriveForLinux/bin" \
    EDITOR=nano \
    TERM=xterm

# Consolidate dependencies, installation, and cleanup into a single atomic layer.
RUN apt-get update && \
    # 1. Install specific required packages; omitting vim and non-essentials.
    #
    #    libpopt0 must be installed BEFORE the iDrive installer runs below. The
    #    installer carries more than one build of its EVS helper and chooses by
    #    probing for libpopt: with the library present it deploys the current helper,
    #    which links libpopt.so.0 and understands the --cmd option the client passes.
    #    Without it, it falls back to an older helper that rejects --cmd, and every
    #    backup fails with "idevs: --cmd=...: unknown option".
    #
    #    Confirmed by comparing built images: the helper self-reports
    #    [20/JAN/2026] when built without libpopt0 and [17/AUG/2026] with it.
    #    Installing the package into an already-built image does not help -- the
    #    fallback binary is baked in at install time.
    apt-get install -y --no-install-recommends \
        ca-certificates locales python3 tzdata \
        cron curl unzip net-tools nano procps \
        libpopt0 && \
    # 1b. On arm64, iDrive ships those helpers as 32-bit armhf executables rather than
    #     arm64, hardcoded to the interpreter path /lib/ld-linux.so.3. Enable the
    #     foreign architecture, install the 32-bit runtime, and provide that path
    #     (Debian ships it as /lib/ld-linux-armhf.so.3).
    if [ "$TARGETPLATFORM" = "linux/arm64" ]; then \
        dpkg --add-architecture armhf && \
        apt-get update && \
        apt-get install -y --no-install-recommends libc6:armhf libpopt0:armhf && \
        ln -sf /lib/ld-linux-armhf.so.3 /lib/ld-linux.so.3; \
    fi && \
    # 2. Configure standard UTF-8 locales directly.
    echo "en_US.UTF-8 UTF-8" > /etc/locale.gen && \
    locale-gen && \
    update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 && \
    # 3. Pre-create the required directory structure for IDrive.
    mkdir -p /opt/IDriveForLinux/idriveIt/cache /opt/IDriveForLinux/bin \
             /opt/IDriveForLinux/idriveIt/user_profile/root/.trace && \
    # 4. Create spoofed installation state files and system symlinks.
    touch /opt/IDriveForLinux/idriveIt/inst.track \
          /opt/IDriveForLinux/idriveIt/idrivecrontab.json \
          /opt/IDriveForLinux/idriveIt/user_profile/root/.trace/traceLog.txt && \
    ln -s /opt/IDriveForLinux/idriveIt/idrivecrontab.json /etc/idrivecrontab.json && \
    ln -s /opt/IDriveForLinux/bin/idrive /etc/idrivecron && \
    # 5. Download the installer directly to /tmp.
    curl -fsSL -o /tmp/idriveforlinux.bin "${IDRIVE_URL}" && \
    chmod a+x /tmp/idriveforlinux.bin && \
    # 6. Execute the installer non-interactively using the required character sequence.
    #    printf, not `echo -en`: RUN uses /bin/sh (dash on Debian), whose echo does
    #    not recognise -en and emits it as literal text, feeding the installer
    #    "-en A" plus a stray newline instead of "A".
    printf 'A\n\n\n\n' | /tmp/idriveforlinux.bin --install && \
    # 7. Purge temporary build tools and execute deep artifact cleansing.
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* \
           /tmp/* \
           /var/tmp/* \
           /opt/IDriveForLinux/bin/Idrivelib/dependencies/pkg/* && \
    find /opt/IDriveForLinux/bin/Idrivelib/cronsetup/ -mindepth 1 -maxdepth 1 ! -name 'debian' -exec rm -rf {} + && \
    # 8. Archive the pristine configuration for dynamic volume initialization on startup.
    #    Kept outside /tmp: /tmp is routinely overridden (--tmpfs /tmp, a compose
    #    tmpfs), which would silently remove the archive start.sh needs to keep the
    #    idevsutil helpers in step with the image. Sibling of the volume, not inside it.
    echo "" > /opt/IDriveForLinux/idriveIt/user_profile/root/.trace/traceLog.txt && \
    tar -czf /opt/IDriveForLinux/idriveIt.orig.tar.gz -C /opt/IDriveForLinux idriveIt

# Set the working directory for subsequent commands and container execution.
WORKDIR /opt/IDriveForLinux/bin

# Copy the initialization script and set executable permissions natively via Docker.
COPY --chmod=755 start.sh /start.sh

# Declare the persistent volume mount point.
VOLUME ["/opt/IDriveForLinux/idriveIt"]

# Define container health check to monitor the core backup daemon
HEALTHCHECK --interval=2m --timeout=10s --start-period=30s --retries=3 \
    CMD pgrep -f "/etc/idrivecron" > /dev/null || exit 1

# Define the default execution command.
CMD ["/start.sh"]
