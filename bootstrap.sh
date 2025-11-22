#!/usr/bin/env bash
set -Eeuo pipefail

# Bootstrap Fedora workstation/dev environment
# Idempotent: safe to run multiple times

# Config
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
ROOT_DIR="$SCRIPT_DIR"
CONF_FILE="${ROOT_DIR}/config/bootstrap.conf"
PKG_FILE="${ROOT_DIR}/config/packages.conf"

# Defaults (can be overridden in bootstrap.conf)
ENABLE_RUST=${ENABLE_RUST:-false}
ENABLE_FLATPAK=${ENABLE_FLATPAK:-true}
EXTRA_PACKAGES=("${EXTRA_PACKAGES[@]:-}")
INSTALL_DOTFILES=${INSTALL_DOTFILES:-false}
DOTFILES_INSTALL_PATH=${DOTFILES_INSTALL_PATH:-}

log() { printf "[%s] %s\n" "$(date +%H:%M:%S)" "$*"; }
warn() { printf "[WARN] %s\n" "$*" >&2; }

run_sudo() {
  if [[ $EUID -ne 0 ]]; then
    sudo "$@"
  else
    "$@"
  fi
}

load_conf() {
  if [[ -f "$CONF_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONF_FILE"
  fi
}

load_packages() {
  if [[ -f "$PKG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$PKG_FILE"
  fi
}

ensure_fedora() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    if [[ "${ID:-}" != fedora ]]; then
      warn "This script targets Fedora; detected ${PRETTY_NAME:-${ID:-unknown}}"
      exit 1
    fi
  else
    warn "Cannot determine OS; /etc/os-release missing."
    exit 1
  fi
}

enable_rpmfusion() {
  local ver
  ver=$(rpm -E %fedora)
  local free_pkg="rpmfusion-free-release-${ver}.noarch"
  local nonfree_pkg="rpmfusion-nonfree-release-${ver}.noarch"
  if rpm -q "$free_pkg" "$nonfree_pkg" >/dev/null 2>&1; then
    log "RPM Fusion already enabled"
    return 0
  fi
  log "Enabling RPM Fusion (free + nonfree)"
  run_sudo dnf install -y \
    "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${ver}.noarch.rpm" \
    "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${ver}.noarch.rpm"
}

is_container() {
  # Detect if we're running in a container
  [[ -f /.dockerenv ]] || [[ -n "${container:-}" ]] || grep -q container=lxc /proc/1/environ 2>/dev/null || [[ "$(systemd-detect-virt 2>/dev/null)" != "none" ]]
}

enable_flathub() {
  # Skip if disabled in config
  if [[ "$ENABLE_FLATPAK" != true ]]; then
    log "Flatpak disabled (set ENABLE_FLATPAK=true to enable)"
    return 0
  fi

  # Skip Flatpak setup in containers as it typically won't work properly
  if is_container; then
    log "Container environment detected; skipping Flatpak setup"
    return 0
  fi

  # Install flatpak if not present
  if ! command -v flatpak >/dev/null 2>&1; then
    log "Installing flatpak"
    run_sudo dnf install -y flatpak || {
      warn "Failed to install flatpak"
      return 0
    }
  fi

  if flatpak remote-list | awk '{print $1}' | grep -qx flathub; then
    log "Flathub already enabled"
    return 0
  fi

  log "Enabling Flathub"
  flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
}

create_local_bin() {
  log "Ensuring ~/.local/bin exists and is in PATH"
  mkdir -p "$HOME/.local/bin"
  # Add to ~/.bash_profile and ~/.zprofile if absent
  local export_line="export PATH=\"\$HOME/.local/bin:\$PATH\""
  grep -Fq "$export_line" "$HOME/.bash_profile" 2>/dev/null || echo "$export_line" >>"$HOME/.bash_profile"
  grep -Fq "$export_line" "$HOME/.zprofile" 2>/dev/null || echo "$export_line" >>"$HOME/.zprofile"
}

install_dev_tools_group() {
  log "Installing development-tools group (if needed)"
  if dnf group list --installed | grep -qi "development tools"; then
    log "development-tools already installed"
    return 0
  fi
  run_sudo dnf group install -y 'development-tools'
}

install_copr_and_extra() {
  if ! command -v dnf >/dev/null 2>&1; then
    warn "dnf not found; skipping COPR setup"
    return 0
  fi

  # Install COPR plugin if not available
  if ! dnf copr --help >/dev/null 2>&1; then
    log "Installing dnf-plugins-core for COPR support"
    run_sudo dnf install -y dnf-plugins-core || {
      warn "Failed to install COPR plugin"
      return 0
    }
  fi

  # Enable COPR repos from packages.conf
  for repo in "${COPR_REPOS[@]:-}"; do
    log "Enabling COPR repo: $repo"
    run_sudo dnf -y copr enable "$repo" || warn "Could not enable COPR $repo"
  done
}

install_packages() {
  if ! command -v dnf >/dev/null 2>&1; then
    warn "dnf not found; cannot install packages"
    return 0
  fi
  # Get package list from packages.conf
  local pkgs=("${DNF_ALL[@]:-}")
  # Merge EXTRA_PACKAGES from bootstrap.conf
  pkgs+=("${EXTRA_PACKAGES[@]:-}")
  # Install missing packages
  local to_install=()
  for p in "${pkgs[@]}"; do
    rpm -q "$p" >/dev/null 2>&1 || to_install+=("$p")
  done
  if ((${#to_install[@]} == 0)); then
    log "All packages already installed"
  else
    log "Installing ${#to_install[@]} packages via dnf"
    # Use --skip-unavailable for cross-version compatibility (e.g., wget conflict on Fedora 43)
    run_sudo dnf install -y --skip-unavailable "${to_install[@]}"
  fi
}

# Flatpak apps can be installed manually as needed:
# flatpak install flathub com.google.Chrome
# flatpak install flathub org.mozilla.firefox
# flatpak install flathub com.spotify.Client

install_rust_and_cargo_tools() {
  [[ "$ENABLE_RUST" == true ]] || {
    log "Rust installation disabled (set ENABLE_RUST=true to enable)"
    return 0
  }

  # Install Rust if not available
  if ! command -v cargo >/dev/null 2>&1; then
    log "Installing Rust toolchain via rustup"
    if ! curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y; then
      warn "Failed to install Rust"
      return 0
    fi
    # shellcheck disable=SC1090
    # shellcheck disable=SC1091
    if [[ -f "$HOME/.cargo/env" ]]; then
      source "$HOME/.cargo/env"
    else
      warn "Rust installed but environment file not found"
      return 0
    fi
  fi
}

install_dra() {
  # Install dra (Download Release Assets) - foundational tool for GitHub releases
  if ! command -v dra >/dev/null 2>&1; then
    log "Installing dra (Download Release Assets)"
    curl --proto '=https' --tlsv1.2 -sSf https://raw.githubusercontent.com/devmatteini/dra/refs/heads/main/install.sh | bash -s -- --to ~/.local/bin || warn "Failed to install dra"
  fi
}

install_dra_tools() {
  # Install tools from GitHub releases using dra
  if ! command -v dra >/dev/null 2>&1; then
    warn "dra not available; skipping dra-based tools installation"
    return 0
  fi

  # Install tools defined in DRA_TOOLS array from packages.conf
  for tool_repo in "${DRA_TOOLS[@]:-}"; do
    local tool_name
    tool_name="${tool_repo##*/}"  # Extract repo name as tool name
    if ! command -v "$tool_name" >/dev/null 2>&1; then
      log "Installing $tool_name via dra"
      dra download --install --output ~/.local/bin -a "$tool_repo" || warn "Failed to install $tool_name via dra"
    fi
  done
}

setup_helix_config() {
  local hx_dir="$HOME/.config/helix"
  local hx_conf="$hx_dir/config.toml"
  local source_conf="${ROOT_DIR}/files/helix/config.toml"

  if [[ -f "$hx_conf" ]]; then
    log "Helix config already exists; leaving as-is"
    return 0
  fi

  if [[ ! -f "$source_conf" ]]; then
    warn "Source helix config not found at $source_conf; skipping"
    return 1
  fi

  log "Installing Helix config from ${source_conf#$ROOT_DIR/} to ${hx_conf#$HOME/}"
  mkdir -p "$hx_dir"
  cp "$source_conf" "$hx_conf"
}

install_broot() {
  local broot_bin="$HOME/.local/bin/broot"
  local broot_url=""
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64)
      broot_url="https://dystroy.org/broot/download/x86_64-linux/broot"
      ;;
    aarch64 | arm64)
      broot_url="https://dystroy.org/broot/download/aarch64-unknown-linux-gnu/broot"
      ;;
    *)
      warn "Unsupported architecture '$arch' for broot install"
      return 1
      ;;
  esac

  if [[ ! -x "$broot_bin" ]]; then
    log "Installing broot to $broot_bin"
    if curl -L --fail "$broot_url" -o "$broot_bin"; then
      chmod +x "$broot_bin"
    else
      warn "Failed to download broot binary"
      rm -f "$broot_bin"
      return 1
    fi
  else
    log "broot already present at $broot_bin"
  fi

  local broot_cmd
  if broot_cmd=$(command -v broot 2>/dev/null); then
    :
  elif [[ -x "$broot_bin" ]]; then
    broot_cmd="$broot_bin"
  else
    warn "broot binary not found after installation; skipping shell integration"
    return 1
  fi

  local target_file marker shell_function
  local shell_post="$HOME/.shell_post"
  marker="# >>> fedora-bootstrap broot integration >>>"
  if [[ -f "$shell_post" ]]; then
    target_file="$shell_post"
  else
    target_file="$HOME/.zshrc"
  fi

  if [[ -f "$target_file" ]] && grep -Fq "$marker" "$target_file"; then
    log "broot shell function already present in ${target_file#$HOME/}"
  else
    if ! shell_function="$("$broot_cmd" --print-shell-function zsh)"; then
      warn "Unable to retrieve broot shell function"
      return 1
    fi
    log "Adding broot shell function to ${target_file#$HOME/}"
    {
      echo ""
      echo "$marker"
      printf '%s\n' "$shell_function"
      echo "# <<< fedora-bootstrap broot integration <<<"
    } >>"$target_file"
  fi

  if ! "$broot_cmd" --set-install-state installed >/dev/null 2>&1; then
    warn "Could not set broot install state"
  fi
}

setup_lazyvim() {
  # Only if not already configured
  local nvconf="$HOME/.config/nvim"
  if [[ -d "$nvconf" && -f "$nvconf/init.lua" ]]; then
    log "Neovim config already present; skipping LazyVim clone"
    return 0
  fi
  log "Setting up LazyVim starter"
  if ! git clone https://github.com/LazyVim/starter "$nvconf"; then
    warn "Failed to setup LazyVim"
    return 0
  fi
  rm -rf "$nvconf/.git"
}

install_dotfiles_from_path() {
  if [[ "$INSTALL_DOTFILES" != true ]]; then
    log "Dotfiles install disabled"
    return 2
  fi

  if [[ -z "$DOTFILES_INSTALL_PATH" ]]; then
    warn "DOTFILES_INSTALL_PATH not set; skipping dotfiles install"
    return 1
  fi

  if [[ ! -d "$DOTFILES_INSTALL_PATH" ]]; then
    warn "Dotfiles path '$DOTFILES_INSTALL_PATH' not found; skipping dotfiles install"
    return 1
  fi

  local install_script="$DOTFILES_INSTALL_PATH/install.sh"
  if [[ ! -f "$install_script" ]]; then
    warn "Dotfiles install script not found at $install_script; skipping dotfiles install"
    return 1
  fi

  log "Running dotfiles installer from $DOTFILES_INSTALL_PATH"
  if ! (cd "$DOTFILES_INSTALL_PATH" && bash ./install.sh); then
    warn "Dotfiles installer reported failure"
    return 1
  fi

  return 0
}

change_default_shell_to_zsh() {
  if [[ "$SHELL" == *"zsh"* ]]; then
    log "Default shell already zsh"
    return 0
  fi
  if command -v zsh >/dev/null 2>&1; then
    local zsh_path
    zsh_path="$(command -v zsh)"
    log "Changing default shell to $zsh_path"
    run_sudo chsh -s "$zsh_path" "$USER" || warn "Could not change default shell"
  else
    warn "zsh not found; skipping chsh"
  fi
}


main() {
  ensure_fedora
  load_conf
  load_packages
  create_local_bin
  enable_rpmfusion
  enable_flathub
  install_copr_and_extra
  install_dev_tools_group
  install_packages
  setup_helix_config
  install_dra
  install_dra_tools
  install_rust_and_cargo_tools
  setup_lazyvim
  local dotfiles_status
  if install_dotfiles_from_path; then
    dotfiles_status=0
  else
    dotfiles_status=$?
  fi

  if [[ "$dotfiles_status" -eq 0 ]]; then
    change_default_shell_to_zsh
  elif [[ "$dotfiles_status" -eq 2 ]]; then
    log "Default shell left unchanged (dotfiles install skipped)"
  else
    warn "Skipping default shell change because dotfiles install did not run"
  fi
  install_broot || warn "broot installation failed; continuing"
  log "Bootstrap complete. You may need to log out/in for some changes to take effect."
}

main "$@"
