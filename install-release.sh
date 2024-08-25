#!/usr/bin/env bash

# The files installed by the script conform to the Filesystem Hierarchy Standard:
# https://wiki.linuxfoundation.org/lsb/fhs

# The URL of the script project is:
# https://github.com/XTLS/Xray-install

# The URL of the script is:
# https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh

# If the script executes incorrectly, go to:
# https://github.com/XTLS/Xray-install/issues

# You can set this variable whatever you want in shell session right before running this script by issuing:
# export DAT_PATH='/usr/local/share/xray'
DAT_PATH=${DAT_PATH:-/usr/local/share/xray}

# You can set this variable whatever you want in shell session right before running this script by issuing:
# export JSON_PATH='/usr/local/etc/xray'
JSON_PATH=${JSON_PATH:-/usr/local/etc/xray}

# Set this variable only if you are starting xray with multiple configuration files:
# export JSONS_PATH='/usr/local/etc/xray'

# Set this variable only if you want this script to check all the systemd unit file:
# export check_all_service_files='yes'

# Gobal verbals

if [[ -f '/etc/systemd/system/xray.service' ]] && [[ -f '/usr/local/bin/xray' ]]; then
  XRAY_IS_INSTALLED_BEFORE_RUNNING_SCRIPT=1
else
  XRAY_IS_INSTALLED_BEFORE_RUNNING_SCRIPT=0
fi

# Xray current version
CURRENT_VERSION=''

# Xray latest release version
RELEASE_LATEST=''

# Xray latest prerelease/release version
PRE_RELEASE_LATEST=''

# Xray version will be installed
INSTALL_VERSION=''

# install
INSTALL='0'

# install-geodata
INSTALL_GEODATA='0'

# remove
REMOVE='0'

# help
HELP='0'

# check
CHECK='0'

# --force
FORCE='0'

# --beta
BETA='0'

# --install-user ?
INSTALL_USER=''

# --without-geodata
NO_GEODATA='0'

# --without-logfiles
NO_LOGFILES='0'

# --logrotate
LOGROTATE='0'

# --no-update-service
N_UP_SERVICE='0'

# --reinstall
REINSTALL='0'

# --version ?
SPECIFIED_VERSION=''

# --local ?
LOCAL_FILE=''

# --proxy ?
PROXY=''

# --purge
PURGE='0'

curl() {
  $(type -P curl) -L -q --retry 5 --retry-delay 10 --retry-max-time 60 "$@"
}

systemd_cat_config() {
  if systemd-analyze --help | grep -qw 'cat-config'; then
    systemd-analyze --no-pager cat-config "$@"
    echo
  else
    echo "${aoi}~~~~~~~~~~~~~~~~"
    cat "$@" "$1".d/*
    echo "${aoi}~~~~~~~~~~~~~~~~"
    echo "${red}warning: ${green}The systemd version on the current operating system is too low."
    echo "${red}warning: ${green}Please consider upgrading systemd or the operating system.${reset}"
    echo
  fi
}

check_if_running_as_root() {
  # If you want to run as another user, please modify $EUID to be owned by this user
  if [[ "$EUID" -ne '0' ]]; then
    echo "error: You must run this script as root!"
    exit 1
  fi
}

identify_the_operating_system_and_architecture() {
  if [[ "$(uname)" != 'Linux' ]]; then
    echo "error: This operating system is not supported."
    exit 1
  fi
  case "$(uname -m)" in
    'i386' | 'i686')
      MACHINE='32'
      ;;
    'amd64' | 'x86_64')
      MACHINE='64'
      ;;
    'armv5tel')
      MACHINE='arm32-v5'
      ;;
    'armv6l')
      MACHINE='arm32-v6'
      grep Features /proc/cpuinfo | grep -qw 'vfp' || MACHINE='arm32-v5'
      ;;
    'armv7' | 'armv7l')
      MACHINE='arm32-v7a'
      grep Features /proc/cpuinfo | grep -qw 'vfp' || MACHINE='arm32-v5'
      ;;
    'armv8' | 'aarch64')
      MACHINE='arm64-v8a'
      ;;
    'mips')
      MACHINE='mips32'
      ;;
    'mipsle')
      MACHINE='mips32le'
      ;;
    'mips64')
      MACHINE='mips64'
      lscpu | grep -q "Little Endian" && MACHINE='mips64le'
      ;;
    'mips64le')
      MACHINE='mips64le'
      ;;
    'ppc64')
      MACHINE='ppc64'
      ;;
    'ppc64le')
      MACHINE='ppc64le'
      ;;
    'riscv64')
      MACHINE='riscv64'
      ;;
    's390x')
      MACHINE='s390x'
      ;;
    *)
      echo "error: The architecture is not supported."
      exit 1
      ;;
  esac
  if [[ ! -f '/etc/os-release' ]]; then
    echo "error: Don't use outdated Linux distributions."
    exit 1
  fi
  if [[ -f /.dockerenv ]] || grep -q 'docker\|lxc' /proc/1/cgroup && [[ "$(type -P systemctl)" ]]; then
    true
  elif [[ -d /run/systemd/system ]] || grep -q systemd <(ls -l /sbin/init); then
    true
  else
    echo "error: Only Linux distributions using systemd are supported."
    exit 1
  fi
  if [[ "$(type -P apk)" ]]; then
    PACKAGE_MANAGEMENT_INSTALL='apk add --no-cache'
    PACKAGE_MANAGEMENT_REMOVE='apk del'
    package_provide_tput='ncurses'
  else
    echo "error: The script does not support the package manager in this operating system."
    exit 1
  fi
}

## Demo function for processing parameters
judgment_parameters() {
  local local_install='0'
  local temp_version='0'
  while [[ "$#" -gt '0' ]]; do
    case "$1" in
      'install')
        INSTALL='1'
        ;;
      'install-geodata')
        INSTALL_GEODATA='1'
        ;;
      'remove')
        REMOVE='1'
        ;;
      'help')
        HELP='1'
        ;;
      'check')
        CHECK='1'
        ;;
      '--without-geodata')
        NO_GEODATA='1'
        ;;
      '--without-logfiles')
        NO_LOGFILES='1'
        ;;
      '--purge')
        PURGE='1'
        ;;
      '--version')
        if [[ -z "$2" ]]; then
          echo "error: Please specify the correct version."
          exit 1
        fi
        temp_version='1'
        SPECIFIED_VERSION="$2"
        shift
        ;;
      '-f' | '--force')
        FORCE='1'
        ;;
      '--beta')
        BETA='1'
        ;;
      '-l' | '--local')
        local_install='1'
        if [[ -z "$2" ]]; then
          echo "error: Please specify the correct local file."
          exit 1
        fi
        LOCAL_FILE="$2"
        shift
        ;;
      '-p' | '--proxy')
        if [[ -z "$2" ]]; then
          echo "error: Please specify the proxy server address."
          exit 1
        fi
        PROXY="$2"
        shift
        ;;
      '-u' | '--install-user')
        if [[ -z "$2" ]]; then
          echo "error: Please specify the install user.}"
          exit 1
        fi
        INSTALL_USER="$2"
        shift
        ;;
      '--reinstall')
        REINSTALL='1'
        ;;
      '--no-update-service')
        N_UP_SERVICE='1'
        ;;
      '--logrotate')
        if ! grep -qE '\b([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]\b' <<< "$2";then
          echo "error: Wrong format of time, it should be in the format of 12:34:56, under 10:00:00 should be start with 0, e.g. 01:23:45."
          exit 1
        fi
        LOGROTATE='1'
        LOGROTATE_TIME="$2"
        shift
        ;;
      *)
        echo "$0: unknown option -- -"
        exit 1
        ;;
    esac
    shift
  done
  if ((INSTALL+INSTALL_GEODATA+HELP+CHECK+REMOVE==0)); then
    INSTALL='1'
  elif ((INSTALL+INSTALL_GEODATA+HELP+CHECK+REMOVE>1)); then
    echo 'You can only choose one action.'
    exit 1
  fi
  if [[ "$INSTALL" -eq '1' ]] && ((temp_version+local_install+REINSTALL>1)); then
    echo 'The --version and --local options are mutually exclusive.'
    exit 1
  fi
  if [[ "$INSTALL" -eq '1' ]] && [[ -n "$INSTALL_USER" ]] && ! id "$INSTALL_USER" &>/dev/null; then
    echo "error: Install user $INSTALL_USER does not exist."
    exit 1
  fi
  if [[ "$INSTALL" -eq '1' ]] && [[ -z "$SPECIFIED_VERSION" && -n "$LOCAL_FILE" ]]; then
    echo 'When specifying --local, the --version option is not required.'
    exit 1
  fi
  if [[ "$REMOVE" -eq '1' ]] && [[ -n "$INSTALL_USER" ]] && ! id "$INSTALL_USER" &>/dev/null; then
    echo "error: Install user $INSTALL_USER does not exist."
    exit 1
  fi
}

check_install_user() {
  if [[ -n "$INSTALL_USER" ]]; then
    if ! id "$INSTALL_USER" &>/dev/null; then
      echo "error: Install user $INSTALL_USER does not exist."
      exit 1
    fi
  fi
}

install_software() {
  if ! apk info xray &>/dev/null; then
    echo "Installing required packages..."
    apk add --no-cache xray
  fi
}

get_current_version() {
  if [[ -f "/usr/local/bin/xray" ]]; then
    CURRENT_VERSION=$(/usr/local/bin/xray --version 2>/dev/null | awk '{print $2}')
  fi
}

get_latest_version() {
  if [[ "$BETA" -eq '1' ]]; then
    RELEASE_LATEST=$(curl -sL 'https://api.github.com/repos/XTLS/Xray-core/releases?per_page=100' | jq -r '[.[] | select(.prerelease == true)] | .[0] | .tag_name')
  else
    RELEASE_LATEST=$(curl -sL 'https://api.github.com/repos/XTLS/Xray-core/releases/latest' | jq -r .tag_name)
  fi
}

version_gt() {
  local v1="$1"
  local v2="$2"
  [[ "$(printf '%s\n%s' "$v1" "$v2" | sort -V | head -n1)" == "$v2" ]]
}

download_xray() {
  local url="https://github.com/XTLS/Xray-core/releases/download/${INSTALL_VERSION}/xray-${MACHINE}-v${INSTALL_VERSION}.tar.gz"
  echo "Downloading Xray version $INSTALL_VERSION..."
  curl -L -o xray.tar.gz "$url"
  curl -L -o xray.tar.gz.sha256 "$url.sha256"
  sha256sum -c xray.tar.gz.sha256
}

decompression() {
  echo "Decompressing Xray..."
  tar -xzf xray.tar.gz -C /usr/local/bin
}

install_file() {
  cp -a xray /usr/local/bin/xray
}

install_xray() {
  if [[ "$INSTALL" -eq '1' ]]; then
    get_current_version
    get_latest_version
    if [[ "$FORCE" -eq '0' && "$(version_gt "$RELEASE_LATEST" "$CURRENT_VERSION")" == '1' ]]; then
      echo "Xray version $RELEASE_LATEST is available, installing..."
      INSTALL_VERSION="$RELEASE_LATEST"
      download_xray
      decompression
      install_file
    elif [[ "$FORCE" -eq '1' ]]; then
      echo "Forcing installation of Xray version $INSTALL_VERSION..."
      download_xray
      decompression
      install_file
    else
      echo "Xray is already up-to-date."
    fi
  fi
}

install_startup_service_file() {
  echo "Installing Xray startup service..."
  cat > /etc/systemd/system/xray.service <<- EOF
[Unit]
Description=Xray Service
Documentation=https://www.v2ray.com/
After=network.target

[Service]
ExecStart=/usr/local/bin/xray run -c /usr/local/etc/xray/config.json
Restart=on-failure
User=nobody
RestartSec=3
LimitNOFILE=4096

[Install]
WantedBy=multi-user.target
EOF
  systemctl enable xray
}

start_xray() {
  echo "Starting Xray..."
  systemctl start xray
}

stop_xray() {
  echo "Stopping Xray..."
  systemctl stop xray
}

install_with_logrotate() {
  if [[ "$LOGROTATE" -eq '1' ]]; then
    echo "Configuring logrotate for Xray logs..."
    cat > /etc/logrotate.d/xray <<- EOF
/var/log/xray/*.log {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    create 0640 root root
}
EOF
  fi
}

main() {
  check_if_running_as_root
  identify_the_operating_system_and_architecture
  judgment_parameters
  check_install_user
  install_software
  install_xray
  install_startup_service_file
  start_xray
  install_with_logrotate
}

main "$@"
