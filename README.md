# idrive-docker
Run IDrive Linux Client in a docker container

GitHub: https://github.com/LunkSnee/idrive-docker

## Requirements
- Docker installed
- optional: docker-compose 
- IDrive account

## Build image
```shell
docker build -t idrive-docker:latest .
```
Image is tagged `idrive-docker:latest`. The image is available on GHCR. Thx to @araines, the image gets also tagged with the iDrive client version.
- `ghcr.io/lunksnee/idrive-docker:latest`
- `ghcr.io/lunksnee/idrive-docker:version`

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

## Build (optional)  & Run with docker-compose - [docker-compose.yml](/LunkSnee/idrive-docker/blob/main/docker-compose.yml)
```shell
docker compose build idrive
docker compose up -d
```

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

## Timezone
Be advised, that the containers timezone is UTC and so are the backup times and the log entries. Adapt the `TZ` environment variable to your timezone to have local time in place.

