# Specify the exact, minimal base image
FROM debian:bookworm-slim

# Consolidate all environment variables into a single layer.
# PYTHONDONTWRITEBYTECODE prevents Python from generating .pyc files on disk at runtime.
ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONDONTWRITEBYTECODE=1 \
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
    apt-get install -y --no-install-recommends \
        ca-certificates locales python3 tzdata \
        cron curl unzip net-tools nano procps && \
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
    curl -fsSL -o /tmp/idriveforlinux.bin https://www.idrivedownloads.com/downloads/linux/download-for-linux/linux-bin/idriveforlinux.bin && \
    chmod a+x /tmp/idriveforlinux.bin && \
    # 6. Execute the installer non-interactively using the required character sequence.
    echo -en "A\n\n\n\n" | /tmp/idriveforlinux.bin --install && \
    # 7. Purge temporary build tools and execute deep artifact cleansing.
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* \
           /tmp/* \
           /var/tmp/* \
           /opt/IDriveForLinux/bin/Idrivelib/dependencies/pkg/* && \
    find /opt/IDriveForLinux/bin/Idrivelib/cronsetup/ -mindepth 1 -maxdepth 1 ! -name 'debian' -exec rm -rf {} + && \
    # 8. Archive the pristine configuration for dynamic volume initialization on startup.
    echo "" > /opt/IDriveForLinux/idriveIt/user_profile/root/.trace/traceLog.txt && \
    tar -czf /tmp/idriveIt.orig.tar.gz -C /opt/IDriveForLinux idriveIt

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
