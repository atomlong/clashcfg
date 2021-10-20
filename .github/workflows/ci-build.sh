#!/bin/bash

# Github Action Continuous Integration for ArchLinuxArm
# Author: Atom Long <atom.long@hotmail.com>

# Enable colors
if [[ -t 1 ]]; then
    normal='\e[0m'
    red='\e[1;31m'
    green='\e[1;32m'
    cyan='\e[1;36m'
fi

# Basic status function
_status() {
    local type="${1}"
    local status="${package:+${package}: }${2}"
    local items=("${@:3}")
    case "${type}" in
        failure) local -n nameref_color='red';   title='[ARCH CI] FAILURE:' ;;
        success) local -n nameref_color='green'; title='[ARCH CI] SUCCESS:' ;;
        message) local -n nameref_color='cyan';  title='[ARCH CI]'
    esac
    printf "\n${nameref_color}${title}${normal} ${status}\n\n"
    printf "${items:+\t%s\n}" "${items:+${items[@]}}"
}

# Run command with status
execute(){
    local status="${1}"
    local command="${2}"
    local arguments=("${@:3}")
	[ -n "${package}" ] && pushd ${package}
    message "${status}"
    if [[ "${command}" != *:* ]]
        then ${command} ${arguments[@]}
        else ${command%%:*} | ${command#*:} ${arguments[@]}
    fi || failure "${status} failed"
    [ -n "${package}" ] && popd
}

# Status functions
failure() { local status="${1}"; local items=("${@:2}"); _status failure "${status}." "${items[@]}"; return 1; }
success() { local status="${1}"; local items=("${@:2}"); _status success "${status}." "${items[@]}"; return 0; }
message() { local status="${1}"; local items=("${@:2}"); _status message "${status}"  "${items[@]}"; }

# Add custom repositories to pacman
add_custom_repos()
{
[ -n "${CUSTOM_REPOS}" ] || { echo "You must set CUSTOM_REPOS firstly."; return 1; }
local repos=(${CUSTOM_REPOS//,/ })
local repo name err i
for repo in ${repos[@]}; do
name=$(sed -n -r 's/\[(\w+)\].*/\1/p' <<< ${repo})
[ -n "${name}" ] || continue
[ -z $(sed -rn "/^\[${name}]\s*$/p" /etc/pacman.conf) ] || continue
cp -vf /etc/pacman.conf{,.orig}
sed -r 's/]/&\nServer = /' <<< ${repo} >> /etc/pacman.conf
sed -i -r 's/^(SigLevel\s*=\s*).*/\1Never/' /etc/pacman.conf
for ((i=0; i<5; i++)); do
err=$(
LANG=en_US.UTF-8 pacman --sync --refresh --needed --noconfirm --disable-download-timeout ${name}-keyring 2>&1 | tee /dev/stderr | sed -n "/error: target not found: ${name}-keyring/p"
exit ${PIPESTATUS}
)
[ $? == 0 ] && break
[ -n "${err}" ] && break
done
[ -z "${err}" ] && name="" || name="SigLevel = Never\n"
mv -vf /etc/pacman.conf{.orig,}
sed -r "s/]/&\n${name}Server = /" <<< ${repo} >> /etc/pacman.conf
done
}

# Enable multilib repository
enable_multilib_repo()
{
[ "${PACMAN_ARCH}" == "x86_64" ] || [ "${PACMAN_ARCH}" == "i686" ] || return 0
[ -z $(sed -rn "/^\[multilib]\s*$/p" /etc/pacman.conf) ] || return 0
printf "[multilib]\nInclude = /etc/pacman.d/mirrorlist\n"  >> /etc/pacman.conf
}

# Add old packages repository
add_archive_repo()
{
[ "${PACMAN_ARCH}" == "x86_64" ] || [ "${PACMAN_ARCH}" == "i686" ] || return 0
local archive_repo='https://archive.archlinux.org/repos/month/$repo/os/$arch'
local archive_repo_sed archive_repo_sed_date
local i d

for ((i=1; i<=365; i++)); do
d=$(date -d "-${i} day" '+%Y/%m/%d')
archive_repo_sed_date=$(sed "s|month|${d}|" <<< "${archive_repo}")
archive_repo_sed="${archive_repo_sed_date//\//\\/}"
archive_repo_sed=${archive_repo_sed//$/\\$}
[ -z $(sed -rn "/^Server = ${archive_repo_sed}/p" /etc/pacman.d/mirrorlist) ] && \
printf "Server = ${archive_repo_sed_date}\n" >> /etc/pacman.d/mirrorlist
done
}

# Build clash config file
build_clash()
{
[ -f source.txt ] || { echo "No source.txt file"; exit 1; }
systemctl.py is-active subconverter || systemctl.py start subconverter || { echo "Failed to start subconverter"; exit 1; }
local conv_root=$(dirname $(readlink -f $(which subconverter)))
local mcp=$(grep -Po '^\s*managed_config_prefix:\s*"\K[^"]+' ${conv_root}/pref.yml)
local URL=$(echo $(cat source.txt) | sed -r 's/\s+/|/g' | tr -d '\n' | urlencode)
local SUB="${mcp}/sub?target=clash&url=${URL}"
mkdir -pv ${ARTIFACTS_PATH}
curl "${SUB}" -o ${ARTIFACTS_PATH}/config.yml
}

# deploy artifacts
deploy_artifacts()
{
[ -n "${DEPLOY_PATH}" ] || { echo "You must set DEPLOY_PATH firstly."; return 1; }
[ -d ${ARTIFACTS_PATH} ] && [ "$(ls -A ${ARTIFACTS_PATH})" ] || { echo "No artifacts to deploy."; return 1; }
echo "Uploading new files to remote server ..."
rclone copy ${ARTIFACTS_PATH} ${DEPLOY_PATH} --copy-links
}

# create mail message
create_mail_message()
{
local message

[ "${1}" ] && message+="<p>${1}<p>"

[ -n "${message}" ] && {
message+="<p>Architecture: ${PACMAN_ARCH}</p>"
message+="<p>Build Number: ${CI_BUILD_NUMBER}</p>"
echo ::set-output name=message::${message}
}

return 0
}

# Run from here
cd ${CI_BUILD_DIR}
message 'Install build environment.'
export PACMAN_ARCH=$(sed -nr 's|^CARCH=\"(\w+).*|\1|p' /etc/makepkg.conf)
export ARTIFACTS_PATH=artifacts
[ -z "${DEPLOY_PATH}" ] && { echo "Environment variable 'DEPLOY_PATH' is required."; exit 1; }
[[ ${DEPLOY_PATH} =~ '$' ]] && eval export DEPLOY_PATH=${DEPLOY_PATH}
[ -z "${RCLONE_CONF}" ] && { echo "Environment variable 'RCLONE_CONF' is required."; exit 1; }
[ -z "${CUSTOM_REPOS}" ] || {
CUSTOM_REPOS=$(sed -e 's/$arch\b/\\$arch/g' -e 's/$repo\b/\\$repo/g' <<< ${CUSTOM_REPOS})
[[ ${CUSTOM_REPOS} =~ '$' ]] && eval export CUSTOM_REPOS=${CUSTOM_REPOS}
add_custom_repos
}
enable_multilib_repo
add_archive_repo

for (( i=0; i<5; i++ )); do
pacman --sync --refresh --sysupgrade --needed --noconfirm --disable-download-timeout \
	base-devel \
	rclone \
	subconverter-bin \
	urlencode \
	docker-systemctl-replacement-git \
	&& break
done || {
create_mail_message "Failed to install build environment."
failure "Cannot install all required packages."
exit 1
}

getent group http &>/dev/null || groupadd -g 33 http
getent passwd http &>/dev/null || useradd -m -u 33 http -s "/usr/bin/nologin" -g "http" -d "/srv/http"

RCLONE_CONFIG_PATH=$(rclone config file | tail -n1)
mkdir -pv $(dirname ${RCLONE_CONFIG_PATH})
[ $(awk 'END{print NR}' <<< "${RCLONE_CONF}") == 1 ] &&
base64 --decode <<< "${RCLONE_CONF}" > ${RCLONE_CONFIG_PATH} ||
printf "${RCLONE_CONF}" > ${RCLONE_CONFIG_PATH}

success 'The build environment is ready successfully.'
# Build
execute 'Building config file' build_clash
success 'Config file built successfully'
execute "Deploying artifacts" deploy_artifacts
create_mail_message
success 'All artifacts have been deployed successfully'
