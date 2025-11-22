# Fedora Bootstrap

Shell script to quickly bootstrap a Fedora system (desktop, server, or WSL). Safe to rerun and adjusts automatically for container environments.

## Run It

```bash
git clone <repo-url> fedora-bootstrap
cd fedora-bootstrap
./bootstrap.sh
```

## What It Sets Up

- Repos: RPM Fusion (free/nonfree), Flathub, COPR (`dejan/lazygit`, `varlad/yazi`)
- Packages: dev tools (`git`, `neovim`, `helix`, `lazygit`, `tree-sitter-cli`)
- CLI staples (`fzf`, `ripgrep`, `fd`, `bat`, `zoxide`, `btop`, `duf`)
- container/K8s tools (`kubectl`, `helm`, `k9s`, `stern`)
- utilities (`tmux`, `yazi`, `ouch`, `p7zip`, `curl`, `wget`, `jq`, `yq`)
- GitHub releases via `dra`: `eza`, `starship`
- Optional Rust toolchain through `rustup`
- Optional dotfiles installer at `DOTFILES_INSTALL_PATH`
- Flatpak enablement (skipped automatically in containers)

## Configure

Copy `config/bootstrap.conf.example` to `config/bootstrap.conf` and adjust:

```bash
ENABLE_RUST=true       # install rustup toolchain
ENABLE_FLATPAK=false   # opt out of Flatpak setup
EXTRA_PACKAGES=(podman virt-manager)
INSTALL_DOTFILES=true
DOTFILES_INSTALL_PATH="$HOME/silentcastle/projects/dot_zshrc" # The dotfiles path must contain an `install.sh` script; otherwise the script logs a warning and keeps the current shell.
```
