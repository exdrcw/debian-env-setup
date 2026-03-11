#!/usr/bin/env bash
set -euo pipefail

# Minimal Debian installs may not expose admin commands like usermod in a normal user's PATH.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config/setup.env"
ACTION="init"
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage:
  bash setup.sh <action> [--config path] [--dry-run]

Actions:
  init
  install-base
  install-node
  install-shell
  link-dotfiles
  apply-proxy
  clear-proxy
  doctor
EOF
}

log() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[DRY-RUN] '
    printf '%q ' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

need_root_or_sudo() {
  if [[ "$(id -u)" -eq 0 ]]; then
    return 0
  fi
  command -v sudo >/dev/null 2>&1 || die "This step requires root or sudo."
}

as_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    run "$@"
  else
    run sudo "$@"
  fi
}

as_target_user() {
  local command_string="$1"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    if [[ "$(id -un)" == "$TARGET_USER" ]]; then
      printf '[DRY-RUN] bash -lc %q\n' "$command_string"
    else
      printf '[DRY-RUN] sudo -u %q -H bash -lc %q\n' "$TARGET_USER" "$command_string"
    fi
    return 0
  fi

  if [[ "$(id -un)" == "$TARGET_USER" ]]; then
    bash -lc "$command_string"
  elif command -v sudo >/dev/null 2>&1; then
    sudo -u "$TARGET_USER" -H bash -lc "$command_string"
  elif [[ "$(id -u)" -eq 0 ]]; then
    su - "$TARGET_USER" -c "$command_string"
  else
    die "Cannot run command as $TARGET_USER without sudo or root"
  fi
}

parse_args() {
  if [[ $# -gt 0 && "${1:-}" != --* ]]; then
    ACTION="$1"
    shift
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config)
        [[ $# -ge 2 ]] || die "--config requires a path"
        CONFIG_FILE="$2"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done
}

load_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    set +u
    source "$CONFIG_FILE"
    set -u
  else
    warn "Config file not found: $CONFIG_FILE"
    warn "Continuing with built-in defaults."
  fi

  TARGET_USER="${TARGET_USER:-${SUDO_USER:-${USER:-$(id -un)}}}"
  [[ -n "$TARGET_USER" ]] || die "Unable to determine TARGET_USER"

  TARGET_HOME="${TARGET_HOME:-$(getent passwd "$TARGET_USER" | cut -d: -f6)}"
  [[ -n "$TARGET_HOME" ]] || die "Unable to determine home directory for $TARGET_USER"
  TARGET_GROUP="${TARGET_GROUP:-$(id -gn "$TARGET_USER")}"

  GRANT_SUDO="${GRANT_SUDO:-0}"
  SUDO_NOPASSWD="${SUDO_NOPASSWD:-0}"
  INSTALL_BASE_PACKAGES="${INSTALL_BASE_PACKAGES:-1}"
  INSTALL_NODEJS="${INSTALL_NODEJS:-1}"
  INSTALL_SHELL_TOOLS="${INSTALL_SHELL_TOOLS:-1}"
  CONFIGURE_PROXY="${CONFIGURE_PROXY:-1}"
  CHANGE_DEFAULT_SHELL_TO_ZSH="${CHANGE_DEFAULT_SHELL_TO_ZSH:-1}"

  BASE_PACKAGES_DEFAULT="curl wget git sudo ca-certificates build-essential zsh tmux unzip zip xz-utils gnupg lsb-release jq ripgrep fd-find"
  BASE_PACKAGES="${BASE_PACKAGES:-$BASE_PACKAGES_DEFAULT}"

  PROXY_URL="${PROXY_URL:-}"
  HTTP_PROXY="${HTTP_PROXY:-$PROXY_URL}"
  HTTPS_PROXY="${HTTPS_PROXY:-${PROXY_URL:-}}"
  ALL_PROXY="${ALL_PROXY:-}"
  NO_PROXY="${NO_PROXY:-localhost,127.0.0.1,::1,.local}"

  APT_HTTP_PROXY="${APT_HTTP_PROXY:-$HTTP_PROXY}"
  APT_HTTPS_PROXY="${APT_HTTPS_PROXY:-$HTTPS_PROXY}"
  GIT_HTTP_PROXY="${GIT_HTTP_PROXY:-$HTTP_PROXY}"
  GIT_HTTPS_PROXY="${GIT_HTTPS_PROXY:-$HTTPS_PROXY}"
  NPM_PROXY="${NPM_PROXY:-$HTTP_PROXY}"
  NPM_HTTPS_PROXY="${NPM_HTTPS_PROXY:-$HTTPS_PROXY}"

  NPM_REGISTRY="${NPM_REGISTRY:-https://registry.npmjs.org/}"
  OH_MY_ZSH_REPO_URL="${OH_MY_ZSH_REPO_URL:-https://github.com/ohmyzsh/ohmyzsh.git}"
  OH_MY_TMUX_REPO_URL="${OH_MY_TMUX_REPO_URL:-https://github.com/gpakosz/.tmux.git}"

  PROXY_ENV_FILE="$TARGET_HOME/.config/dev-bootstrap/proxy.env"
  OH_MY_ZSH_DIR="$TARGET_HOME/.oh-my-zsh"
  OH_MY_TMUX_DIR="$TARGET_HOME/.tmux"

  IFS=' ' read -r -a BASE_PACKAGE_ARRAY <<< "$BASE_PACKAGES"
}

ensure_prereqs() {
  need_cmd bash
  need_cmd getent
}

is_http_proxy() {
  [[ "$1" =~ ^https?:// ]]
}

write_file_as_root() {
  local path="$1"
  local content="$2"
  local temp_file

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[DRY-RUN] write root file %s\n' "$path"
    return 0
  fi

  temp_file="$(mktemp)"
  printf '%s' "$content" > "$temp_file"
  if [[ "$(id -u)" -eq 0 ]]; then
    install -m 0644 "$temp_file" "$path"
  else
    sudo install -m 0644 "$temp_file" "$path"
  fi
  rm -f "$temp_file"
}

write_file_as_target_user() {
  local path="$1"
  local content="$2"
  local temp_file

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[DRY-RUN] write user file %s\n' "$path"
    return 0
  fi

  temp_file="$(mktemp)"
  printf '%s' "$content" > "$temp_file"

  if [[ "$(id -un)" == "$TARGET_USER" ]]; then
    install -D -m 0644 "$temp_file" "$path"
  elif [[ "$(id -u)" -eq 0 ]]; then
    install -D -o "$TARGET_USER" -g "$TARGET_GROUP" -m 0644 "$temp_file" "$path"
  else
    sudo install -D -o "$TARGET_USER" -g "$TARGET_GROUP" -m 0644 "$temp_file" "$path"
  fi

  rm -f "$temp_file"
}

grant_sudo_access() {
  [[ "$GRANT_SUDO" -eq 1 ]] || return 0

  need_root_or_sudo
  need_cmd usermod

  log "Granting sudo access to $TARGET_USER"
  as_root usermod -aG sudo "$TARGET_USER"

  if [[ "$SUDO_NOPASSWD" -eq 1 ]]; then
    log "Creating passwordless sudo rule for $TARGET_USER"
    write_file_as_root "/etc/sudoers.d/90-${TARGET_USER}-bootstrap" "$TARGET_USER ALL=(ALL:ALL) NOPASSWD:ALL
"
    as_root chmod 0440 "/etc/sudoers.d/90-${TARGET_USER}-bootstrap"
  fi
}

apply_proxy_config() {
  [[ "$CONFIGURE_PROXY" -eq 1 ]] || {
    log "CONFIGURE_PROXY=0, skipping proxy setup"
    return 0
  }

  log "Writing shell proxy environment to $PROXY_ENV_FILE"
  write_file_as_target_user "$PROXY_ENV_FILE" "export http_proxy='${HTTP_PROXY}'
export https_proxy='${HTTPS_PROXY}'
export all_proxy='${ALL_PROXY}'
export no_proxy='${NO_PROXY}'
export HTTP_PROXY='${HTTP_PROXY}'
export HTTPS_PROXY='${HTTPS_PROXY}'
export ALL_PROXY='${ALL_PROXY}'
export NO_PROXY='${NO_PROXY}'
"

  need_root_or_sudo
  if [[ -n "$APT_HTTP_PROXY" || -n "$APT_HTTPS_PROXY" ]]; then
    if [[ -n "$APT_HTTP_PROXY" ]] && ! is_http_proxy "$APT_HTTP_PROXY"; then
      warn "APT_HTTP_PROXY is not HTTP(S); skipping apt proxy config"
    elif [[ -n "$APT_HTTPS_PROXY" ]] && ! is_http_proxy "$APT_HTTPS_PROXY"; then
      warn "APT_HTTPS_PROXY is not HTTP(S); skipping apt proxy config"
    else
      log "Writing apt proxy config"
      write_file_as_root "/etc/apt/apt.conf.d/80proxy" "Acquire::http::Proxy \"${APT_HTTP_PROXY}\";
Acquire::https::Proxy \"${APT_HTTPS_PROXY}\";
"
    fi
  else
    log "No apt proxy configured; removing existing apt proxy file"
    as_root rm -f /etc/apt/apt.conf.d/80proxy
  fi

  if command -v git >/dev/null 2>&1; then
    log "Configuring git proxy"
    if [[ -n "$GIT_HTTP_PROXY" ]]; then
      as_target_user "git config --global http.proxy $(printf '%q' "$GIT_HTTP_PROXY")"
    else
      as_target_user "git config --global --unset-all http.proxy || true"
    fi

    if [[ -n "$GIT_HTTPS_PROXY" ]]; then
      as_target_user "git config --global https.proxy $(printf '%q' "$GIT_HTTPS_PROXY")"
    else
      as_target_user "git config --global --unset-all https.proxy || true"
    fi

    as_target_user "git config --global url.'https://'.insteadOf git://"
  else
    warn "git is not installed yet; git proxy will be configured after git is available"
  fi

  if command -v npm >/dev/null 2>&1; then
    log "Configuring npm proxy and registry"
    if [[ -n "$NPM_PROXY" ]]; then
      as_target_user "npm config set proxy $(printf '%q' "$NPM_PROXY")"
    else
      as_target_user "npm config delete proxy || true"
    fi

    if [[ -n "$NPM_HTTPS_PROXY" ]]; then
      as_target_user "npm config set https-proxy $(printf '%q' "$NPM_HTTPS_PROXY")"
    else
      as_target_user "npm config delete https-proxy || true"
    fi

    as_target_user "npm config set registry $(printf '%q' "$NPM_REGISTRY")"
  else
    warn "npm is not installed yet; npm proxy will be configured after npm is available"
  fi
}

clear_proxy_config() {
  log "Clearing proxy environment file"
  as_target_user "rm -f $(printf '%q' "$PROXY_ENV_FILE")"

  need_root_or_sudo
  log "Removing apt proxy config"
  as_root rm -f /etc/apt/apt.conf.d/80proxy

  if command -v git >/dev/null 2>&1; then
    as_target_user "git config --global --unset-all http.proxy || true"
    as_target_user "git config --global --unset-all https.proxy || true"
  fi

  if command -v npm >/dev/null 2>&1; then
    as_target_user "npm config delete proxy || true"
    as_target_user "npm config delete https-proxy || true"
  fi
}

resolve_available_packages() {
  local available=()
  local pkg

  for pkg in "$@"; do
    if apt-cache show "$pkg" >/dev/null 2>&1; then
      available+=("$pkg")
    else
      warn "Skipping unavailable package: $pkg"
    fi
  done

  printf '%s\n' "${available[@]}"
}

install_base_packages() {
  [[ "$INSTALL_BASE_PACKAGES" -eq 1 ]] || {
    log "INSTALL_BASE_PACKAGES=0, skipping base package installation"
    return 0
  }

  need_root_or_sudo
  need_cmd apt-get
  need_cmd apt-cache

  log "Installing base packages"
  as_root env DEBIAN_FRONTEND=noninteractive apt-get update

  mapfile -t available_packages < <(resolve_available_packages "${BASE_PACKAGE_ARRAY[@]}")
  if [[ "${#available_packages[@]}" -eq 0 ]]; then
    die "No installable base packages were found in the current apt sources"
  fi

  as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "${available_packages[@]}"
}

install_nodejs() {
  [[ "$INSTALL_NODEJS" -eq 1 ]] || {
    log "INSTALL_NODEJS=0, skipping Node.js installation"
    return 0
  }

  need_root_or_sudo
  need_cmd apt-get

  log "Installing nodejs and npm from Debian repositories"
  as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs npm
}

backup_if_needed() {
  local dest="$1"
  local src="$2"

  if [[ ! -e "$dest" && ! -L "$dest" ]]; then
    return 0
  fi

  if [[ -L "$dest" ]] && [[ "$(readlink "$dest")" == "$src" ]]; then
    return 0
  fi

  local backup_path="${dest}.bak.$(date +%Y%m%d%H%M%S)"
  as_target_user "mv $(printf '%q' "$dest") $(printf '%q' "$backup_path")"
}

link_user_file() {
  local src="$1"
  local dest="$2"

  backup_if_needed "$dest" "$src"
  as_target_user "mkdir -p $(printf '%q' "$(dirname "$dest")")"
  as_target_user "ln -sfn $(printf '%q' "$src") $(printf '%q' "$dest")"
}

link_dotfiles() {
  log "Linking dotfiles into $TARGET_HOME"

  link_user_file "$SCRIPT_DIR/dotfiles/shell/profile" "$TARGET_HOME/.profile"
  link_user_file "$SCRIPT_DIR/dotfiles/zsh/zshrc" "$TARGET_HOME/.zshrc"
  link_user_file "$SCRIPT_DIR/dotfiles/git/gitconfig" "$TARGET_HOME/.gitconfig"
  link_user_file "$SCRIPT_DIR/dotfiles/tmux/tmux.conf.local" "$TARGET_HOME/.tmux.conf.local"

  if [[ -f "$OH_MY_TMUX_DIR/.tmux.conf" ]]; then
    link_user_file "$OH_MY_TMUX_DIR/.tmux.conf" "$TARGET_HOME/.tmux.conf"
  else
    link_user_file "$SCRIPT_DIR/dotfiles/tmux/tmux.conf" "$TARGET_HOME/.tmux.conf"
  fi
}

install_shell_tools() {
  [[ "$INSTALL_SHELL_TOOLS" -eq 1 ]] || {
    log "INSTALL_SHELL_TOOLS=0, skipping shell setup"
    return 0
  }

  need_cmd git

  if [[ ! -d "$OH_MY_ZSH_DIR" ]]; then
    log "Cloning Oh My Zsh"
    as_target_user "git clone --depth=1 $(printf '%q' "$OH_MY_ZSH_REPO_URL") $(printf '%q' "$OH_MY_ZSH_DIR")"
  else
    log "Oh My Zsh already exists: $OH_MY_ZSH_DIR"
  fi

  if [[ ! -d "$OH_MY_TMUX_DIR" ]]; then
    log "Cloning Oh My Tmux"
    as_target_user "git clone --depth=1 $(printf '%q' "$OH_MY_TMUX_REPO_URL") $(printf '%q' "$OH_MY_TMUX_DIR")"
  else
    log "Oh My Tmux already exists: $OH_MY_TMUX_DIR"
  fi

  link_dotfiles

  if [[ "$CHANGE_DEFAULT_SHELL_TO_ZSH" -eq 1 ]]; then
    local zsh_path
    zsh_path="$(command -v zsh || true)"
    if [[ -z "$zsh_path" ]]; then
      warn "zsh is not installed; cannot change default shell"
    elif [[ "$(id -u)" -eq 0 ]]; then
      log "Changing default shell for $TARGET_USER to $zsh_path"
      run usermod -s "$zsh_path" "$TARGET_USER"
    elif [[ "$(id -un)" == "$TARGET_USER" ]]; then
      log "Attempting to change current user's shell to zsh"
      run chsh -s "$zsh_path" || warn "chsh failed; run it manually later"
    else
      warn "Cannot change shell for another user without root"
    fi
  fi
}

doctor() {
  cat <<EOF
ACTION=$ACTION
CONFIG_FILE=$CONFIG_FILE
TARGET_USER=$TARGET_USER
TARGET_HOME=$TARGET_HOME
TARGET_GROUP=$TARGET_GROUP
GRANT_SUDO=$GRANT_SUDO
SUDO_NOPASSWD=$SUDO_NOPASSWD
INSTALL_BASE_PACKAGES=$INSTALL_BASE_PACKAGES
INSTALL_NODEJS=$INSTALL_NODEJS
INSTALL_SHELL_TOOLS=$INSTALL_SHELL_TOOLS
CONFIGURE_PROXY=$CONFIGURE_PROXY
CHANGE_DEFAULT_SHELL_TO_ZSH=$CHANGE_DEFAULT_SHELL_TO_ZSH
HTTP_PROXY=$HTTP_PROXY
HTTPS_PROXY=$HTTPS_PROXY
ALL_PROXY=$ALL_PROXY
NO_PROXY=$NO_PROXY
APT_HTTP_PROXY=$APT_HTTP_PROXY
APT_HTTPS_PROXY=$APT_HTTPS_PROXY
GIT_HTTP_PROXY=$GIT_HTTP_PROXY
GIT_HTTPS_PROXY=$GIT_HTTPS_PROXY
NPM_PROXY=$NPM_PROXY
NPM_HTTPS_PROXY=$NPM_HTTPS_PROXY
NPM_REGISTRY=$NPM_REGISTRY
OH_MY_ZSH_REPO_URL=$OH_MY_ZSH_REPO_URL
OH_MY_TMUX_REPO_URL=$OH_MY_TMUX_REPO_URL
EOF
}

run_init() {
  grant_sudo_access
  apply_proxy_config
  install_base_packages
  install_nodejs
  install_shell_tools

  if command -v git >/dev/null 2>&1 || command -v npm >/dev/null 2>&1; then
    apply_proxy_config
  fi

  link_dotfiles
  log "Bootstrap completed"
}

main() {
  parse_args "$@"
  load_config
  ensure_prereqs

  case "$ACTION" in
    init)
      run_init
      ;;
    install-base)
      install_base_packages
      ;;
    install-node)
      install_nodejs
      ;;
    install-shell)
      install_shell_tools
      ;;
    link-dotfiles)
      link_dotfiles
      ;;
    apply-proxy)
      apply_proxy_config
      ;;
    clear-proxy)
      clear_proxy_config
      ;;
    doctor)
      doctor
      ;;
    *)
      usage
      die "Unknown action: $ACTION"
      ;;
  esac
}

main "$@"




