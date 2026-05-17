#!/usr/bin/env sh
#
# install.sh — Idempotent POSIX installer/updater for a full OpenCloud stack
#
# Requirements / Goals
# - POSIX-compliant shell (sh). No bashisms.
# - Platform-agnostic Linux support: Debian/Ubuntu, RHEL/Rocky/Alma/Fedora, openSUSE, Arch.
# - Install Docker Engine from OFFICIAL Docker repositories (not distro's deprecated docker.io pkg).
# - Use Docker Compose v2 plugin ("docker compose"). No docker.io package.
# - Deploy OpenCloud via a compose file under a managed directory.
# - Listen on host port 9200 (default), bind to 127.0.0.1 for reverse proxy fronting.
# - Admin username: "admin". Default password: random on first setup if not provided.
# - Update without breaking existing data; perform safe preflight checks and snapshots.
# - Optionally deploy Collabora document collaboration via --collab.
# - No "curl | sh" patterns. Keys/files may be downloaded; remote scripts are never executed.
# - No Docker Desktop requirement; pure server-side Docker Engine.
#
# Repo: https://github.com/scriptmgr/opencloud
# Script: install.sh
#
# Usage examples:
#   sh install.sh                                           # fresh install with defaults
#   sh install.sh --update                                  # update images (with safety backup)
#   sh install.sh --path /opt/opencloud                    # choose install dir
#   sh install.sh --admin-pass 'S3cure!'                   # set admin password
#   sh install.sh --port 9200 --domain cloud.example.com
#   sh install.sh --smtp-host 172.17.0.1 --smtp-port 25
#   sh install.sh --collab --domain cloud.example.com      # enable Collabora editing
#       # infers collabora.example.com + wopiserver.example.com automatically
#
# Notes:
# - OpenCloud admin username is always 'admin'.
# - The admin password is written ONCE at first startup via IDM_ADMIN_PASSWORD.
#   After first start, change it through the web UI; editing .env has no effect.
# - For collaboration (--collab) the reverse proxy must already serve HTTPS for
#   collabora.{base-domain} (→ port 9980) and wopiserver.{base-domain} (→ port 9300).
#   These subdomains are inferred from --domain automatically.
# - By default we assume a local MTA on the host is reachable at 172.17.0.1:25
#   from containers. Override via --smtp-host / --smtp-port if needed.
#
set -eu
umask 027

########################################
# Defaults
########################################
PREFIX="/opt/opencloud"
ADMIN_USER="admin"
ADMIN_PASS=""
PORT="9200"
DOMAIN=""
SMTP_HOST="172.17.0.1"    # Docker bridge gateway on Linux
SMTP_PORT="25"
SMTP_SECURE="none"         # 'none', 'starttls', or 'ssltls'
SMTP_AUTH=""               # auth method name (e.g. 'plain', 'login'); empty = none
SMTP_USER=""
SMTP_PASS=""
UPDATE_ONLY="false"
NON_INTERACTIVE="false"
ENABLE_COLLAB="false"
COLLABORA_ADMIN_USER="admin"
COLLABORA_ADMIN_PASS=""
OC_CONTAINER_UID_GID="1000:1000"
NETWORK_NAME="opencloud-net"

########################################
# Helpers (POSIX)
########################################
log()  { printf "%s\n" "$*"; }
info() { printf "[INFO] %s\n" "$*"; }
warn() { printf "[WARN] %s\n" "$*" >&2; }
err()  { printf "[ERR ] %s\n" "$*" >&2; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { err "Missing required command: $1"; exit 1; }
}

# Generate a random 32-char secret; prefers openssl, falls back to /dev/urandom.
rand_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 24 | tr -d '\n=' | cut -c1-32
  else
    dd if=/dev/urandom bs=1 count=48 2>/dev/null | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-32
  fi
}

is_root() {
  [ "$(id -u)" = "0" ]
}

# Run a shell command as root (or via sudo).
# Pass the entire command as a single pre-quoted string.
sudocmd() {
  if is_root; then
    sh -c "$1"
  else
    need_cmd sudo
    sudo sh -c "$1"
  fi
}

has_systemd() {
  command -v systemctl >/dev/null 2>&1
}

now_utc() { date -u +"%Y%m%dT%H%M%SZ"; }

# Derive a base domain from a potentially sub-domained hostname.
# cloud.example.com  → example.com   (strips leading label when 3+ labels present)
# example.com        → example.com   (unchanged)
# localhost          → localhost      (unchanged)
infer_base_domain() {
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

detect_pm() {
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
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
  err "Unsupported distribution (no known package manager)"; exit 1
}

########################################
# Argument parsing
########################################
while [ "$#" -gt 0 ]; do
  case "$1" in
    --path)                 PREFIX="$2";               shift 2 ;;
    --admin-pass)           ADMIN_PASS="$2";            shift 2 ;;
    --port)                 PORT="$2";                  shift 2 ;;
    --domain)               DOMAIN="$2";                shift 2 ;;
    --smtp-host)            SMTP_HOST="$2";             shift 2 ;;
    --smtp-port)            SMTP_PORT="$2";             shift 2 ;;
    --smtp-secure)          SMTP_SECURE="$2";           shift 2 ;;
    --smtp-auth)            SMTP_AUTH="$2";             shift 2 ;;
    --smtp-user)            SMTP_USER="$2";             shift 2 ;;
    --smtp-pass)            SMTP_PASS="$2";             shift 2 ;;
    --collab)               ENABLE_COLLAB="true";       shift 1 ;;
    --collabora-admin-user) COLLABORA_ADMIN_USER="$2";  shift 2 ;;
    --collabora-admin-pass) COLLABORA_ADMIN_PASS="$2";  shift 2 ;;
    --network)              NETWORK_NAME="$2";          shift 2 ;;
    --update)               UPDATE_ONLY="true";         shift 1 ;;
    -y|--yes|--non-interactive) NON_INTERACTIVE="true"; shift 1 ;;
    -h|--help)
      cat <<EOF
OpenCloud Installer / Updater (POSIX sh)

Options:
  --path DIR                    Install root (default: /opt/opencloud)
  --admin-pass PASS             Admin password (default: random on first setup)
  --port N                      Host port to bind (default: 9200)
  --domain HOST                 Public hostname (sets OC_DOMAIN)
  --smtp-host HOST              SMTP relay host (default: 172.17.0.1)
  --smtp-port PORT              SMTP relay port (default: 25)
  --smtp-secure MODE            'none', 'starttls', or 'ssltls' (default: none)
  --smtp-auth METHOD            SMTP auth method, e.g. 'plain' or 'login' (default: none)
  --smtp-user USER              SMTP username (if auth enabled)
  --smtp-pass PASS              SMTP password (if auth enabled)
  --collab                      Enable Collabora document collaboration
  --collabora-admin-user NAME   Collabora admin username (default: admin)
  --collabora-admin-pass PASS   Collabora admin password (default: random)
  --network NAME                Docker network name (default: opencloud-net)
                                Created automatically if it does not exist.
                                Join your reverse proxy to this network to reach OpenCloud.
  --update                      Pull latest images and recreate (with backup)
  -y, --yes                     Non-interactive mode (assume yes)
  -h, --help                    Show this help

Notes:
  OpenCloud admin username is always 'admin'.
  The admin password is applied ONCE at first startup; editing .env afterwards
  has no effect. Use the web UI to change it later.

  For --collab: Collabora subdomains are inferred from --domain automatically.
  If --domain is cloud.example.com the script configures:
    collabora.example.com  → port 9980
    wopiserver.example.com → port 9300
  Your reverse proxy must route HTTPS for both before the stack starts.
EOF
      exit 0 ;;
    *) err "Unknown option: $1"; exit 1 ;;
  esac
done

# Collaboration pre-flight
if [ "$ENABLE_COLLAB" = "true" ] && [ -z "$DOMAIN" ]; then
  err "--collab requires --domain (the public OpenCloud hostname)."
  exit 1
fi

########################################
# Directory layout
########################################
COMPOSE_DIR="$PREFIX"
ENV_FILE="$COMPOSE_DIR/.env"
COMPOSE_FILE="$COMPOSE_DIR/compose.yaml"
CONFIG_DIR="$COMPOSE_DIR/config"
DATA_DIR="$COMPOSE_DIR/data"
BACKUP_DIR="$COMPOSE_DIR/backups"
ADMIN_OUT="$COMPOSE_DIR/admin.credentials"

mkdir -p "$CONFIG_DIR" "$DATA_DIR" "$BACKUP_DIR"

# OpenCloud runs as uid/gid 1000 inside the container; volumes must match.
chown 1000:1000 "$CONFIG_DIR" "$DATA_DIR" 2>/dev/null || \
  warn "Could not chown config/data dirs to 1000:1000. Ensure the container user can write to them."

########################################
# Install Docker Engine (official repos) + compose plugin
########################################
install_docker_official() {
  _pm="$(detect_pm)"
  info "Detected package manager: $_pm"

  case "$_pm" in
    apt)
      need_cmd apt-get
      need_cmd gpg
      sudocmd "apt-get update"
      sudocmd "apt-get install -y ca-certificates curl gnupg lsb-release"
      mkdir -p /etc/apt/keyrings
      if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
        _distro_id="$(. /etc/os-release; echo "$ID")"
        curl -fsSL "https://download.docker.com/linux/${_distro_id}/gpg" | \
          gpg --dearmor > /tmp/opencloud-docker.gpg
        sudocmd "install -m 0644 -o root -g root -D /tmp/opencloud-docker.gpg /etc/apt/keyrings/docker.gpg"
        rm -f /tmp/opencloud-docker.gpg
      fi
      _arch="$(dpkg --print-architecture)"
      _distro_id="$(. /etc/os-release; echo "$ID")"
      _codename="$(. /etc/os-release; echo "$VERSION_CODENAME")"
      printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/%s %s stable\n' \
        "$_arch" "$_distro_id" "$_codename" | \
        sudocmd "tee /etc/apt/sources.list.d/docker.list >/dev/null"
      sudocmd "apt-get update"
      sudocmd "apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
      ;;
    dnf)
      need_cmd dnf
      sudocmd "dnf -y install dnf-plugins-core"
      _distro_id="$(. /etc/os-release; echo "$ID")"
      sudocmd "dnf config-manager --add-repo https://download.docker.com/linux/${_distro_id}/docker-ce.repo"
      sudocmd "dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
      ;;
    yum)
      need_cmd yum
      sudocmd "yum -y install yum-utils"
      sudocmd "yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo"
      sudocmd "yum -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || true"
      ;;
    zypper)
      need_cmd zypper
      sudocmd "zypper -n install ca-certificates curl gnupg2"
      _distro_id="$(. /etc/os-release; echo "$ID")"
      sudocmd "zypper -n addrepo https://download.docker.com/linux/${_distro_id}/docker-ce.repo || true"
      sudocmd "zypper -n refresh"
      sudocmd "zypper -n install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
      ;;
    pacman)
      need_cmd pacman
      sudocmd "pacman -Sy --noconfirm docker docker-compose-plugin"
      ;;
    *)
      err "Unsupported package manager: $_pm"; exit 1 ;;
  esac

  if has_systemd; then
    sudocmd "systemctl enable --now docker"
  else
    warn "systemd not detected. Please start and enable the Docker daemon manually."
  fi
}

ensure_network() {
  if docker network inspect -- "$NETWORK_NAME" >/dev/null 2>&1; then
    info "Docker network '$NETWORK_NAME' already exists."
  else
    info "Creating Docker network '$NETWORK_NAME'..."
    docker network create --driver bridge -- "$NETWORK_NAME"
  fi
}

ensure_docker() {
  if command -v docker >/dev/null 2>&1; then
    info "Docker is present."
  else
    info "Docker not found; installing from official repository..."
    install_docker_official
  fi
  if docker compose version >/dev/null 2>&1; then
    info "Docker Compose v2 plugin present."
  else
    err "Docker Compose v2 plugin missing. Please install docker-compose-plugin."; exit 1
  fi
}

########################################
# .env file (idempotent: written once only)
########################################
write_env_file() {
  if [ ! -s "$ENV_FILE" ]; then
    _admin_pass="${ADMIN_PASS:-$(rand_secret)}"
    _collab_pass="${COLLABORA_ADMIN_PASS:-$(rand_secret)}"
    # INSECURE: true when no domain is set (local/self-signed); false for internet-facing.
    _insecure="${DOMAIN:+false}"
    _insecure="${_insecure:-true}"
    # Infer Collabora subdomains from the base domain.
    _base_domain="$(infer_base_domain "${DOMAIN:-localhost}")"
    _collabora_domain="collabora.${_base_domain}"
    _wopi_domain="wopiserver.${_base_domain}"

    cat > "$ENV_FILE" <<EOF
# Autogenerated by install.sh on $(date -u)
# Safe to edit and re-run install.sh. Keep this file secure (mode 600).

COMPOSE_PROJECT_NAME=opencloud

# --- OpenCloud image ---
# Use opencloudeu/opencloud for stable releases.
OC_DOCKER_IMAGE=opencloudeu/opencloud-rolling
OC_DOCKER_TAG=latest
# Container runs as this uid:gid — volumes must be owned by the same ids.
OC_CONTAINER_UID_GID=$OC_CONTAINER_UID_GID

# --- Network ---
# Host port exposed by the reverse proxy.
OPENCLOUD_HTTP_PORT=$PORT
# Public domain name.
OC_DOMAIN=${DOMAIN:-localhost}
# Full URL that OpenCloud advertises to clients.
OC_URL=https://${DOMAIN:-localhost}
# TLS is terminated by the external reverse proxy; OpenCloud speaks plain HTTP.
PROXY_TLS=false
# Set true only for local/self-signed setups.
INSECURE=$_insecure

# --- Admin credentials (applied on FIRST start only) ---
# To change later: use the web UI — editing this file has no effect.
INITIAL_ADMIN_PASSWORD=$_admin_pass

# --- Demo users (never enable in production) ---
DEMO_USERS=false

# --- Logging ---
LOG_LEVEL=info
LOG_PRETTY=false
LOG_DRIVER=local

# --- Additional services ---
# 'notifications' enables SMTP email sending.
START_ADDITIONAL_SERVICES=notifications

# --- SMTP / email notifications ---
SMTP_HOST=$SMTP_HOST
SMTP_PORT=$SMTP_PORT
SMTP_SENDER=OpenCloud Notifications <notifications@${DOMAIN:-localhost}>
SMTP_USERNAME=$SMTP_USER
SMTP_PASSWORD=$SMTP_PASS
SMTP_AUTHENTICATION=$SMTP_AUTH
SMTP_TRANSPORT_ENCRYPTION=$SMTP_SECURE
SMTP_INSECURE=false

# --- Storage (leave empty to use Docker-managed named volumes) ---
OC_CONFIG_DIR=$CONFIG_DIR
OC_DATA_DIR=$DATA_DIR

# --- Docker network ---
# All OpenCloud containers join this network. Attach your reverse proxy to it.
OPENCLOUD_NETWORK=$NETWORK_NAME

# --- Collaboration (Collabora + WOPI) ---
# Subdomains are inferred from OC_DOMAIN at install time. Only used when
# the collaboration service is included in compose.yaml.
COLLABORA_DOMAIN=$_collabora_domain
WOPISERVER_DOMAIN=$_wopi_domain
COLLABORA_ADMIN_USER=$COLLABORA_ADMIN_USER
COLLABORA_ADMIN_PASSWORD=$_collab_pass
COLLABORA_SSL_ENABLE=false
COLLABORA_SSL_VERIFICATION=false
COLLABORA_HOME_MODE=false
EOF
    chmod 600 "$ENV_FILE"
    info ".env written."

    if [ ! -s "$ADMIN_OUT" ]; then
      printf "Admin user: %s\nAdmin pass: %s\n" "$ADMIN_USER" "$_admin_pass" > "$ADMIN_OUT"
      if [ "$ENABLE_COLLAB" = "true" ]; then
        printf "Collabora admin user: %s\nCollabora admin pass: %s\n" \
          "$COLLABORA_ADMIN_USER" "$_collab_pass" >> "$ADMIN_OUT"
      fi
      chmod 600 "$ADMIN_OUT"
      info "Admin credentials saved to $ADMIN_OUT"
    fi
  else
    info ".env exists; leaving as-is (idempotent)."
    if [ -n "$ADMIN_PASS" ]; then
      warn "INITIAL_ADMIN_PASSWORD is ignored after first initialization."
      warn "Change the admin password through the web UI instead."
    fi
  fi
}

########################################
# Compose file (always regenerated so
# collab can be added on re-runs)
########################################
write_compose_file() {
  # --- Base: opencloud service ---
  cat > "$COMPOSE_FILE" <<'EOF'
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
      OC_URL: https://${OC_DOMAIN:-localhost}
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

EOF

  # --- Optional: collaboration + collabora services ---
  if [ "$ENABLE_COLLAB" = "true" ]; then
    info "Adding Collabora collaboration services to compose..."
    cat >> "$COMPOSE_FILE" <<'EOF'
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
      COLLABORATION_WOPI_SRC: https://${WOPISERVER_DOMAIN:-wopiserver.localhost}
      COLLABORATION_APP_NAME: "CollaboraOnline"
      COLLABORATION_APP_PRODUCT: "Collabora"
      COLLABORATION_APP_ADDR: https://${COLLABORA_DOMAIN:-collabora.localhost}
      COLLABORATION_APP_ICON: https://${COLLABORA_DOMAIN:-collabora.localhost}/favicon.ico
      COLLABORATION_APP_INSECURE: "${INSECURE:-false}"
      COLLABORATION_CS3API_DATAGATEWAY_INSECURE: "${INSECURE:-false}"
      COLLABORATION_LOG_LEVEL: ${LOG_LEVEL:-info}
      OC_URL: https://${OC_DOMAIN:-localhost}
    volumes:
      - ${OC_CONFIG_DIR:-opencloud-config}:/etc/opencloud

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
      aliasgroup1: https://${WOPISERVER_DOMAIN:-wopiserver.localhost}
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

EOF
  fi

  # --- Shared networks and volumes (always last) ---
  cat >> "$COMPOSE_FILE" <<'EOF'
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

########################################
# Backup (safe before updates)
########################################
snapshot_backup() {
  _ts="$(now_utc)"
  _bdir="$BACKUP_DIR/$_ts"
  info "Creating backup snapshot at $_bdir ..."
  mkdir -p "$_bdir"

  # Config snapshot
  tar -C "$COMPOSE_DIR" -czf "$_bdir/config.tgz" "$(basename "$CONFIG_DIR")" 2>/dev/null || \
    warn "Config backup failed; continuing."

  # Data snapshot — warn if large
  if command -v du >/dev/null 2>&1; then
    _data_mb="$(du -sm "$DATA_DIR" 2>/dev/null | cut -f1)"
    if [ "${_data_mb:-0}" -gt 10240 ]; then
      warn "Data directory is ${_data_mb} MB; backup may take some time."
    fi
  fi
  tar -C "$COMPOSE_DIR" -czf "$_bdir/data.tgz" "$(basename "$DATA_DIR")" 2>/dev/null || \
    warn "Data backup failed; continuing (non-fatal)."

  info "Backup snapshot complete: $_bdir"
}

########################################
# Wait for OpenCloud to accept requests
########################################
wait_for_opencloud() {
  info "Waiting for OpenCloud to initialize (can take a minute on first run)..."
  _tries=0
  while [ "$_tries" -lt 60 ]; do
    if curl -sf "http://127.0.0.1:${PORT}/" >/dev/null 2>&1; then
      info "OpenCloud is responding."
      return 0
    fi
    sleep 5
    _tries=$((_tries + 1))
  done
  warn "OpenCloud did not respond within 5 minutes."
  warn "Check logs: cd $COMPOSE_DIR && docker compose logs -f opencloud"
}

########################################
# Main flow
########################################
main() {
  ensure_docker
  ensure_network
  write_env_file
  write_compose_file

  cd "$COMPOSE_DIR"

  if [ "$UPDATE_ONLY" = "true" ]; then
    info "Running update flow..."
    snapshot_backup
    info "Pulling latest images..."
    docker compose pull
    info "Recreating services..."
    docker compose up -d --remove-orphans
  else
    info "Bringing up OpenCloud stack..."
    docker compose up -d
  fi

  wait_for_opencloud

  info ""
  info "OpenCloud is up. Summary:"
  info "  Compose dir   : $COMPOSE_DIR"
  info "  Port (HTTP)   : 127.0.0.1:$PORT  (attach your reverse proxy)"
  if [ -n "$DOMAIN" ]; then
    info "  Public URL    : https://$DOMAIN/"
  fi
  if [ "$ENABLE_COLLAB" = "true" ]; then
    _bd="$(infer_base_domain "${DOMAIN:-localhost}")"
    info "  Collabora     : https://collabora.${_bd}/  → proxy to port 9980"
    info "  WOPI server   : https://wopiserver.${_bd}/ → proxy to port 9300"
    info "  Docker network: $NETWORK_NAME  (attach your reverse proxy here)"
  fi
  if [ -f "$ADMIN_OUT" ]; then
    info "  Admin creds   : $ADMIN_OUT"
  fi
  info "  Config dir    : $CONFIG_DIR"
  info "  Data dir      : $DATA_DIR"
  info "  Backups       : $BACKUP_DIR"
  info ""
  info "To manage:"
  info "  cd $COMPOSE_DIR && docker compose ps"
  info "  cd $COMPOSE_DIR && docker compose logs -f opencloud"
  info "  sh $0 --update --path $COMPOSE_DIR"
}

main "$@"
