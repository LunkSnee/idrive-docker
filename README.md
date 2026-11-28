# idrive-docker

Runs the [IDrive for Linux](https://www.idrive.com/online-backup-linux) backup client in a Docker container (`amd64` and `arm64`), so a server or NAS can back up to IDrive without installing anything on the host.

GitHub: https://github.com/LunkSnee/idrive-docker

On top of the plain IDrive client, this image:

- **Stays logged in across restarts, host reboots and image upgrades.** IDrive logs itself out when it thinks the machine changed; the container updates the state IDrive checks before it starts.
- **Can log in by itself** (optional): first-time setup and re-login from Docker secrets, including two-factor authentication (2FA) codes from an authenticator-app setup key.
- **Recovers from logouts while running**: a watchdog notices and restarts the container to log in again, with backoff so it can never lock your account.
- **Reports real health** in `docker ps`: `(healthy)` means IDrive's service is running *and* (once configured or with credentials provided) logged in with an active schedule whose last 3 scheduled backups did not all fail.
- **Keeps `docker logs` readable**: filters out IDrive's bulk file-list chatter by default and adds concise `[job]` summary and progress lines.
- **Updates IDrive through new images**, not by patching itself inside the container (which would log you out).

## Quick start

> Requires Docker Engine and Docker Compose (`v2.24.0+` for optional `.env` loading in [`compose.yaml`](compose.yaml)).

1. Get [`compose.yaml`](compose.yaml) and [`.env.example`](.env.example) into a folder.
2. In `compose.yaml`:
   - Keep the named volume `idrive:/opt/IDriveForLinux/idriveIt` (or switch to a bind mount `- /path/to/config:/opt/IDriveForLinux/idriveIt`). Keeping this folder is what preserves your login, settings and schedule.
   - Replace `/path/to/backup:/source/1:ro` with each folder you want to back up, one line per folder, read-only (for example `/path/to/other:/source/2:ro`).
3. Copy `.env.example` to `.env` and set `TZ` to your time zone.
4. Start the container:

   ```bash
   docker compose up -d
   ```

5. Set up your IDrive account, either interactively:

   ```bash
   docker exec -it idrive idrive --account-setting
   ```

   For interactive setup:
   - `1) Login using IDrive credentials` → enter your IDrive username and password
   - `1) Create new Backup Location` (or reuse an existing one) → enter a Backup Location name (do not leave it empty)

   Or configure [automated login](#automated-login-optional) with Docker secrets instead.
6. Choose what to back up and when. Mounting a folder only makes it visible inside the container; you still select it in IDrive (pick `/source` to include every `/source/*` mount):

   ```bash
   docker exec -it idrive idrive --edit-job-sets
   docker exec -it idrive idrive --scheduler
   ```

   Help for the IDrive CLI is in the [IDrive Linux documentation](https://www.idrive.com/readme) and [IDrive FAQs](https://www.idrive.com/faq_linux#linuxWeb2).
7. Check status: `docker ps` should show `(healthy)` within a minute or two.

<details>
<summary>Without Compose (<code>docker run</code>)</summary>

```bash
docker volume create idrive
docker run -d --name idrive --hostname idrive-backup --restart unless-stopped \
  -e TZ=Etc/UTC \
  -v idrive:/opt/IDriveForLinux/idriveIt \
  -v /path/to/backup:/source/1:ro \
  ghcr.io/lunksnee/idrive-docker:latest
```

To use a host folder instead of a named volume:

```bash
CONFIG_PATH=/path/to/config
mkdir -p "$CONFIG_PATH"
docker run -d --name idrive --hostname idrive-backup --restart unless-stopped \
  -e TZ=Etc/UTC \
  -v "$CONFIG_PATH:/opt/IDriveForLinux/idriveIt" \
  -v /path/to/backup:/source/1:ro \
  ghcr.io/lunksnee/idrive-docker:latest
```

</details>

## Which image tag to use

Images are published to GHCR (`ghcr.io/lunksnee/idrive-docker`) and Docker Hub (when configured). Thanks to @araines for the IDrive version tagging pattern.

| Tag | Moves? | Use it when |
|-----|--------|-------------|
| `3.17.1-r2` (`<version>-r<N>`) | Never | You want a fixed, known build. Best for unattended backups. |
| `3.17.1` (`<version>`) | To the newest `-r<N>` build of that IDrive version | You want image fixes without changing IDrive versions. |
| `latest` | To a new IDrive version once it has been public for 7 days | You want new IDrive versions automatically, after a short wait. |

Every build gets an immutable `<version>-r<N>` tag (starting at `r1` per IDrive version) and a matching [GitHub Release](../../releases) explaining why it was built. Version tags publish as soon as a new IDrive release builds; `:latest` waits `LATEST_MIN_AGE_DAYS` (7 by default, set in [`.github/workflows/build-and-publish.yml`](.github/workflows/build-and-publish.yml)) so a broken release does not reach `:latest` users on day one.

## Everyday commands

```bash
docker exec -it idrive idrive --login           # log in again by hand
docker exec -it idrive idrive --edit-job-sets   # choose what to back up / exclude
docker exec -it idrive idrive --scheduler       # set backup schedule
docker exec idrive idrive --backup --silent     # start a backup now
docker exec -it idrive idrive --restore         # restore files (to a writable mount such as /restore)
docker exec -it idrive idrive --account-setting # change account settings
docker exec -it idrive idrive --logs            # inspect job logs inside IDrive
docker logs -f idrive                           # watch container, job and trace logs
```

To restore files, add a writable mount (for example `/path/to/restore:/restore` in `compose.yaml`) and choose `/restore` as the restore destination. Keep backup source mounts read-only (`:ro`).

## Settings

All settings are optional environment variables. With Compose, put them in `.env` ([`.env.example`](.env.example) lists every variable with comments).

| Variable | Default | What it does |
|----------|---------|--------------|
| `TZ` | `Etc/UTC` | Time zone for IDrive's logs and backup schedule. Keep it consistent across restarts. |
| `IDRIVE_LOG_LEVEL` | `info` | Trace log verbosity in `docker logs`: `full`, `info`, or `summary` (see [Logs](#logs)). |
| `IDRIVE_ACCOUNT_FILE` / `IDRIVE_ACCOUNT` | unset | IDrive login (email or username). Turns on automated login. |
| `IDRIVE_PASSWORD_FILE` / `IDRIVE_PASSWORD` | unset | Password for that account. |
| `IDRIVE_TOTP_SECRET_FILE` / `IDRIVE_TOTP_SECRET` | unset | Authenticator-app setup key (Base32 or `otpauth://` URI), only if 2FA is on. |
| `IDRIVE_ENCRYPTION_KEY_FILE` / `IDRIVE_ENCRYPTION_KEY` | unset | Your private encryption key, only if the account uses private encryption. |
| `IDRIVE_ENCRYPTION_TYPE` | `DEFAULT` | First-time setup only: `DEFAULT` or `PRIVATE` (`PRIVATE` requires the key above). |
| `IDRIVE_BACKUP_LOCATION` | container hostname | First-time setup only: device name in IDrive (1–64 chars `[A-Za-z0-9_-]`). Reuses an existing match or creates and renames a new one. |
| `IDRIVE_WATCHDOG_INTERVAL` | `300` | Seconds between login checks while running; `0` turns the watchdog off. |

The `_FILE` form reads the value from a file (such as a Docker secret) and is recommended: plain environment variables can be read by anyone who can run `docker inspect`. Either way, the container unsets plain variables before starting IDrive's background daemon.

## Automated login (optional)

Instead of logging in by hand, the container can set up an empty config volume and log back in automatically whenever it starts logged out, reading credentials from Docker secret files.

1. Create a `secrets` folder next to `compose.yaml` (gitignored), one value per file with **no trailing newline**:

   ```bash
   mkdir -p secrets && chmod 700 secrets
   printf '%s' 'you@example.com'      > secrets/idrive_account
   printf '%s' 'your-idrive-password' > secrets/idrive_password
   printf '%s' 'YOURTOTPSETUPKEY'     > secrets/idrive_totp_secret     # only if 2FA is on
   # printf '%s' 'your-private-key'   > secrets/idrive_encryption_key  # only for a private key
   chmod 400 secrets/idrive_*
   ```

2. In [`compose.yaml`](compose.yaml), uncomment the matching lines in both `secrets:` blocks (under the service and at the bottom).
3. Copy `.env.example` to `.env` and uncomment the matching `IDRIVE_*_FILE` lines.
4. Run `docker compose up -d` and watch `docker logs -f idrive` for `[autologin] Account setup completed successfully.`

**First-time setup defaults:** automated `--account-setting` answers no proxy, trusts this device, uses `Mirror` backup mode, and skips copying saved cloud settings from a reused backup location. A volume already set up for one account is never logged into another.

**Two-factor authentication:** automated login supports **authenticator-app** TOTP keys (the text setup key or `otpauth://` link shown when adding an authenticator app to IDrive). Keeping it next to the password means anyone with root on the Docker host has both factors; it still protects against a leaked password alone. Without a key, log in interactively with `docker exec -it idrive idrive --login`.

With credentials configured, `(healthy)` also requires the account to be set up and logged in, so a failed first setup shows as unhealthy rather than waiting indefinitely.

### Staying logged in (watchdog)

IDrive can also log itself out while running (for example after server errors such as `password mismatch`, `failed to get the device information` or `invalid device id`). With automated login configured, the container recovers automatically:

- **Watchdog:** every `IDRIVE_WATCHDOG_INTERVAL` seconds (default `300`, `0` turns it off) the container checks the login. If the account is logged out or its schedule is `INACTIVE` on two checks in a row, the container exits with code `3`, Docker's restart policy starts a fresh container, and startup logs back in. Keep `restart: unless-stopped`: without a restart policy the container stops.
- **Backoff:** failed logins retry after 5 min, 10 min, 20 min, and so on up to 6 h across restarts. History is kept in `cache/autologin-state.json` on the config volume (timestamps, attempt counts, salted settings hash, last error, and last 2FA time step; no passwords).
- **Pause on credential errors:** a wrong password, rejected 2FA code, blocked account, or invalid setting pauses automated login completely so it cannot lock the account. It resumes automatically once you update credentials or settings and restart, or when you explicitly reset it:

  ```bash
  docker exec idrive idrive-init.py reset-login && docker restart idrive
  ```

Without credentials, the watchdog only logs a reminder (`idrive --login`).

## Logs

`docker logs idrive` combines container lifecycle messages (`[init]`, `[autologin]`, `[watchdog]`), IDrive's trace logs, and one `[job]` line per finished backup or restore:

```text
[job] Backup (Scheduled) Success: 779,526 considered, 5,258 backed up (2.58 GB), 0 failed, ended 2026-11-26 02:54
```

While a job is running (at `full` or `info`), a progress line is printed when the job starts and every 10 minutes thereafter when the numbers change, showing progress across files that need uploading (files already in the account are shown separately):

```text
[job] Backup (Scheduled) running since 23:30: 21,337 of 30,370 files to upload processed (70%); 777,976 of 808,346 already in the account
```

`IDRIVE_LOG_LEVEL` controls how much of IDrive's trace logs is forwarded to `docker logs`:

| Level | What reaches `docker logs` |
|-------|----------------------------|
| `full` | Everything IDrive writes to its trace logs, starting with the last 10 lines as context. |
| `info` (default) | Only new lines, dropping IDrive's bulk output: the backup set listing (1,000 files per message), the file watcher's chatter (`Starting rescan`, `dir add event`, bare file paths that report no error), and per-batch fork/debug lines. |
| `summary` | Only new trace lines reporting errors or logouts, plus finished `[job]` summary lines (`docker logs` reads as a backup history). |

IDrive's complete logs remain on the config volume (`user_profile/root/<account>/.trace/` and `.../LOGS/`, also viewable via `docker exec -it idrive idrive --logs`).

## Upgrading

**Normal upgrade:** pull the new image and recreate the container; your config volume, login, and schedules carry over:

```bash
docker compose pull && docker compose up -d
```

**From older versions of this image** (before automated login and layout changes): your existing config volume and login carry over unchanged. Note that `docker-compose.yml` and `docker-compose-mounts.yml` were consolidated into [`compose.yaml`](compose.yaml), and the build context moved from `idrive/build/` to the repository root (`Dockerfile`).

**Moving to a new host or empty config volume:** your backed-up files in the cloud stay intact. Copy the config volume to preserve everything seamlessly, or start fresh with the same `hostname` and reconnect to your existing backup location via `idrive --account-setting` (or `IDRIVE_BACKUP_LOCATION`).

## Troubleshooting

| Symptom | What to do |
|---------|------------|
| `docker ps` shows `(unhealthy)` | Run `docker exec idrive idrive-init.py healthcheck` for the exact reason (prints nothing when healthy). |
| `the last 3 scheduled backups failed` | Backups have stopped working while IDrive is logged in (for example a source folder no longer mounted, a full quota, or a changed encryption key). The `[job]` lines in `docker logs` and `docker exec -it idrive idrive --logs` show why; the container is healthy again after the next successful scheduled backup. |
| Log or schedule times are hours off | Check `tz=` and `local_time=` in the `[init] Summary:` line. With `TZ=${TZ}` under `environment:` in your compose file, a `TZ` set in the shell or deploy tool that runs Compose overrides `.env`; this image's `compose.yaml` loads `.env` with `env_file:`, which is not affected. |
| Excluded files are still backed up | IDrive applies exclude lists changed in its editor once it refreshes its file database. In `docker exec -it idrive idrive --edit-job-sets`, switch the hidden-files exclusion off and on again to make it refresh. |
| `WARNING: IDrive's config (...) is on an anonymous Docker volume` | Mount a named volume (`idrive:/opt/IDriveForLinux/idriveIt`) or host bind mount so `docker compose down` does not erase your login and schedule. |
| `RMSH is empty in CONFIGURATION_FILE` | Logins created by older IDrive releases lack `RMSH`, which IDrive `3.17.1+` validates; run `docker exec -it idrive idrive --login` once. |
| Log says `automated login paused after: ...` | Fix the password, 2FA key, or setting and restart, or run `docker exec idrive idrive-init.py reset-login && docker restart idrive`. |
| Container exited with code `3` | Expected when the watchdog restarts the container to recover a dropped session via automated login. |
| `two-factor code was rejected` | Check `IDRIVE_TOTP_SECRET` and verify the host clock is NTP-synced. |

## The config volume

`/opt/IDriveForLinux/idriveIt` holds everything IDrive persists: the active login (`cache/idriveuser.txt`), schedules (`idrivecrontab.json`), and per-account settings, obfuscated saved passwords, backup sets, excludes, and job logs (`user_profile/root/<account>/`). Always mount `/opt/IDriveForLinux/idriveIt` as a whole (named volume or host bind mount) — mounting only a subdirectory loses login or schedule state.

Without a mount, Docker creates an anonymous volume for the `VOLUME` declaration, which `docker compose down` or `docker rm -v` deletes; the container warns at startup when this happens. Because IDrive's saved passwords live inside this folder, restrict host permissions on bind mounts. The container runs as `root` because `idrivecron` refuses to run as a non-root user; keep backup source mounts read-only (`:ro`).

## How it works

At every container start, [`docker/start.sh`](docker/start.sh) runs [`docker/idrive-init.py`](docker/idrive-init.py) `prepare` before starting `/etc/idrivecron`:

- **Boot time (`UPTIME`):** IDrive records the host boot time and logs out (`dashboard_uptime`) when it changes for accounts not on WebSocket remote management (`RMWS != yes`). `prepare` writes the current boot time first so host reboots do not trigger a logout.
- **Self-update disabled:** `AUTOSOFTWAREUPDATE` and scheduled `--launch-update` jobs are turned off because in-container self-updates log the account out and only patch the container layer rather than the image.
- **Version and install markers:** `cache/version` is synced to the image's IDrive version, `cache/.updateVersionInfo` is removed, and `inst.track` is excluded/removed once an account is initialized (leaving `inst.track` causes `--account-setting` to wipe schedules).
- **Transfer helpers and locks:** missing defaults are restored from `/opt/IDriveForLinux/idriveIt.orig.tar.gz`, `idevsutil*` binaries are refreshed to match the image, and stale `.lock`/`.pid` files from unclean stops are removed.

The image is built in a single stage on `debian:trixie-slim`. It installs only runtime packages, satisfies the IDrive installer with a temporary `crontab` stub removed in the same layer (avoiding `cron` and `systemd`, since IDrive runs `/etc/idrivecron`), omits `locales` (`C.UTF-8` is built into Debian) and `unzip`, packs the default configuration into `idriveIt.orig.tar.gz`, and strips installer caches, non-Debian cron scripts, and by default Cloud Drive (`INCLUDE_CLOUD_DRIVE=false`; note that setting `INCLUDE_CLOUD_DRIVE=true` preserves IDrive's Cloud Drive files, though FUSE host packages such as `fuse3` are not installed in the lean image).

## Development

Pull requests touching the image are built natively for `linux/amd64` and `linux/arm64` and verified with the offline smoke test before publishing.

Build locally from the repository root:

```bash
# Current IDrive release
docker build -t idrive-docker:local .

# Pick up a newly released IDrive installer (bypassing Docker layer cache)
docker build --no-cache -t idrive-docker:local .

# Include IDrive's optional Cloud Drive files (~60 MB extra)
docker build --build-arg INCLUDE_CLOUD_DRIVE=true -t idrive-docker:local .
```

Run tests:

```bash
# Offline smoke test (no IDrive account needed)
./tests/smoke-test.sh idrive-docker:local

# Live test against IDrive's servers: fresh setup, UTF-8 backups, then upgrade chain
./tests/e2e-upgrade-test.sh idrive-docker:local
```

`tests/e2e-upgrade-test.sh` reads plain `IDRIVE_ACCOUNT`, `IDRIVE_PASSWORD`, and optional `IDRIVE_TOTP_SECRET` / `IDRIVE_ENCRYPTION_TYPE` / `IDRIVE_ENCRYPTION_KEY` from `.env` (or `$ENV_FILE`). **Use a separate test account:** each run creates an `E2E-Test-...` backup location and uploads small test files.

Run the same static checks as the `Lint` workflow (only Docker needed):

```bash
docker run --rm -i -v "$PWD/.hadolint.yaml:/.config/hadolint.yaml:ro" hadolint/hadolint:v2.12.0 < Dockerfile
docker run --rm -v "$PWD:/mnt:ro" -w /mnt koalaman/shellcheck:v0.10.0 docker/*.sh scripts/*.sh tests/*.sh
docker run --rm -v "$PWD:/src:ro" -w /src ghcr.io/astral-sh/ruff:0.8.4 check --no-cache docker/
docker run --rm -v "$PWD:/repo:ro" -w /repo rhysd/actionlint:1.7.7 -no-color
```

## License

The files in this repository are licensed under the [GNU General Public License v3.0](LICENSE) (`GPL-3.0-only`). Published images also include the proprietary IDrive for Linux client downloaded during the build and subject to IDrive's terms.
