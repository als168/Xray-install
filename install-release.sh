#!/usr/bin/env bash

DAT_PATH=${DAT_PATH:-/usr/local/share/xray}
JSON_PATH=${JSON_PATH:-/usr/local/etc/xray}

if [[ -f '/etc/init.d/xray' ]] && [[ -f '/usr/local/bin/xray' ]]; then
  XRAY_IS_INSTALLED_BEFORE_RUNNING_SCRIPT=1
else
  XRAY_IS_INSTALLED_BEFORE_RUNNING_SCRIPT=0
fi

CURRENT_VERSION=''
RELEASE_LATEST=''
PRE_RELEASE_LATEST=''
INSTALL_VERSION=''
INSTALL='0'
INSTALL_GEODATA='0'
REMOVE='0'
HELP='0'
CHECK='0'
FORCE='0'
BETA='0'
INSTALL_USER=''
NO_GEODATA='0'
NO_LOGFILES='0'
LOGROTATE='0'
N_UP_SERVICE='0'
REINSTALL='0'
SPECIFIED_VERSION=''
LOCAL_FILE=''
PROXY=''
PURGE='0'

curl() {
  $(type -P curl) -L -q --retry 5 --retry-delay 10 --retry-max-time 60 "$@"
}

check_if_running_as_root() {
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

  if [[ -f /.dockerenv ]] || grep -q 'docker\|lxc' /proc/1/cgroup && [[ "$(type -P rc-service)" ]]; then
    true
  elif [[ -d /run/openrc ]] || grep -q openrc <(ls -l /sbin/init); then
    true
  else
    echo "error: Only Linux distributions using OpenRC are supported."
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
          echo "error: Please specify the install user."
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
        if ! grep -qE '\b([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]\b' <<< "$2"; then
          echo "error: Wrong format of time, it should be in the format of 12:34:56."
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

  if ((INSTALL + INSTALL_GEODATA + HELP + CHECK + REMOVE == 0)); then
    INSTALL='1'
  elif ((INSTALL + INSTALL_GEODATA + HELP + CHECK + REMOVE > 1)); then
    echo 'You can only choose one action.'
    exit 1
  fi

  if [[ "$INSTALL" -eq '1' ]] && ((temp_version + local_install + REINSTALL > 1)); then
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
  echo "Installing required packages..."
  $PACKAGE_MANAGEMENT_INSTALL xray curl jq tar
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
    RELEASE_LATEST=$(curl -sL 'https://api.github.com/repos/XTLS/Xray-core/releases/latest' | jq -r '.tag_name')
  fi
}

download_xray() {
  local download_link
  download_link="https://github.com/XTLS/Xray-core/releases/download/${INSTALL_VERSION}/Xray-linux-${MACHINE}.zip"

  echo "Downloading Xray..."
  curl -L -o "/tmp/xray.zip" "$download_link"

  echo "Verifying download..."
  curl -sL "https://github.com/XTLS/Xray-core/releases/download/${INSTALL_VERSION}/Xray-linux-${MACHINE}.zip.sha256sum" -o "/tmp/xray.zip.sha256sum"
  cd /tmp && sha256sum -c xray.zip.sha256sum || exit 1
  unzip -o xray.zip -d /usr/local/bin/ || exit 1
  rm -f /tmp/xray.zip /tmp/xray.zip.sha256sum
}

install_xray() {
  get_latest_version
  if [[ -z "$INSTALL_VERSION" ]]; then
    INSTALL_VERSION="$RELEASE_LATEST"
  fi
  if [[ "$CURRENT_VERSION" != "$INSTALL_VERSION" ]]; then
    download_xray
    install_startup_service_file
  else
    echo "Xray is already the latest version."
  fi
}

install_startup_service_file() {
  cat <<EOF > /etc/init.d/xray
#!/sbin/openrc-run

description="Xray - A platform for building proxies to bypass network restrictions."
command="/usr/local/bin/xray"
command_args="-c /usr/local/etc/xray/config.json"
command_user="nobody:nogroup"
pidfile="/run/xray.pid"

depend() {
  after networking
}

EOF

  chmod +x /etc/init.d/xray
  rc-update add xray default
}

start_xray() {
  echo "Starting Xray..."
  rc-service xray start
}

stop_xray() {
  echo "Stopping Xray..."
  rc-service xray stop
}

install_with_logrotate() {
  cat <<EOF > /etc/logrotate.d/xray
/usr/local/etc/xray/*.log {
  daily
  missingok
  rotate 14
  compress
  notifempty
  copytruncate
  delaycompress
  postrotate
    rc-service xray reload > /dev/null 2>/dev/null || true
  endscript
}
EOF
}

main() {
  check_if_running_as_root
  identify_the_operating_system_and_architecture
  judgment_parameters

  if [[ "$REMOVE" -eq '1' ]]; then
    stop_xray
    rc-update del xray default
    rm -f /etc/init.d/xray
    rm -rf /usr/local/bin/xray /usr/local/etc/xray /usr/local/share/xray
    echo "Xray has been removed."
    exit 0
  fi

  if [[ "$HELP" -eq '1' ]]; then
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  install                Install Xray."
    echo "  remove                 Remove Xray."
    echo "  check                  Check for updates."
    echo "  --without-geodata      Install without geodata."
    echo "  --without-logfiles     Install without logrotate."
    echo "  --version VERSION      Install a specific version."
    echo "  --local FILE           Install from a local file."
    echo "  --proxy PROXY          Use a proxy server."
    echo "  --reinstall            Reinstall Xray."
    echo "  --logrotate TIME       Configure logrotate with a specified time."
    echo "  --purge                Purge all Xray data."
    echo "  --help                 Show this help message."
    exit 0
  fi

  if [[ "$CHECK" -eq '1' ]]; then
    get_current_version
    get_latest_version
    if [[ "$CURRENT_VERSION" != "$RELEASE_LATEST" ]]; then
      echo "A new version of Xray is available: $RELEASE_LATEST"
    else
      echo "Xray is up to date."
    fi
    exit 0
  fi

  if [[ "$INSTALL" -eq '1' ]]; then
    install_software
    get_current_version
    install_xray
    install_with_logrotate
    start_xray
  fi
}

main "$@"
