#!/usr/bin/env bash
# DDS-Nodex Manager (EN + Better UX) — final, IFS-safe, pretty menu + .env editor
# MODIFIED: Paths moved to /home/cloudsigma/ and root requirement removed.
set -Eeuo pipefail
IFS=$'\n\t'

# ==================== Defaults (Modified for /home/cloudsigma/) ====================
readonly ZIP_URL_DEFAULT="${ZIP_URL:-https://github.com/azavaxhuman/Nodex/releases/download/v1.4/v1.4.zip}"
readonly APP_HOME_DEFAULT="${APP_HOME:-/home/cloudsigma/dds-nodex}"
readonly DATA_DIR_DEFAULT="${DATA_DIR:-/home/cloudsigma/dds-nodex/data}"
readonly CONFIG_DIR_DEFAULT="${CONFIG_DIR:-/home/cloudsigma/dds-nodex/config}"
# UID/GID are now set to the current user since root is not used.
readonly UID_APP_DEFAULT="" # Set dynamically below
readonly GID_APP_DEFAULT="" # Set dynamically below
# Binary path moved to user's home. Make sure /home/cloudsigma/bin is in your $PATH
readonly BIN_PATH_DEFAULT="${BIN_PATH:-/home/cloudsigma/bin/dds-nodex}"

COMPOSE_FILES=("docker-compose.yml" "compose.yml" "compose.yaml")

# ==================== Mutable (via flags) ====================
ZIP_URL="$ZIP_URL_DEFAULT"
APP_HOME="$APP_HOME_DEFAULT"
DATA_DIR="$DATA_DIR_DEFAULT"
CONFIG_DIR="$CONFIG_DIR_DEFAULT"
# Set UID/GID to the current user, as root privileges are not assumed.
UID_APP="${UID_APP:-$(id -u)}"
GID_APP="${GID_APP:-$(id -g)}"
BIN_PATH="$BIN_PATH_DEFAULT"
REQUIRED_FILES=("Dockerfile" "requirements.txt")
NONINTERACTIVE=false
SKIP_DOCKER_INSTALL=false
COMPOSE_CMD=()   # array, safe with IFS

# ==================== UI ====================
ce() { local c="$1"; shift || true; local code=0
  case "$c" in red)code=31;;green)code=32;;yellow)code=33;;blue)code=34;;magenta)code=35;;cyan)code=36;;bold)code=1;; *)code=0;; esac
  echo -e "\033[${code}m$*\033[0m"
}
ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { ce "$1" "[$(ts)] $2"; }
section(){ ce magenta "\n────────────────────────────────────────────────────"; ce bold " $1"; ce magenta "────────────────────────────────────────────────────\n"; }
step(){ log blue    "[STEP] $1"; }
ok()  { log green   "[OK]   $1"; }
warn(){ log yellow  "[WARN] $1"; }
fatal(){ log red    "[FATAL] $1"; exit "${2:-1}"; }
info(){ log cyan    "[INFO] $1"; }
success(){ log bold "[SUCCESS] $1"; }

pause(){ $NONINTERACTIVE && return 0; read -n1 -s -r -p "Press any key to continue..." _; echo; }
confirm(){ $NONINTERACTIVE && return 0; read -p "$1 [y/N]: " -r; [[ "${REPLY:-}" =~ ^[Yy]$ ]]; }

# ==================== Traps ====================
cleanup(){ true; }
on_err(){ fatal "Command failed. Check messages above." "$?"; }
trap cleanup EXIT
trap on_err ERR

# ==================== Core ====================
require_root(){
  # MODIFIED: This check is disabled.
  # The original script would exit if not run as root.
  # NOTE: Without root, you must manually install dependencies like Docker, curl, etc.
  true
}

detect_compose(){
  if command -v docker &>/dev/null && docker compose version &>/dev/null; then
    COMPOSE_CMD=(docker compose)
  elif command -v docker-compose &>/dev/null; then
    COMPOSE_CMD=(docker-compose)
  else
    COMPOSE_CMD=()
  fi
}

need_compose(){
  if ((${#COMPOSE_CMD[@]}==0)); then
    detect_compose
    ((${#COMPOSE_CMD[@]}==0)) && fatal "Docker Compose not available. Please install it manually."
  fi
}

install_deps(){
  local deps=(curl unzip ca-certificates gnupg lsb-release)
  local miss=()
  for d in "${deps[@]}"; do command -v "$d" &>/dev/null || miss+=("$d"); done
  if ((${#miss[@]})); then
    # MODIFIED: Cannot auto-install without root.
    warn "Missing dependencies: ${miss[*]}. Please install them manually."
    fatal "Dependency installation failed."
  else ok "All dependencies present."; fi
}

ensure_docker(){
  detect_compose
  if ! command -v docker &>/dev/null; then
    $SKIP_DOCKER_INSTALL && fatal "Docker not found and auto-install disabled."
    # MODIFIED: Cannot auto-install without root.
    fatal "Docker is not installed. Please install it manually before running this script."
  fi
  detect_compose
  if ((${#COMPOSE_CMD[@]}==0)); then
    # MODIFIED: Cannot auto-install without root.
    fatal "Docker Compose plugin is not installed. Please install it manually."
  fi
  ok "Docker/Compose ready."
}

create_user_group(){
  # MODIFIED: This function no longer creates a system user/group.
  # It will use the current user's UID/GID for file ownership.
  ok "Skipping user/group creation. Using current user (UID: ${UID_APP}, GID: ${GID_APP})."
}

create_dirs(){
  mkdir -p "${APP_HOME}" "${DATA_DIR}" "${CONFIG_DIR}"
  # The chown should succeed as the directories are within the user's home.
  chown -R "${UID_APP}:${GID_APP}" "${DATA_DIR}" "${CONFIG_DIR}"
  chown -R "${UID_APP}:${GID_APP}" "${APP_HOME}"
}

validate_files(){
  for f in "${REQUIRED_FILES[@]}"; do
    [[ -f "${APP_HOME}/$f" ]] || fatal "Required file missing: $f"
    ok "Found $f"
  done
  local found=false
  for c in "${COMPOSE_FILES[@]}"; do
    if [[ -f "${APP_HOME}/$c" ]]; then ok "Found $c"; found=true; break; fi
  done
  $found || fatal "No compose file found (checked: ${COMPOSE_FILES[*]})."
}

parse_zip(){
  case "$ZIP_URL" in
    file://*) ZIP_PATH="${ZIP_URL#file://}"; [[ -f "$ZIP_PATH" ]] || fatal "Zip not found: $ZIP_PATH" ;;
    http://*|https://*) ZIP_PATH="" ;;
    *) fatal "Unsupported ZIP_URL: $ZIP_URL" ;;
  esac
}

download_extract(){
  section "Download & Extract"
  parse_zip
  local tmp; tmp="$(mktemp --suffix=.zip)"

  if [[ -n "${ZIP_PATH:-}" ]]; then
    info "Copying local archive: $ZIP_PATH"
    cp -f "$ZIP_PATH" "$tmp"
  else
    info "Downloading: $ZIP_URL"
    curl -fSL --retry 3 --retry-delay 2 "$ZIP_URL" -o "$tmp"
  fi
  ok "Archive ready."

  info "Unpacking to ${APP_HOME}…"
  mkdir -p "${APP_HOME}"
  unzip -oq "$tmp" -d "${APP_HOME}"
  rm -f "$tmp"
  ok "Unpacked."

  shopt -s nullglob dotglob
  local entries=("${APP_HOME}"/*)
  if (( ${#entries[@]} == 1 )) && [[ -d "${entries[0]}" ]]; then
    local top="${entries[0]}"
    info "Detected single top-level dir '$(basename "$top")' → promoting contents to ${APP_HOME}"
    mv "${top}/"* "${APP_HOME}/" 2>/dev/null || true
    rmdir "$top" 2>/dev/null || true
    ok "Contents promoted."
  fi
  shopt -u nullglob dotglob
}


setup_config(){
  section "Configuration"
  local sample="${APP_HOME}/config.sample.json"
  local cfg="${CONFIG_DIR}/config.json"
  if [[ -f "$cfg" ]]; then ok "config.json already exists."
  else
    if [[ -f "$sample" ]]; then cp -f "$sample" "$cfg"; ok "config.json created from sample."
    else warn "No config.sample.json; create ${cfg} manually."; fi
  fi
}

backup_config(){
  local cfg="${CONFIG_DIR}/config.json"
  [[ -f "$cfg" ]] || return 0
  local t; t="$(date +%Y%m%d-%H%M%S)"
  cp -f "$cfg" "${cfg}.bak-${t}"
  ok "Config backup: ${cfg}.bak-${t}"
}

backup_env(){
  local envf="${APP_HOME}/.env"
  [[ -f "$envf" ]] || return 0
  local t; t="$(date +%Y%m%d-%H%M%S)"
  cp -f "$envf" "${envf}.bak-${t}"
  ok ".env backup: ${envf}.bak-${t}"
}

edit_env(){
  section "Edit .env"
  local editor="${EDITOR:-nano}"
  local envf="${APP_HOME}/.env"
  if [[ ! -f "$envf" ]]; then
    touch "$envf"
    chown "${UID_APP}:${GID_APP}" "$envf" || true
    ok "Created empty ${envf}"
  fi
  backup_env
  info "Opening with ${editor}…"; "$editor" "$envf"; ok ".env saved."
}

compose_build_up(){
  section "Docker Compose Deploy"
  validate_files
  need_compose
  (cd "${APP_HOME}" && "${COMPOSE_CMD[@]}" build && ok "Built." && "${COMPOSE_CMD[@]}" up -d && ok "Service started.")
}

show_logs(){
  local lines="${1:-100}"
  section "Recent Logs"
  need_compose
  (cd "${APP_HOME}" && "${COMPOSE_CMD[@]}" logs --tail "$lines" --no-log-prefix) || warn "No logs."
}

tail_follow_logs(){
  section "Live Logs (press Ctrl+C to stop)"
  need_compose
  (cd "${APP_HOME}" && "${COMPOSE_CMD[@]}" logs -f --tail=50 --no-log-prefix) || warn "No logs."
}

edit_config(){
  section "Edit Config"
  local editor="${EDITOR:-nano}"
  local cfg="${CONFIG_DIR}/config.json"
  if [[ ! -f "$cfg" ]]; then
    local sample="${APP_HOME}/config.sample.json"
    [[ -f "$sample" ]] || fatal "config.sample.json missing; cannot create config.json."
    cp -f "$sample" "$cfg"; ok "config.json created."
  fi
  backup_config
  info "Opening with ${editor}…"; "$editor" "$cfg"; ok "Config saved."
}

safe_delete_principals(){
  # MODIFIED: This function no longer deletes system users/groups.
  ok "Skipping user/group deletion."
}

uninstall_stack(){
  section "Uninstall DDS-Nodex"
  if ! $NONINTERACTIVE; then
    confirm "Are you sure you want to uninstall and DELETE ALL DATA?" || { warn "Uninstall cancelled."; return; }
    read -p "Type DELETE to confirm: " -r; [[ "${REPLY:-}" == "DELETE" ]] || { warn "Uninstall aborted."; return; }
  else
    warn "Non-interactive uninstall: skipping confirmations (dangerous)."
  fi

  need_compose || true
  step "Stopping service…"; (cd "${APP_HOME}" && "${COMPOSE_CMD[@]}" down) || warn "Service not running."
  step "Removing files…"; rm -rf "${APP_HOME}" "${DATA_DIR}" "${CONFIG_DIR}"
  step "Removing app user/group…"; safe_delete_principals
  success "DDS-Nodex uninstalled."
}

service_status(){ section "Service Status"; need_compose; (cd "${APP_HOME}" && "${COMPOSE_CMD[@]}" ps) || warn "No status."; }
disk_usage(){ section "Disk Usage"; du -sh "${APP_HOME}" "${DATA_DIR}" "${CONFIG_DIR}" 2>/dev/null || true; }
list_containers(){ section "Docker Containers"; docker ps -a || true; }
list_images(){ section "Docker Images"; docker images || true; }
restart_service(){ section "Restart Service"; need_compose; (cd "${APP_HOME}" && "${COMPOSE_CMD[@]}" restart && ok "Restarted.") || warn "Service not found."; }

register_cmd(){
  local bin_dir; bin_dir="$(dirname "$BIN_PATH")"
  mkdir -p "$bin_dir"
  [[ -f "$BIN_PATH" ]] && return 0

  local script_path; script_path="$(realpath "${BASH_SOURCE[0]}")"

  cat > "$BIN_PATH" <<EOF
#!/usr/bin/env bash
exec "$script_path" "\$@"
EOF
  chmod +x "$BIN_PATH"
  ok "Command '$(basename "$BIN_PATH")' registered in ${BIN_PATH}."
  info "You may need to add '${bin_dir}' to your \$PATH to run it directly."
}

is_installed(){
  for c in "${COMPOSE_FILES[@]}"; do
    [[ -f "${APP_HOME}/$c" ]] && return 0
  done
  return 1
}

quick_start(){
  section "Quick Start"
  if ! is_installed; then
    info "Not installed → running install."
    install_dds_nodex
  else
    service_status
    show_logs 50
    pause
  fi
}

# ==================== High-level ====================
install_dds_nodex(){
  section "Install DDS-Nodex"
  require_root
  install_deps
  ensure_docker
  step "Prepare user/group & directories…"
  create_user_group
  create_dirs
  ok "Preparation done."
  download_extract
  setup_config
  compose_build_up
  success "Installation finished!"
  info "Logs:   (cd ${APP_HOME} && ${COMPOSE_CMD[*]} logs --tail 100 --no-log-prefix)"
  info "Stop:   (cd ${APP_HOME} && ${COMPOSE_CMD[*]} down)"
  info "Restart:(cd ${APP_HOME} && ${COMPOSE_CMD[*]} restart)"
  show_logs 100
  $NONINTERACTIVE || pause
}

# ==================== CLI (Flags) ====================
print_help(){
  cat <<EOF
DDS-Nodex Manager (Modified for non-root execution)

Usage:
  $(basename "$0")                  # Interactive menu (recommended)
  $(basename "$0") --install        # Non-interactive install
  $(basename "$0") --quick          # Quick Start (install or status+logs)
  $(basename "$0") --uninstall      # Non-interactive uninstall (dangerous)
  $(basename "$0") --status         # Show compose status
  $(basename "$0") --logs           # Show recent logs
  $(basename "$0") --follow-logs    # Follow logs
  $(basename "$0") --restart        # Restart service
  $(basename "$0") --edit-config    # Edit config.json with backup
  $(basename "$0") --edit-env       # Edit ${APP_HOME}/.env with backup
  $(basename "$0") --disk           # Disk usage
  $(basename "$0") --containers     # List containers
  $(basename "$0") --images         # List images

Flags:
  --zip-url=URL         Zip source (http/https/file://)
  --app-home=PATH       Install path (default: ${APP_HOME_DEFAULT})
  --data-dir=PATH
  --config-dir=PATH
  --uid=ID --gid=ID     App UID/GID (defaults to current user)
  --non-interactive     No prompts/pauses
  --skip-docker-install Do not auto-install Docker
  -h, --help            Show help
EOF
}

ACTION=""
parse_flags(){
  for a in "$@"; do
    case "$a" in
      --install) ACTION="install" ;;
      --quick) ACTION="quick" ;;
      --uninstall) ACTION="uninstall" ;;
      --status) ACTION="status" ;;
      --logs) ACTION="logs" ;;
      --follow-logs) ACTION="follow-logs" ;;
      --restart) ACTION="restart" ;;
      --edit-config) ACTION="edit-config" ;;
      --edit-env) ACTION="edit-env" ;;
      --disk) ACTION="disk" ;;
      --containers) ACTION="containers" ;;
      --images) ACTION="images" ;;
      --zip-url=*) ZIP_URL="${a#*=}" ;;
      --app-home=*) APP_HOME="${a#*=}" ;;
      --data-dir=*) DATA_DIR="${a#*=}" ;;
      --config-dir=*) CONFIG_DIR="${a#*=}" ;;
      --uid=*) UID_APP="${a#*=}" ;;
      --gid=*) GID_APP="${a#*=}" ;;
      --non-interactive) NONINTERACTIVE=true ;;
      --skip-docker-install) SKIP_DOCKER_INSTALL=true ;;
      -h|--help) print_help; exit 0 ;;
      *) warn "Unknown flag: $a" ;;
    esac
  done
}
parse_flags "$@"

# ==================== Interactive Menu ====================
draw_menu(){
  ce green "┌────────────────────────────────────────────────────────────────────────────┐"
  ce green "│                                                                            │"
  ce green "│ $(ce green ' 1)') Quick Start              (install if missing / show status & logs)     $(ce green '│')"
  ce green "│____________________________________________________________________________│"
  ce green "│                                                                            │"
  ce green "│ $(ce green ' 2)') Service Status           (docker compose ps)                           $(ce green '│')"
  ce green "│____________________________________________________________________________│"
  ce green "│                                                                            │"
  ce green "│ $(ce green ' 3)') View Logs                (last 100 lines, optional follow)             $(ce green '│')"
  ce green "│                                                                            │"
  ce green "│ $(ce green ' 4)') Restart Service          (docker compose restart)                      $(ce green '│')"
  ce green "│____________________________________________________________________________│"
  ce green "│                                                                            │"
  ce green "│ $(ce green ' 5)') Edit Config              (backup + open in Nano Editor)                $(ce green '│')"
  ce green "│                                                                            │"
  ce green "│ $(ce green ' 6)') Edit .env                (${APP_HOME}/.env)                         $(ce green '│')"
  ce green "│____________________________________________________________________________│"
  ce green "│                                                                            │"
  ce green "│ $(ce green ' 7)') Install 3x-ui Panel      (from MHSanaei Github)                        $(ce green '│')"
  ce green "│____________________________________________________________________________│"
  ce green "│                                                                            │"
  ce green "│ $(ce red ' X)') Uninstall                (DANGEROUS – double confirmation)             $(ce green '│')"
  ce green "│____________________________________________________________________________│"
  ce green "│                                                                            │"
  ce bold  "│ $(ce bold ' 0)') Exit                                                                   $(ce green '│')"
  ce green "│                                                                            $(ce green '│')"
  ce green "└────────────────────────────────────────────────────────────────────────────┘"
  echo
  ce magenta "──────────────────────────────────────────────────────────────"
  ce bold    "  YouTube | Telegram :  @DailyDigitalSkills"
  ce magenta "──────────────────────────────────────────────────────────────"
  echo
}

main_menu(){
  register_cmd
  ensure_docker || true
  while true; do
    clear
    section "DDS-Nodex Control Panel"
    draw_menu
    read -p "Select an option [0-8/X]: " -r choice
    case "$choice" in
      1) quick_start ;;
      2) service_status; pause ;;
      3) show_logs 100; read -p "Follow live logs? [y/N]: " -r; [[ "${REPLY:-}" =~ ^[Yy]$ ]] && tail_follow_logs; pause ;;
      4) restart_service; pause ;;
      5) edit_config; pause ;;
      6) edit_env; pause ;;
      7) section "Install 3x-ui Panel"
         if confirm "This will run a remote script from the Internet. Proceed?"; then
           bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
         else
           warn "Skipped 3x-ui installation."
         fi
         pause ;;
      X|x) uninstall_stack; pause ;;
      0) ce bold "Goodbye!"; exit 0 ;;
      *) warn "Invalid option."; pause ;;
    esac
  done
}

# ==================== Entry ====================
if [[ -n "${ACTION:-}" ]]; then
  register_cmd
  ensure_docker || true
  case "$ACTION" in
    install) require_root; install_dds_nodex ;;
    quick) require_root; quick_start ;;
    uninstall) require_root; NONINTERACTIVE=true; uninstall_stack ;;
    status) service_status ;;
    logs) show_logs 100 ;;
    follow-logs) tail_follow_logs ;;
    restart) restart_service ;;
    edit-config) require_root; edit_config ;;
    edit-env) require_root; edit_env ;;
    disk) disk_usage ;;
    containers) list_containers ;;
    images) list_images ;;
  esac
  exit 0
fi

require_root
main_menu
