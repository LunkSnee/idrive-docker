# idrive-docker
Run IDrive Linux Client in a docker container

GitHub: https://github.com/LunkSnee/idrive-docker

## Requirements
- Docker installed
- optional: docker-compose 
- IDrive account

## Build image
Build from the repository root:
```shell
docker build -t idrive-docker:latest .
```
The image leaves out IDrive's optional Cloud Drive component (~60 MB), which backups do not
need. To keep it: `docker build --build-arg INCLUDE_CLOUD_DRIVE=true -t idrive-docker:latest .`

Docker caches the downloaded installer, and the default download link never changes, so a
plain rebuild keeps the IDrive version it downloaded first. Add `--no-cache` to pick up a
new IDrive release.
Image is tagged `idrive-docker:latest`. The image is available on GHCR. Thx to @araines, the image gets also tagged with the iDrive client version.
- `ghcr.io/lunksnee/idrive-docker:latest`
- `ghcr.io/lunksnee/idrive-docker:<version>`, e.g. `:3.17.1`
- `ghcr.io/lunksnee/idrive-docker:<version>-r<N>`, e.g. `:3.17.1-r2`

### Which tag to use
| Tag | Moves? | Use it when |
|-----|--------|-------------|
| `3.17.1-r2` | Never | You want a fixed, known build. Best for unattended backups. |
| `3.17.1` | To the newest `-r<N>` build of that IDrive version | You want image fixes but not a new IDrive version. |
| `latest` | To a new IDrive version once it has been public for 7 days | You want new IDrive versions automatically, after a short wait. |

Every build gets a new `-r<N>` (starting at `r1` for each IDrive version) and a
matching [GitHub Release](../../releases) saying why it was built. Version tags are
published as soon as a new iDrive release is built; `:latest` is held back until a
release has been public for `LATEST_MIN_AGE_DAYS` (7 by default, set in
`.github/workflows/build-and-publish.yml`), so a bad iDrive release does not reach
`:latest` users on day one.

## Run container with docker
```shell
docker volume create idrive
docker run -d --name idrive -v idrive:/opt/IDriveForLinux/idriveIt \
           -v /path/to/backup:/source/1:ro -e TZ="Etc/UTC" \
           ghcr.io/lunksnee/idrive-docker:latest
```
Data to be backuped should be located in `/path/to/backup`. It is mapped to `/source/1` inside the container. You can specify more mappings like this to backup different folders (e.g.: `-v /path/to/anotherbackup:/source/2`). In the IDrive backup configuration you then only have to specify `/source` as backup source.

### Optional: Run with bind mounts instead of docker volumes
```shell
USERNAME=<myUserName>                              # adapt this to your needs
CONFIG_PATH=/home/$USERNAME/docker/idrive/config   # adapt this to your needs
mkdir -p $CONFIG_PATH
touch $CONFIG_PATH/idrivecrontab.json
docker run -d --name idrive \
           -v $CONFIG_PATH:/opt/IDriveForLinux/idriveIt \
           -v /path/to/backup:/source/1:ro \
           -e TZ="Etc/UTC" \
           ghcr.io/lunksnee/idrive-docker:latest
```

## Build (optional)  & Run with docker-compose - [compose.yaml](compose.yaml)
```shell
docker compose build idrive
docker compose up -d
```
To use a bind mount for the config instead of the named volume, swap the two
`/opt/IDriveForLinux/idriveIt` lines in `compose.yaml` and adjust the `/path/to/config` mapping.

## Tasks after first start
You have to login to your IDrive account after first start.
```
docker exec -it idrive idrive --account-setting
```
Now you login and specify the basic settings. For me this worked best:
- `1) Login using IDrive credentials`
  - `Enter your IDrive username:`
  - `Enter your IDrive password:`
- `1) Create new Backup Location`
  - `Enter your Backup Location` - enter a name - do no keep empty

For more information and additional `idrive` parameters have a look at the [IDrive documentation](https://www.idrive.com/readme).
The login and settings are stored persistent in the volume or the bind mounts.

## Backup configuration
The configuration and operation of backup and restore can be done in the IDrive GUI. Help can be found on the [IDrive FAQs](https://www.idrive.com/faq_linux#linuxWeb2) for Linux.

__WARNING:__ Please take a note on your schedules, as they will be deleted in the next steps.
- Login
`Configuring the same user profile with current path will terminate and delete all the existing scheduled jobs. Do you want to continue (y/n)?: y`
- Backup content and definitions will keep, but you have to recreate your schedules.

## The config volume
`/opt/IDriveForLinux/idriveIt` holds everything IDrive keeps: the login (`cache/idriveuser.txt`),
the schedule (`idrivecrontab.json`), and per account the settings, saved password, backup set,
excludes and job logs (`user_profile/root/<account>/`). Mount the whole folder, as one named
volume (as `compose.yaml` does) or a host folder; mounting only part of it loses the login or
the schedule. Without a mount Docker uses an anonymous volume, which `docker compose down` or
`docker rm -v` throws away; the container warns about that at start. (The `idevsutil*`
programs in it come from the image and are refreshed at every start.)

## Staying logged in across restarts and upgrades
IDrive logs the account out when it believes the machine changed, and some of what it checks
changes routinely in a container. At every start, before IDrive runs,
[`docker/idrive-init.py`](docker/idrive-init.py) `prepare` fixes that up:

- **Boot time:** IDrive saves the host's boot time (`UPTIME`) and logs out (`dashboard_uptime`)
  when it differs, for example after a host reboot. The check only applies to accounts that
  IDrive's servers have not moved to its newer WebSocket remote management (`RMWS` other than
  `yes`; IDrive sets this at login). The current boot time is written first, so it matches.
- **Self-update off:** IDrive's own update logs the account out afterwards and would patch the
  container rather than the image, so it is switched off. New IDrive versions arrive as new images.
- **Version and install markers:** the image's IDrive version is recorded as installed, IDrive's
  "update available" marker is cleared, and its "fresh install" marker (`inst.track`) is not
  restored on a volume that is already set up (it makes `--account-setting` treat the account
  as new and delete its schedules).
- **Transfer programs and stale locks:** the `idevsutil*` programs in the volume are refreshed
  to match the image, missing default files are restored, and lock files from an unclean stop
  are removed.

`docker ps` shows `(healthy)` when IDrive's service runs and, once an account is set up, it is
logged in, its saved-password files exist and its schedule is active. Checking only that the
service runs is not enough: it keeps running after a logout, while backups stop. To see why it is
unhealthy, run `docker exec idrive idrive-init.py healthcheck` (it prints nothing when healthy).

## Timezone
Be advised, that the containers timezone is UTC and so are the backup times and the log entries. Adapt the `TZ` environment variable to your timezone to have local time in place.


## Development
Every pull request that changes the image is built for `amd64` and `arm64` and checked
with the offline smoke test before anything is published. Run it against a local build:
```shell
docker build -t idrive-docker:local .
./tests/smoke-test.sh idrive-docker:local
```

The `Lint` workflow checks every change. Run the same checks locally (only Docker needed):
```shell
docker run --rm -i -v "$PWD/.hadolint.yaml:/.config/hadolint.yaml:ro" hadolint/hadolint:v2.12.0 < Dockerfile
docker run --rm -v "$PWD:/mnt:ro" -w /mnt koalaman/shellcheck:v0.10.0 docker/*.sh scripts/*.sh tests/*.sh
docker run --rm -v "$PWD:/src:ro" -w /src ghcr.io/astral-sh/ruff:0.8.4 check --no-cache docker/
docker run --rm -v "$PWD:/repo:ro" -w /repo rhysd/actionlint:1.7.7
```
