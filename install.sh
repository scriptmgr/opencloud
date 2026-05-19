#!/usr/bin/env sh
# shellcheck shell=sh
# - - - - - - - - - - - - - - - - - - - - - - - - -
##@Version           :  202605191054-git
# @@Author           :  Jason Hempstead
# @@Contact          :  git-admin@casjaysdev.pro
# @@License          :  MIT or LICENSE.md
# @@ReadME           :  install.sh --help | README.md
# @@Copyright        :  Copyright: (c) 2025 Jason Hempstead, Casjays Developments
# @@Created          :  Monday, May 19, 2025 10:54 EDT
# @@File             :  install.sh
# @@Description      :  Idempotent POSIX installer/updater for a full OpenCloud stack
# @@Changelog        :  Apply CasjaysDev script conventions; __functions; INSTALL_ globals; getopts
# @@TODO             :
# @@Other            :  Requires root or sudo; installs Docker Engine from official repos
# @@Resource         :  https://github.com/scriptmgr/opencloud
# @@Terminal App     :  no
# @@sudo/root        :  yes
# @@Template         :  shell/sh
# - - - - - - - - - - - - - - - - - - - - - - - - -
# shellcheck disable=SC1001,SC1003,SC1091,SC2001,SC2003,SC2016,SC2031,SC2034,SC2090,SC2115,SC2120,SC2155,SC2199,SC2229,SC2317,SC2329
# - - - - - - - - - - - - - - - - - - - - - - - - -
VERSION="202605191054-git"
# - - - - - - - - - - - - - - - - - - - - - - - - -
APPNAME="${0##*/}"
RUN_USER="${USER:-root}"
SET_UID="$(id -u)"
SCRIPT_SRC_DIR="$(dirname -- "$0")"
# - - - - - - - - - - - - - - - - - - - - - - - - -
set -eu
umask 027
# - - - - - - - - - - - - - - - - - - - - - - - - -

# Root check — must be root or able to sudo for package installation and
# writing to /opt (default install path). Fail early with a clear message
# rather than obscure permission errors mid-install.
if [ "$SET_UID" != "0" ] && ! command -v sudo >/dev/null 2>&1; then
  printf "[ERR ] This script requires root or sudo. Re-run as root or install sudo.\n" >&2
  exit 1
fi

# - - - - - - - - - - - - - - - - - - - - - - - - -
# Defaults
# - - - - - - - - - - - - - - - - - - - - - - - - -
INSTALL_PREFIX="/opt/opencloud"
INSTALL_ADMIN_USER="admin"
INSTALL_ADMIN_PASS=""
INSTALL_PORT="9200"
INSTALL_DOMAIN=""
INSTALL_SMTP_HOST="172.17.0.1"   # Docker bridge gateway on Linux
INSTALL_SMTP_PORT="25"
INSTALL_SMTP_SECURE="none"        # 'none', 'starttls', or 'ssltls'
INSTALL_SMTP_AUTH=""              # auth method (e.g. 'plain', 'login'); empty = none
INSTALL_SMTP_USER=""
INSTALL_SMTP_PASS=""
INSTALL_UPDATE_ONLY="false"
INSTALL_ENABLE_COLLAB="true"
INSTALL_COLLAB_EXPLICIT="false"   # true when --collab or --no-collab was passed explicitly
INSTALL_COLLABORA_ADMIN_USER="admin"
INSTALL_COLLABORA_ADMIN_PASS=""
INSTALL_OC_CONTAINER_UID_GID="1000:1000"
INSTALL_NETWORK_NAME="opencloud-net"

# - - - - - - - - - - - - - - - - - - - - - - - - -
# Helpers (POSIX)
# - - - - - - - - - - - - - - - - - - - - - - - - -
__log()  { printf "%s\n" "$*"; }
__info() { printf "[INFO] %s\n" "$*"; }
__warn() { printf "[WARN] %s\n" "$*" >&2; }
__err()  { printf "[ERR ] %s\n" "$*" >&2; }

__need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { __err "Missing required command: $1"; exit 1; }
}

# Generate a random 32-char alphanumeric secret; prefers openssl, falls back to /dev/urandom.
__rand_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32
  else
    dd if=/dev/urandom bs=1 count=48 2>/dev/null | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c 32
  fi
}

# Double-quote a value for safe inclusion in a .env file.
# Escapes embedded backslashes, double-quotes, and dollar-signs.
# Docker Compose expands $VAR inside double-quoted strings unless $ is escaped as \$.
__env_quote() {
  printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\$/\\$/g')"
}

__is_root() {
  [ "$SET_UID" = "0" ]
}

# Run a shell command as root (or via sudo).
# Pass the entire command as a single pre-quoted string.
__sudocmd() {
  if __is_root; then
    sh -c "$1"
  else
    __need_cmd sudo
    sudo sh -c "$1"
  fi
}

__has_systemd() {
  command -v systemctl >/dev/null 2>&1
}

__now_utc() { date -u +"%Y%m%dT%H%M%SZ"; }

# Derive a base domain from a potentially sub-domained hostname.
# cloud.example.com  → example.com   (strips leading label when 3+ labels present)
# example.com        → example.com   (unchanged)
# localhost          → localhost      (unchanged)
__infer_base_domain() {
  case "$1" in
    *.*.*)
      # Three or more labels: strip the first one.
      printf '%s' "${1#*.}"
      ;;
    *)
      printf '%s' "$1"
      ;;
  esac
}

# - - - - - - - - - - - - - - - - - - - - - - - - -
# Help and version
# - - - - - - - - - - - - - - - - - - - - - - - - -
__help() {
  cat <<EOF
OpenCloud Installer / Updater (POSIX sh)

Usage: sh ${APPNAME} [OPTIONS]

Options:
  --path DIR, --prefix DIR      Install root (default: /opt/opencloud)
  --admin-pass PASS             Admin password (default: random on first setup)
  --port N                      Host port to bind (default: 9200)
  --domain HOST                 Public hostname (sets OC_DOMAIN)
  --smtp-host HOST              SMTP relay host (default: 172.17.0.1)
  --smtp-port PORT              SMTP relay port (default: 25)
  --smtp-secure MODE            'none', 'starttls', or 'ssltls' (default: none)
  --smtp-auth METHOD            SMTP auth method, e.g. 'plain' or 'login' (default: none)
  --smtp-user USER              SMTP username (if auth enabled)
  --smtp-pass PASS              SMTP password (if auth enabled)
  --collab                      Enable Collabora document collaboration (default: on)
  --no-collab                   Disable Collabora document collaboration
  --collabora-admin-user NAME   Collabora admin username (default: admin)
  --collabora-admin-pass PASS   Collabora admin password (default: random)
  --network NAME                Docker network name (default: opencloud-net)
                                Created automatically if it does not exist.
                                Join your reverse proxy to this network to reach OpenCloud.
  --update                      Pull latest images and recreate (with backup)
  -h, --help                    Show this help
  -v, --version                 Show version and exit

Notes:
  OpenCloud admin username is always 'admin'.
  The admin password is applied ONCE at first startup; editing .env afterwards
  has no effect. Use the web UI to change it later.

  Collabora is enabled by default. Use --no-collab to disable it.
  Collabora subdomains are inferred from --domain automatically.
  If --domain is cloud.example.com the script configures:
    collabora.example.com  → port 9980
    wopiserver.example.com → port 9300
  Without --domain, collabora.localhost and wopiserver.localhost are used.
  Your reverse proxy must route both subdomains to the container ports.

  When --domain is empty or a single-label hostname (e.g. localhost, myserver),
  INSECURE=true and http:// URLs are used — suitable for local testing only.
EOF
}

__version() {
  printf '%s\n' "$VERSION"
}

# - - - - - - - - - - - - - - - - - - - - - - - - -
# Argument parsing (getopts with -: trick for long options)
# - - - - - - - - - - - - - - - - - - - - - - - - -
__parse_args() {
  OPTIND=1
  while getopts ":hvy-:" _opt; do
    case "${_opt}" in
      h) __help; exit 0 ;;
      v) __version; exit 0 ;;
      y) ;;  # kept for compatibility; script never prompts
      -)
        # For --flag value form: OPTARG is the flag name; value is at $OPTIND.
        case "${OPTARG}" in
          help)    __help; exit 0 ;;
          version) __version; exit 0 ;;

          path|prefix)
            _idx="$OPTIND"; OPTIND=$((OPTIND + 1))
            eval "_optval=\${${_idx}:-}"
            [ -z "${_optval:-}" ] && { __err "Option --${OPTARG} requires a value."; exit 1; }
            case "${_optval}" in -*) __err "Option --${OPTARG} requires a value (got flag '${_optval}' instead)."; exit 1 ;; esac
            INSTALL_PREFIX="${_optval}" ;;

          admin-pass)
            _idx="$OPTIND"; OPTIND=$((OPTIND + 1))
            eval "_optval=\${${_idx}:-}"
            [ -z "${_optval:-}" ] && { __err "Option --${OPTARG} requires a value."; exit 1; }
            case "${_optval}" in -*) __err "Option --${OPTARG} requires a value (got flag '${_optval}' instead)."; exit 1 ;; esac
            INSTALL_ADMIN_PASS="${_optval}" ;;

          port)
            _idx="$OPTIND"; OPTIND=$((OPTIND + 1))
            eval "_optval=\${${_idx}:-}"
            [ -z "${_optval:-}" ] && { __err "Option --${OPTARG} requires a value."; exit 1; }
            case "${_optval}" in -*) __err "Option --${OPTARG} requires a value (got flag '${_optval}' instead)."; exit 1 ;; esac
            INSTALL_PORT="${_optval}" ;;

          domain)
            _idx="$OPTIND"; OPTIND=$((OPTIND + 1))
            eval "_optval=\${${_idx}:-}"
            [ -z "${_optval:-}" ] && { __err "Option --${OPTARG} requires a value."; exit 1; }
            case "${_optval}" in -*) __err "Option --${OPTARG} requires a value (got flag '${_optval}' instead)."; exit 1 ;; esac
            INSTALL_DOMAIN="${_optval}" ;;

          smtp-host)
            _idx="$OPTIND"; OPTIND=$((OPTIND + 1))
            eval "_optval=\${${_idx}:-}"
            [ -z "${_optval:-}" ] && { __err "Option --${OPTARG} requires a value."; exit 1; }
            case "${_optval}" in -*) __err "Option --${OPTARG} requires a value (got flag '${_optval}' instead)."; exit 1 ;; esac
            INSTALL_SMTP_HOST="${_optval}" ;;

          smtp-port)
            _idx="$OPTIND"; OPTIND=$((OPTIND + 1))
            eval "_optval=\${${_idx}:-}"
            [ -z "${_optval:-}" ] && { __err "Option --${OPTARG} requires a value."; exit 1; }
            case "${_optval}" in -*) __err "Option --${OPTARG} requires a value (got flag '${_optval}' instead)."; exit 1 ;; esac
            INSTALL_SMTP_PORT="${_optval}" ;;

          smtp-secure)
            _idx="$OPTIND"; OPTIND=$((OPTIND + 1))
            eval "_optval=\${${_idx}:-}"
            [ -z "${_optval:-}" ] && { __err "Option --${OPTARG} requires a value."; exit 1; }
            case "${_optval}" in -*) __err "Option --${OPTARG} requires a value (got flag '${_optval}' instead)."; exit 1 ;; esac
            INSTALL_SMTP_SECURE="${_optval}" ;;

          smtp-auth)
            _idx="$OPTIND"; OPTIND=$((OPTIND + 1))
            eval "_optval=\${${_idx}:-}"
            [ -z "${_optval:-}" ] && { __err "Option --${OPTARG} requires a value."; exit 1; }
            case "${_optval}" in -*) __err "Option --${OPTARG} requires a value (got flag '${_optval}' instead)."; exit 1 ;; esac
            INSTALL_SMTP_AUTH="${_optval}" ;;

          smtp-user)
            _idx="$OPTIND"; OPTIND=$((OPTIND + 1))
            eval "_optval=\${${_idx}:-}"
            [ -z "${_optval:-}" ] && { __err "Option --${OPTARG} requires a value."; exit 1; }
            case "${_optval}" in -*) __err "Option --${OPTARG} requires a value (got flag '${_optval}' instead)."; exit 1 ;; esac
            INSTALL_SMTP_USER="${_optval}" ;;

          smtp-pass)
            _idx="$OPTIND"; OPTIND=$((OPTIND + 1))
            eval "_optval=\${${_idx}:-}"
            [ -z "${_optval:-}" ] && { __err "Option --${OPTARG} requires a value."; exit 1; }
            case "${_optval}" in -*) __err "Option --${OPTARG} requires a value (got flag '${_optval}' instead)."; exit 1 ;; esac
            INSTALL_SMTP_PASS="${_optval}" ;;

          collab)       INSTALL_ENABLE_COLLAB="true";  INSTALL_COLLAB_EXPLICIT="true" ;;
          no-collab)    INSTALL_ENABLE_COLLAB="false"; INSTALL_COLLAB_EXPLICIT="true" ;;

          collabora-admin-user)
            _idx="$OPTIND"; OPTIND=$((OPTIND + 1))
            eval "_optval=\${${_idx}:-}"
            [ -z "${_optval:-}" ] && { __err "Option --${OPTARG} requires a value."; exit 1; }
            case "${_optval}" in -*) __err "Option --${OPTARG} requires a value (got flag '${_optval}' instead)."; exit 1 ;; esac
            INSTALL_COLLABORA_ADMIN_USER="${_optval}" ;;

          collabora-admin-pass)
            _idx="$OPTIND"; OPTIND=$((OPTIND + 1))
            eval "_optval=\${${_idx}:-}"
            [ -z "${_optval:-}" ] && { __err "Option --${OPTARG} requires a value."; exit 1; }
            case "${_optval}" in -*) __err "Option --${OPTARG} requires a value (got flag '${_optval}' instead)."; exit 1 ;; esac
            INSTALL_COLLABORA_ADMIN_PASS="${_optval}" ;;

          network)
            _idx="$OPTIND"; OPTIND=$((OPTIND + 1))
            eval "_optval=\${${_idx}:-}"
            [ -z "${_optval:-}" ] && { __err "Option --${OPTARG} requires a value."; exit 1; }
            case "${_optval}" in -*) __err "Option --${OPTARG} requires a value (got flag '${_optval}' instead)."; exit 1 ;; esac
            INSTALL_NETWORK_NAME="${_optval}" ;;

          update)         INSTALL_UPDATE_ONLY="true" ;;
          yes|non-interactive) ;;  # kept for compatibility; script never prompts

          *) __err "Unknown option: --${OPTARG}"; exit 1 ;;
        esac ;;
      ?) __err "Unknown option: -${OPTARG}"; exit 1 ;;
    esac
  done
}

# - - - - - - - - - - - - - - - - - - - - - - - - -
# Parse arguments
# - - - - - - - - - - - - - - - - - - - - - - - - -
__parse_args "$@"

# - - - - - - - - - - - - - - - - - - - - - - - - -
# Post-parse validation and normalisation
# - - - - - - - - - - - - - - - - - - - - - - - - -

# Validate --port: must be a positive integer in range 1-65535.
case "$INSTALL_PORT" in
  *[!0-9]*|'')
    __err "--port must be a number between 1 and 65535 (got: '$INSTALL_PORT')."; exit 1 ;;
esac
if [ "$INSTALL_PORT" -lt 1 ] || [ "$INSTALL_PORT" -gt 65535 ]; then
  __err "--port must be between 1 and 65535 (got: $INSTALL_PORT)."; exit 1
fi

# Validate --smtp-port: same 1-65535 range check as --port.
case "$INSTALL_SMTP_PORT" in
  *[!0-9]*|'')
    __err "--smtp-port must be a number between 1 and 65535 (got: '$INSTALL_SMTP_PORT')."; exit 1 ;;
esac
if [ "$INSTALL_SMTP_PORT" -lt 1 ] || [ "$INSTALL_SMTP_PORT" -gt 65535 ]; then
  __err "--smtp-port must be between 1 and 65535 (got: $INSTALL_SMTP_PORT)."; exit 1
fi

# Normalise domain: lowercase only (trailing dot is rejected below — it causes
# issues in HTTP URLs and TLS SAN matching, so treat it as a typo).
if [ -n "$INSTALL_DOMAIN" ]; then
  INSTALL_DOMAIN="$(printf '%s' "$INSTALL_DOMAIN" | tr '[:upper:]' '[:lower:]')"
  # Reject spaces and shell metacharacters.
  case "$INSTALL_DOMAIN" in
    *' '*|*'	'*)
      __err "Invalid domain: must not contain spaces."; exit 1 ;;
  esac
  case "$INSTALL_DOMAIN" in
    *['$''!''`''#''&''('')''|''<''>''{''}'' ']*)
      __err "Invalid domain '$INSTALL_DOMAIN': shell metacharacters are not allowed."; exit 1 ;;
  esac
  # Allow only: letters, digits, hyphens, dots.
  _dom_check="$(printf '%s' "$INSTALL_DOMAIN" | tr -d 'A-Za-z0-9.-')"
  if [ -n "$_dom_check" ]; then
    __err "Invalid domain '$INSTALL_DOMAIN': only letters, digits, hyphens, and dots are allowed."; exit 1
  fi
  # Reject consecutive dots (empty labels, e.g. foo..bar.com).
  case "$INSTALL_DOMAIN" in
    *..*)
      __err "Invalid domain '$INSTALL_DOMAIN': consecutive dots (empty label) are not allowed."; exit 1 ;;
  esac
  # Reject leading or trailing hyphens in any label, and leading/trailing dots.
  # Patterns:  .*|*.  = domain starts/ends with a dot
  #            -*|*-  = first/last label starts/ends with a hyphen
  #            *-.*   = interior label ends with a hyphen (e.g. bad-.com)
  #            *.-*   = interior label starts with a hyphen (e.g. foo.-bar.com)
  case "$INSTALL_DOMAIN" in
    .*|*.)
      __err "Invalid domain '$INSTALL_DOMAIN': must not start or end with a dot."; exit 1 ;;
    -*|*-|*-.*|*.-*)
      __err "Invalid domain '$INSTALL_DOMAIN': must not start or end with a hyphen."; exit 1 ;;
  esac
fi

# No domain pre-flight needed for --collab: subdomains are inferred from INSTALL_DOMAIN
# (falling back to *.localhost), and the reverse proxy handles routing to the
# container ports regardless of whether a real domain is configured.

# - - - - - - - - - - - - - - - - - - - - - - - - -
# Directory layout (derived from INSTALL_PREFIX)
# - - - - - - - - - - - - - - - - - - - - - - - - -
INSTALL_COMPOSE_DIR="$INSTALL_PREFIX"
INSTALL_ENV_FILE="$INSTALL_COMPOSE_DIR/.env"
INSTALL_COMPOSE_FILE="$INSTALL_COMPOSE_DIR/compose.yaml"
INSTALL_CONFIG_DIR="$INSTALL_COMPOSE_DIR/config"
INSTALL_DATA_DIR="$INSTALL_COMPOSE_DIR/data"
INSTALL_BACKUP_DIR="$INSTALL_COMPOSE_DIR/backups"
INSTALL_ADMIN_OUT="$INSTALL_COMPOSE_DIR/admin.credentials"

mkdir -p "$INSTALL_CONFIG_DIR" "$INSTALL_DATA_DIR" "$INSTALL_BACKUP_DIR"

# OpenCloud runs as uid/gid 1000 inside the container; volumes must match.
chown 1000:1000 "$INSTALL_CONFIG_DIR" "$INSTALL_DATA_DIR" 2>/dev/null || \
  __warn "Could not chown config/data dirs to 1000:1000. Ensure the container user can write to them."

# - - - - - - - - - - - - - - - - - - - - - - - - -
# Package manager detection
# - - - - - - - - - - - - - - - - - - - - - - - - -
__detect_pm() {
  if [ -r /etc/os-release ]; then
    . /etc/os-release
    case "$ID" in
      debian|ubuntu|raspbian|linuxmint) echo "apt";    return ;;
      fedora)                           echo "dnf";    return ;;
      rhel|rocky|almalinux|centos)
        if command -v dnf >/dev/null 2>&1; then echo "dnf"; else echo "yum"; fi
        return ;;
      opensuse*|sles)                   echo "zypper"; return ;;
      arch|manjaro|endeavouros)         echo "pacman"; return ;;
    esac
  fi
  command -v apt-get >/dev/null 2>&1 && { echo apt;    return; }
  command -v dnf     >/dev/null 2>&1 && { echo dnf;    return; }
  command -v yum     >/dev/null 2>&1 && { echo yum;    return; }
  command -v zypper  >/dev/null 2>&1 && { echo zypper; return; }
  command -v pacman  >/dev/null 2>&1 && { echo pacman; return; }
  __err "Unsupported distribution (no known package manager)."; exit 1
}

# - - - - - - - - - - - - - - - - - - - - - - - - -
# Docker installation
# - - - - - - - - - - - - - - - - - - - - - - - - -
__install_docker_official() {
  _pm="$(__detect_pm)"
  __info "Detected package manager: $_pm"

  case "$_pm" in
    apt)
      __need_cmd apt-get
      __need_cmd gpg
      __sudocmd "apt-get update"
      __sudocmd "apt-get install -y ca-certificates curl gnupg lsb-release"
      mkdir -p /etc/apt/keyrings
      if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
        _distro_id="$(. /etc/os-release; echo "$ID")"
        curl -fsSL "https://download.docker.com/linux/${_distro_id}/gpg" | \
          gpg --dearmor > /tmp/opencloud-docker.gpg
        __sudocmd "install -m 0644 -o root -g root -D /tmp/opencloud-docker.gpg /etc/apt/keyrings/docker.gpg"
        rm -f /tmp/opencloud-docker.gpg
      fi
      _arch="$(dpkg --print-architecture)"
      _distro_id="$(. /etc/os-release; echo "$ID")"
      _codename="$(. /etc/os-release; echo "$VERSION_CODENAME")"
      printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/%s %s stable\n' \
        "$_arch" "$_distro_id" "$_codename" | \
        __sudocmd "tee /etc/apt/sources.list.d/docker.list >/dev/null"
      __sudocmd "apt-get update"
      __sudocmd "apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
      ;;
    dnf)
      __need_cmd dnf
      __sudocmd "dnf -y install dnf-plugins-core"
      _distro_id="$(. /etc/os-release; echo "$ID")"
      # Docker publishes repos for 'centos' and 'fedora' only.
      # AlmaLinux, Rocky, and other RHEL rebuilds must use the centos repo.
      case "$_distro_id" in
        fedora) _docker_repo_id="fedora" ;;
        *)      _docker_repo_id="centos" ;;
      esac
      __sudocmd "dnf config-manager --add-repo https://download.docker.com/linux/${_docker_repo_id}/docker-ce.repo"
      __sudocmd "dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
      ;;
    yum)
      __need_cmd yum
      __sudocmd "yum -y install yum-utils"
      __sudocmd "yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo"
      __sudocmd "yum -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || true"
      ;;
    zypper)
      __need_cmd zypper
      __sudocmd "zypper -n install ca-certificates curl gnupg2"
      _distro_id="$(. /etc/os-release; echo "$ID")"
      __sudocmd "zypper -n addrepo https://download.docker.com/linux/${_distro_id}/docker-ce.repo || true"
      __sudocmd "zypper -n refresh"
      __sudocmd "zypper -n install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
      ;;
    pacman)
      __need_cmd pacman
      __sudocmd "pacman -Sy --noconfirm docker docker-compose-plugin"
      ;;
    *)
      __err "Unsupported package manager: $_pm"; exit 1 ;;
  esac

  if __has_systemd; then
    __sudocmd "systemctl enable --now docker"
  else
    __warn "systemd not detected. Please start and enable the Docker daemon manually."
  fi
}

__ensure_network() {
  if docker network inspect -- "$INSTALL_NETWORK_NAME" >/dev/null 2>&1; then
    __info "Docker network '$INSTALL_NETWORK_NAME' already exists."
    return 0
  fi
  __info "Creating Docker network '$INSTALL_NETWORK_NAME'..."
  # Suppress and re-check: a parallel create or a stale external network that
  # inspect missed (rare but possible with bridge networks) would fail create
  # with "already exists". If create fails, verify the network is now reachable;
  # error only if it truly cannot be found.
  docker network create --driver bridge -- "$INSTALL_NETWORK_NAME" >/dev/null 2>&1 || true
  if ! docker network inspect -- "$INSTALL_NETWORK_NAME" >/dev/null 2>&1; then
    __err "Failed to create or find Docker network '$INSTALL_NETWORK_NAME'."
    exit 1
  fi
}

__ensure_docker() {
  if command -v docker >/dev/null 2>&1; then
    __info "Docker is present."
  else
    __info "Docker not found; installing from official repository..."
    __info "If automatic install fails, install docker-ce and docker-compose-plugin manually:"
    __info "  https://docs.docker.com/engine/install/"
    __install_docker_official
  fi
  if docker compose version >/dev/null 2>&1; then
    __info "Docker Compose v2 plugin present."
  else
    __err "Docker Compose v2 plugin missing. Install docker-compose-plugin and re-run."; exit 1
  fi
}

# - - - - - - - - - - - - - - - - - - - - - - - - -
# .env file (idempotent: written once only)
# - - - - - - - - - - - - - - - - - - - - - - - - -
__write_env_file() {
  if [ ! -s "$INSTALL_ENV_FILE" ]; then
    _admin_pass="${INSTALL_ADMIN_PASS:-$(__rand_secret)}"
    _collab_pass="${INSTALL_COLLABORA_ADMIN_PASS:-$(__rand_secret)}"

    # INSECURE: false for real multi-label domains (example.com, cloud.example.com).
    # true for empty, 'localhost', or any single-label hostname (no dot → no valid cert).
    if [ -z "$INSTALL_DOMAIN" ] || [ "${INSTALL_DOMAIN%%.*}" = "$INSTALL_DOMAIN" ]; then
      _insecure="true"
      _scheme="http"
    else
      _insecure="false"
      _scheme="https"
    fi

    # Infer Collabora subdomains from the base domain.
    _base_domain="$(__infer_base_domain "${INSTALL_DOMAIN:-localhost}")"
    _collabora_domain="collabora.${_base_domain}"
    _wopi_domain="wopiserver.${_base_domain}"

    # Build full URLs (scheme-aware) for collaboration services.
    _wopi_url="${_scheme}://${_wopi_domain}"
    _collabora_url="${_scheme}://${_collabora_domain}"

    # Quote credentials for safe inclusion in the .env file.
    _admin_pass_q="$(__env_quote "$_admin_pass")"
    _collab_pass_q="$(__env_quote "$_collab_pass")"
    _smtp_pass_q="$(__env_quote "$INSTALL_SMTP_PASS")"

    cat > "$INSTALL_ENV_FILE" <<EOF
# Autogenerated by install.sh on $(date -u)
# Safe to edit and re-run install.sh. Keep this file secure (mode 600).

COMPOSE_PROJECT_NAME=opencloud

# --- OpenCloud image ---
# Use opencloudeu/opencloud for stable releases.
OC_DOCKER_IMAGE=opencloudeu/opencloud-rolling
OC_DOCKER_TAG=latest
# Container runs as this uid:gid — volumes must be owned by the same ids.
OC_CONTAINER_UID_GID=$INSTALL_OC_CONTAINER_UID_GID

# --- Network ---
# Host port exposed by the reverse proxy.
OPENCLOUD_HTTP_PORT=$INSTALL_PORT
# Public domain name.
OC_DOMAIN=${INSTALL_DOMAIN:-localhost}
# Full URL that OpenCloud advertises to clients.
OC_URL=${_scheme}://${INSTALL_DOMAIN:-localhost}
# TLS is terminated by the external reverse proxy; OpenCloud speaks plain HTTP.
PROXY_TLS=false
# Set true only for local/self-signed setups (single-label hostnames, localhost).
INSECURE=$_insecure

# --- Admin credentials (applied on FIRST start only) ---
# To change later: use the web UI — editing this file has no effect.
INITIAL_ADMIN_PASSWORD=${_admin_pass_q}

# --- Demo users (never enable in production) ---
DEMO_USERS=false

# --- Logging ---
LOG_LEVEL=info
LOG_PRETTY=false
# Docker logging driver: local, json-file, syslog, journald, etc.
LOG_DRIVER=local

# --- Additional services ---
# 'notifications' enables SMTP email sending.
START_ADDITIONAL_SERVICES=notifications

# --- SMTP / email notifications ---
SMTP_HOST=$INSTALL_SMTP_HOST
SMTP_PORT=$INSTALL_SMTP_PORT
SMTP_SENDER=OpenCloud Notifications <notifications@${INSTALL_DOMAIN:-localhost}>
SMTP_USERNAME=$INSTALL_SMTP_USER
SMTP_PASSWORD=${_smtp_pass_q}
SMTP_AUTHENTICATION=$INSTALL_SMTP_AUTH
SMTP_TRANSPORT_ENCRYPTION=$INSTALL_SMTP_SECURE
SMTP_INSECURE=false

# --- Storage (leave empty to use Docker-managed named volumes) ---
OC_CONFIG_DIR=$INSTALL_CONFIG_DIR
OC_DATA_DIR=$INSTALL_DATA_DIR

# --- Docker network ---
# All OpenCloud containers join this network. Attach your reverse proxy to it.
OPENCLOUD_NETWORK=$INSTALL_NETWORK_NAME

# --- Collaboration (Collabora + WOPI) ---
# Subdomains are inferred from OC_DOMAIN at install time. Only used when
# the collaboration service is included in compose.yaml.
COLLABORA_DOMAIN=$_collabora_domain
WOPISERVER_DOMAIN=$_wopi_domain
# Scheme-aware URLs for collaboration services (http when INSECURE=true).
COLLABORA_URL=$_collabora_url
WOPISERVER_URL=$_wopi_url
COLLABORA_ADMIN_USER=$INSTALL_COLLABORA_ADMIN_USER
COLLABORA_ADMIN_PASSWORD=${_collab_pass_q}
COLLABORA_SSL_ENABLE=false
COLLABORA_SSL_VERIFICATION=false
COLLABORA_HOME_MODE=false
EOF
    chmod 600 "$INSTALL_ENV_FILE"
    __info ".env written."

    if [ ! -s "$INSTALL_ADMIN_OUT" ]; then
      printf "Admin user: %s\nAdmin pass: %s\n" "$INSTALL_ADMIN_USER" "$_admin_pass" > "$INSTALL_ADMIN_OUT"
      if [ "$INSTALL_ENABLE_COLLAB" = "true" ]; then
        printf "Collabora admin user: %s\nCollabora admin pass: %s\n" \
          "$INSTALL_COLLABORA_ADMIN_USER" "$_collab_pass" >> "$INSTALL_ADMIN_OUT"
      fi
      chmod 600 "$INSTALL_ADMIN_OUT"
      __info "Admin credentials saved to $INSTALL_ADMIN_OUT"
    fi
  else
    __info ".env exists; leaving as-is (idempotent)."
    if [ -n "$INSTALL_ADMIN_PASS" ]; then
      __warn "INITIAL_ADMIN_PASSWORD is ignored after first initialization."
      __warn "Change the admin password through the web UI instead."
    fi
  fi
}

# - - - - - - - - - - - - - - - - - - - - - - - - -
# Compose file
# - - - - - - - - - - - - - - - - - - - - - - - - -
__write_compose_file() {
  # Idempotency guard: honour the existing compose.yaml's Collabora state when
  # neither --collab nor --no-collab was passed explicitly on the command line.
  # This prevents a plain re-run or --update from silently adding or removing
  # Collabora services that the operator deliberately chose.
  if [ -f "$INSTALL_COMPOSE_FILE" ] && [ "$INSTALL_COLLAB_EXPLICIT" = "false" ]; then
    if grep -q -- 'container_name: opencloud-collaboration' "$INSTALL_COMPOSE_FILE" 2>/dev/null; then
      INSTALL_ENABLE_COLLAB="true"
    else
      INSTALL_ENABLE_COLLAB="false"
    fi
  fi

  # --- Base: opencloud service ---
  # NOTE: This file is auto-generated by install.sh on every run.
  # Do not edit it directly — changes will be overwritten.
  # Customise .env (preserved across runs) or re-run install.sh instead.
  cat > "$INSTALL_COMPOSE_FILE" <<'EOF'
# Auto-generated by install.sh — do not edit; re-run install.sh to regenerate.
---
services:

  opencloud:
    image: ${OC_DOCKER_IMAGE:-opencloudeu/opencloud-rolling}:${OC_DOCKER_TAG:-latest}
    container_name: opencloud-app
    user: ${OC_CONTAINER_UID_GID:-1000:1000}
    networks:
      - opencloud-net
    restart: unless-stopped
    entrypoint: ["/bin/sh"]
    # opencloud init writes config + random secrets on first run.
    # It exits non-zero if the config already exists; we ignore that error.
    command: ["-c", "opencloud init || true; opencloud server"]
    ports:
      - "127.0.0.1:${OPENCLOUD_HTTP_PORT:-9200}:9200"
    environment:
      OC_ADD_RUN_SERVICES: ${START_ADDITIONAL_SERVICES:-}
      # OC_URL is set by install.sh with the correct scheme (http for local, https for real domains).
      OC_URL: "${OC_URL:-https://localhost}"
      OC_LOG_LEVEL: ${LOG_LEVEL:-info}
      OC_LOG_COLOR: "${LOG_PRETTY:-false}"
      OC_LOG_PRETTY: "${LOG_PRETTY:-false}"
      PROXY_TLS: "false"
      OC_INSECURE: "${INSECURE:-false}"
      PROXY_ENABLE_BASIC_AUTH: "false"
      IDM_CREATE_DEMO_USERS: "${DEMO_USERS:-false}"
      IDM_ADMIN_PASSWORD: "${INITIAL_ADMIN_PASSWORD}"
      NOTIFICATIONS_SMTP_HOST: "${SMTP_HOST:-}"
      NOTIFICATIONS_SMTP_PORT: "${SMTP_PORT:-25}"
      NOTIFICATIONS_SMTP_SENDER: "${SMTP_SENDER:-OpenCloud Notifications <notifications@localhost>}"
      NOTIFICATIONS_SMTP_USERNAME: "${SMTP_USERNAME:-}"
      NOTIFICATIONS_SMTP_PASSWORD: "${SMTP_PASSWORD:-}"
      NOTIFICATIONS_SMTP_INSECURE: "${SMTP_INSECURE:-false}"
      NOTIFICATIONS_SMTP_AUTHENTICATION: "${SMTP_AUTHENTICATION:-}"
      NOTIFICATIONS_SMTP_ENCRYPTION: "${SMTP_TRANSPORT_ENCRYPTION:-none}"
      FRONTEND_ARCHIVER_MAX_SIZE: "10000000000"
    volumes:
      - ${OC_CONFIG_DIR:-opencloud-config}:/etc/opencloud
      - ${OC_DATA_DIR:-opencloud-data}:/var/lib/opencloud
    logging:
      driver: "${LOG_DRIVER:-local}"
      options:
        max-size: "50m"
        max-file: "5"

EOF

  # --- Optional: collaboration + collabora services ---
  if [ "$INSTALL_ENABLE_COLLAB" = "true" ]; then
    __info "Adding Collabora collaboration services to compose..."
    cat >> "$INSTALL_COMPOSE_FILE" <<'EOF'
  # Collaboration service: bridges OpenCloud with Collabora via the WOPI protocol.
  # Runs as a separate process using the same OpenCloud image.
  collaboration:
    image: ${OC_DOCKER_IMAGE:-opencloudeu/opencloud-rolling}:${OC_DOCKER_TAG:-latest}
    container_name: opencloud-collaboration
    user: ${OC_CONTAINER_UID_GID:-1000:1000}
    networks:
      - opencloud-net
    restart: unless-stopped
    depends_on:
      opencloud:
        condition: service_started
      collabora:
        condition: service_healthy
    entrypoint: ["/bin/sh"]
    command: ["-c", "opencloud collaboration server"]
    ports:
      - "127.0.0.1:9300:9300"
    environment:
      COLLABORATION_GRPC_ADDR: 0.0.0.0:9301
      COLLABORATION_HTTP_ADDR: 0.0.0.0:9300
      MICRO_REGISTRY: "nats-js-kv"
      # Use the service name (not container_name) for internal DNS resolution.
      MICRO_REGISTRY_ADDRESS: "opencloud:9233"
      # WOPISERVER_URL and COLLABORA_URL are written by install.sh with the correct scheme.
      COLLABORATION_WOPI_SRC: "${WOPISERVER_URL:-https://wopiserver.localhost}"
      COLLABORATION_APP_NAME: "CollaboraOnline"
      COLLABORATION_APP_PRODUCT: "Collabora"
      COLLABORATION_APP_ADDR: "${COLLABORA_URL:-https://collabora.localhost}"
      COLLABORATION_APP_ICON: "${COLLABORA_URL:-https://collabora.localhost}/favicon.ico"
      COLLABORATION_APP_INSECURE: "${INSECURE:-false}"
      COLLABORATION_CS3API_DATAGATEWAY_INSECURE: "${INSECURE:-false}"
      COLLABORATION_LOG_LEVEL: ${LOG_LEVEL:-info}
      OC_URL: "${OC_URL:-https://localhost}"
    volumes:
      - ${OC_CONFIG_DIR:-opencloud-config}:/etc/opencloud
    logging:
      driver: "${LOG_DRIVER:-local}"
      options:
        max-size: "50m"
        max-file: "5"

  # Collabora CODE: the actual document editing server.
  collabora:
    image: collabora/code:latest
    container_name: opencloud-collabora
    networks:
      - opencloud-net
    restart: unless-stopped
    cap_add:
      - SYS_ADMIN
    security_opt:
      - seccomp=unconfined
      - apparmor:unconfined
    ports:
      - "127.0.0.1:9980:9980"
    environment:
      # aliasgroup1 tells Collabora which WOPI server it may contact.
      aliasgroup1: "${WOPISERVER_URL:-https://wopiserver.localhost}"
      DONT_GEN_SSL_CERT: "YES"
      extra_params: >-
        --o:ssl.enable=${COLLABORA_SSL_ENABLE:-false}
        --o:ssl.ssl_verification=${COLLABORA_SSL_VERIFICATION:-false}
        --o:ssl.termination=true
        --o:welcome.enable=false
        --o:net.frame_ancestors=${OC_DOMAIN:-localhost}
        --o:home_mode.enable=${COLLABORA_HOME_MODE:-false}
      username: ${COLLABORA_ADMIN_USER:-admin}
      password: ${COLLABORA_ADMIN_PASSWORD}
    entrypoint: ["/bin/bash", "-c"]
    command: ["coolconfig generate-proof-key && /start-collabora-online.sh"]
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9980/hosting/discovery"]
      interval: 15s
      timeout: 10s
      retries: 5
      start_period: 30s
    logging:
      driver: "${LOG_DRIVER:-local}"
      options:
        max-size: "50m"
        max-file: "5"

EOF
  fi

  # --- Shared networks and volumes (always last) ---
  cat >> "$INSTALL_COMPOSE_FILE" <<'EOF'
networks:
  # External named network — created by install.sh before compose starts.
  # Attach your reverse proxy to this network to reach OpenCloud without
  # exposing extra ports on the host.
  opencloud-net:
    name: ${OPENCLOUD_NETWORK:-opencloud-net}
    external: true

volumes:
  opencloud-config:
  opencloud-data:
EOF
}

# - - - - - - - - - - - - - - - - - - - - - - - - -
# Backup (safe before updates)
# - - - - - - - - - - - - - - - - - - - - - - - - -
__snapshot_backup() {
  _ts="$(__now_utc)"
  _bdir="$INSTALL_BACKUP_DIR/$_ts"
  __info "Creating backup snapshot at $_bdir ..."
  mkdir -p "$_bdir"

  # Credentials and env (critical — failure is fatal for the backup)
  for _f in ".env" "admin.credentials"; do
    if [ -f "$INSTALL_COMPOSE_DIR/$_f" ]; then
      cp -- "$INSTALL_COMPOSE_DIR/$_f" "$_bdir/$_f" 2>/dev/null || \
        __warn "Could not back up $_f; continuing."
    fi
  done

  # Config snapshot
  tar -C "$INSTALL_COMPOSE_DIR" -czf "$_bdir/config.tgz" "$(basename "$INSTALL_CONFIG_DIR")" 2>/dev/null || \
    __warn "Config backup failed; continuing."

  # Data snapshot — warn if large
  if command -v du >/dev/null 2>&1; then
    _data_mb="$(du -sm "$INSTALL_DATA_DIR" 2>/dev/null | cut -f1)"
    if [ "${_data_mb:-0}" -gt 10240 ]; then
      __warn "Data directory is ${_data_mb} MB; backup may take some time."
    fi
  fi
  tar -C "$INSTALL_COMPOSE_DIR" -czf "$_bdir/data.tgz" "$(basename "$INSTALL_DATA_DIR")" 2>/dev/null || \
    __warn "Data backup failed; continuing (non-fatal)."

  __info "Backup snapshot complete: $_bdir"
}

# - - - - - - - - - - - - - - - - - - - - - - - - -
# Wait for OpenCloud to accept requests
# - - - - - - - - - - - - - - - - - - - - - - - - -
__wait_for_opencloud() {
  __info "Waiting for OpenCloud to initialize (can take a minute on first run)..."
  _tries=0
  while [ "$_tries" -lt 60 ]; do
    if curl -sf "http://127.0.0.1:${INSTALL_PORT}/" >/dev/null 2>&1; then
      __info "OpenCloud is responding."
      return 0
    fi
    sleep 5
    _tries=$((_tries + 1))
  done
  __warn "OpenCloud did not respond within 5 minutes."
  __warn "Check logs: cd $INSTALL_COMPOSE_DIR && docker compose logs -f opencloud"
  return 1
}

# - - - - - - - - - - - - - - - - - - - - - - - - -
# Main flow
# - - - - - - - - - - - - - - - - - - - - - - - - -
__main() {
  # Guard: --update on a path with no existing installation is almost always
  # a typo (wrong --path). Warn loudly so the user can abort.
  if [ "$INSTALL_UPDATE_ONLY" = "true" ] && [ ! -f "$INSTALL_ENV_FILE" ]; then
    __warn "--update specified but no existing installation found at $INSTALL_COMPOSE_DIR"
    __warn "(no .env found). Creating a fresh installation. Use Ctrl-C to abort."
    sleep 3
  fi

  __ensure_docker
  __ensure_network
  __write_env_file
  __write_compose_file

  cd "$INSTALL_COMPOSE_DIR"

  if [ "$INSTALL_UPDATE_ONLY" = "true" ]; then
    __info "Running update flow..."
    __snapshot_backup
    __info "Pulling latest images..."
    docker compose pull
    __info "Recreating services..."
    docker compose up -d --remove-orphans
  else
    __info "Bringing up OpenCloud stack..."
    docker compose up -d
  fi

  _oc_up=true
  __wait_for_opencloud || _oc_up=false

  # If --domain / --port were not passed, read them from the existing .env so
  # the summary reflects the actual configured values rather than defaults.
  if [ -f "$INSTALL_ENV_FILE" ]; then
    if [ -z "$INSTALL_DOMAIN" ]; then
      _env_domain="$(grep -- '^OC_DOMAIN=' "$INSTALL_ENV_FILE" | cut -d= -f2- | tr -d '"')"
      if [ -n "$_env_domain" ] && [ "$_env_domain" != "localhost" ]; then
        INSTALL_DOMAIN="$_env_domain"
      fi
    fi
    _env_port="$(grep -- '^OPENCLOUD_HTTP_PORT=' "$INSTALL_ENV_FILE" | cut -d= -f2- | tr -d '"')"
    if [ -n "$_env_port" ]; then
      INSTALL_PORT="$_env_port"
    fi
  fi

  # Derive display scheme from domain (mirrors __write_env_file logic).
  if [ -z "$INSTALL_DOMAIN" ] || [ "${INSTALL_DOMAIN%%.*}" = "$INSTALL_DOMAIN" ]; then
    _sum_scheme="http"
  else
    _sum_scheme="https"
  fi

  __info ""
  if [ "$_oc_up" = "true" ]; then
    __info "OpenCloud is up. Summary:"
  else
    __warn "OpenCloud did not come up within the timeout. Summary (check logs above):"
  fi
  __info "  Compose dir   : $INSTALL_COMPOSE_DIR"
  __info "  Port (HTTP)   : 127.0.0.1:$INSTALL_PORT  (attach your reverse proxy)"
  __info "  Docker network: $INSTALL_NETWORK_NAME  (attach your reverse proxy here)"
  if [ -n "$INSTALL_DOMAIN" ]; then
    __info "  Public URL    : ${_sum_scheme}://$INSTALL_DOMAIN/"
  fi
  if [ "$INSTALL_ENABLE_COLLAB" = "true" ]; then
    _bd="$(__infer_base_domain "${INSTALL_DOMAIN:-localhost}")"
    __info "  Collabora     : ${_sum_scheme}://collabora.${_bd}/  → proxy to port 9980"
    __info "  WOPI server   : ${_sum_scheme}://wopiserver.${_bd}/ → proxy to port 9300"
  fi
  if [ -f "$INSTALL_ADMIN_OUT" ]; then
    __info "  Admin creds   : $INSTALL_ADMIN_OUT  (delete after noting; mode 600)"
  fi
  __info "  Config dir    : $INSTALL_CONFIG_DIR"
  __info "  Data dir      : $INSTALL_DATA_DIR"
  __info "  Backups       : $INSTALL_BACKUP_DIR"
  __info ""
  __info "To manage:"
  __info "  cd $INSTALL_COMPOSE_DIR && docker compose ps"
  __info "  cd $INSTALL_COMPOSE_DIR && docker compose logs -f opencloud"
  __info "  sh install.sh --update --path $INSTALL_COMPOSE_DIR  # re-download install.sh to update"
}

# - - - - - - - - - - - - - - - - - - - - - - - - -
__main
# ex: ts=2 sw=2 et filetype=sh
