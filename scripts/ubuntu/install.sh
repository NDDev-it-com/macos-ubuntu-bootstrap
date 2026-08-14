#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/common.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=privilege.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/privilege.sh"
# shellcheck source=server.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/server.sh"

RLDYOUR_DRY_RUN="${RLDYOUR_DRY_RUN:-1}"
PROFILE="${RLDYOUR_PROFILE:-server}"
SKIP_SYSTEM="${RLDYOUR_SKIP_SYSTEM:-0}"
SKIP_AI="${RLDYOUR_SKIP_AI:-0}"
SKIP_LSPS="${RLDYOUR_SKIP_LSPS:-0}"
SKIP_CHECKS="${RLDYOUR_SKIP_CHECKS:-0}"
GUI_ENABLED="${RLDYOUR_GUI_ENABLED:-0}"
DOCKER_MODE="${RLDYOUR_DOCKER_MODE:-rootful}"
LOCAL_EXECUTION_POLICY="${RLDYOUR_LOCAL_EXECUTION_POLICY:-container-execution-only}"
HARDEN_SSH="${RLDYOUR_HARDEN_SSH:-0}"
ENABLE_UFW="${RLDYOUR_ENABLE_UFW:-0}"
WITH_FAIL2BAN="${RLDYOUR_WITH_FAIL2BAN:-0}"
# Login shell change is explicit opt-in only; never mutated silently.
SET_LOGIN_SHELL="${RLDYOUR_SET_LOGIN_SHELL:-0}"

NODE_VERSION="24.19.0"
NODE_SHA256_X64="14b342e71204f811bde6153be8e04b62aef63c236fef92b55f9c83154b409647"
NODE_SHA256_ARM64="01443c1e1a29e531ccad5a46fefa6df490d2189c49f7955904aecdbb0fe86fdc"
UV_VERSION="0.12.4"
UV_SHA256_X64="c8c60f47e6f88d18dbf6f33d7279fb1fbf7ae76631768152cf5578c3d65729b4"
UV_SHA256_ARM64="49d881b3403187e1f1789720881e77e4251ad4259d86c4844862657d2a35d13f"
BUN_VERSION="1.3.14"
BUN_SHA256_X64="951ee2aee855f08595aeec6225226a298d3fea83a3dcd6465c09cbccdf7e848f"
BUN_SHA256_X64_BASELINE="a063908ae08b7852ca10939bbdc6ceed3ddabce8fb9402dce83d65d73b36e6c7"
BUN_SHA256_ARM64="a27ffb63a8310375836e0d6f668ae17fa8d8d18b88c37c821c65331973a19a3b"
# Go and Rust are desktop language-server hosts, exactly like Node and uv: they
# back gopls and rust-analyzer over the estate's Go and Rust sources. Installing
# them does not authorize local project builds; the desktop execution policy
# stays `source-lsp-only` and the server profile never receives them (project
# builds belong in Docker under `container-execution-only`).
GO_VERSION="1.26.6"
GO_SHA256_AMD64="708effb774be8237570d0add163225abbdfaf4fca28b2611df167beba4feef89"
GO_SHA256_ARM64="d0507e9e9d7fe012aae570108cbd76c15de879e17130ab8cb90d4d7445cb1f2e"
# gopls publishes no prebuilt archive. It is pinned to an exact version and its
# provenance comes from the Go module checksum database (sum.golang.org), which
# is a transparency log rather than a hash this repository tracks. GOFLAGS and
# GONOSUMDB are never relaxed.
GOPLS_VERSION="v0.23.0"
# One combined archive per architecture carries rustc, cargo, rust-std, clippy,
# rustfmt and rust-analyzer, so a single tracked hash covers the whole host.
RUST_VERSION="1.97.1"
RUST_CHANNEL_DATE="2026-07-16"
RUST_SHA256_X86_64="88f28fa9af20594179f85d6df67078dfd6fa93e2f6da5e1e9b0ac4997988ca4f"
RUST_SHA256_AARCH64="9a7a2c336b4787f1b72f6bab7c35d5b7af2fd03cbd39b4fc721466a70d402a7d"
# Dart is the third desktop language-server host (ADR 0005), on the same footing
# as Go and Rust. One self-contained SDK archive carries `dart language-server`
# (the analysis server) and `dart mcp-server` (the Dart/Flutter MCP transport the
# rldyour-mcps marketplace declares), so a single tracked hash covers both. The
# SDK never mutates its own install tree, which is what keeps it compatible with
# the runtime-receipt contract; the Flutter SDK is deliberately not installed
# here because its bin/cache self-populates at runtime and would break that.
DART_VERSION="3.13.0"
DART_SHA256_X64="87902573facd8acacac7ee1fe73fa8d0668e06065016068e2ed6c5c99c6b1ee0"
DART_SHA256_ARM64="20141a0653327939bb20c4b87b231226beba1128d8a9aedbb30cb5af1a2790d4"
# Prompt/history/completion pillars — parity with the macOS brew baseline
# (starship, atuin, carapace). Installed as pinned standalone artifacts, never
# via apt (stale) or a piped install script. Linux x64 + arm64 tarball SHA-256
# from each project's signed GitHub release checksum files.
STARSHIP_VERSION="1.26.0"
STARSHIP_SHA256_X64="321f0dd7af8340a5f2e6a8fec6538a04f617486f9ec70d878f91c09cd8deef22"
STARSHIP_SHA256_ARM64="dc30189378d2f2e287384e8a692d3f95ad1df64cf0e8c36aa9201516028aed6b"
ATUIN_VERSION="18.17.1"
ATUIN_SHA256_X64="72395cf7ae86b3698c04ba4a331773e7c4f027630bfd2b522bb14d4c80cb2410"
ATUIN_SHA256_ARM64="9412210a9cdd6d0ff7635693e940096d82b368628326d334d27a8ca0ba173b0f"
CARAPACE_VERSION="1.7.3"
CARAPACE_SHA256_X64="35ab52bfe7bdd8296d90c3687660bde80497599badde840ab615d2f421f5f053"
CARAPACE_SHA256_ARM64="b2456cb09d77004db87de2567d6d7588a61ceb4724522c463e2b1c1f87b4d4b9"

APT_SOURCE_PACKAGES=(
  ca-certificates curl gpg gnupg git jq python3 python3-venv
  shellcheck shfmt clangd zsh unzip xz-utils wget zip lsb-release yamllint
  fd-find bat fzf zoxide tmux btop duf hexyl gh ripgrep httpie miller
  software-properties-common wl-clipboard libsecret-tools
)

# Registry-backed language servers + source checks, pinned to exact versions
# for reproducibility (RVR-P2-003). Two package identities are corrected here:
# `biome` (an unrelated squatter package) -> `@biomejs/biome` (the Biome
# linter), and `@ansible/language-server` (does not exist on npm) ->
# `@ansible/ansible-language-server` (the real Ansible language server).
BUN_LSP_PACKAGES=(
  "typescript@7.0.2"
  "@vtsls/language-server@0.3.0"
  "yaml-language-server@1.24.0"
  "bash-language-server@5.6.0"
  "dockerfile-language-server-nodejs@0.15.0"
  "vscode-langservers-extracted@4.10.0"
  "@taplo/cli@0.7.0"
  "gh-actions-language-server@0.0.3"
  "@biomejs/biome@2.5.4"
  "oxlint@1.74.0"
  "markdownlint-cli2@0.23.1"
  "prettier@3.9.6"
  "@ansible/ansible-language-server@26.6.0"
)

# Isolated Python source-analysis tools, pinned to exact versions so a device
# bootstrapped today and one bootstrapped next month resolve the same releases
# (RVR-P2-003). uv installs the exact pin; a divergent installed version is
# re-pinned, not silently preserved.
PYTHON_SOURCE_TOOLS=(
  "pyright==1.1.411"
  "ruff==0.15.22"
  "ty==0.0.61"
  "cmake-language-server==0.1.11"
  "basedpyright==1.39.9"
  "semgrep==1.170.0"
)

# Pinned upstream CLI artifacts: the tools macOS gets from Homebrew for which
# Ubuntu has no acceptable distribution package, either because none exists or
# because the archive lags too far behind. "Too far behind" is a judgement each
# row justifies in a comment, not a reflex — apt is preferred wherever its
# version is acceptable, which is why ripgrep, fd-find, bat and fzf are apt
# packages and not rows here. Each is a single upstream release
# artifact with a tracked per-architecture SHA-256, installed into an owned
# versioned directory with a runtime receipt — the same contract as Node, uv,
# Bun, Go, and Rust. Adding a row here is the only way to add such a tool; there
# is deliberately no second install path.
#
# Row format (semicolon-separated, no spaces inside a field):
#   name;version;kind;members_x64;members_arm64;links;sha_x64;sha_arm64;url_x64;url_arm64
#
#   kind     tar0 = tarball, binaries at the root
#            tar1 = tarball with one wrapper directory to strip
#            zip  = zip archive, binaries at the root
#            raw  = the download is the binary itself
#   members  comma-separated paths inside the unpacked tree, parallel to links
#   links    comma-separated names published into ~/.local/bin
#
# Every digest below was confirmed by downloading the artifact, not copied from
# a release note.
PINNED_SOURCE_TOOLS=(
  # Reproduce the estate's CI checks locally: these four are exactly what the
  # gitleaks, OSV, actionlint, and hadolint workflows run.
  "gitleaks;8.30.1;tar0;gitleaks;gitleaks;gitleaks;551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb;e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080;https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_linux_x64.tar.gz;https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_linux_arm64.tar.gz"
  "osv-scanner;2.5.0;raw;osv-scanner;osv-scanner;osv-scanner;edcfc41d257db36148f065055655fe3fcfc434b0b423ea67468a84c207524e0c;fe152e1a546af223e6c557cc3111a8bb3e5dc02fcbf7dbe95d26567c0f0041f2;https://github.com/google/osv-scanner/releases/download/v2.5.0/osv-scanner_linux_amd64;https://github.com/google/osv-scanner/releases/download/v2.5.0/osv-scanner_linux_arm64"
  "actionlint;1.7.12;tar0;actionlint;actionlint;actionlint;8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8;325e971b6ba9bfa504672e29be93c24981eeb1c07576d730e9f7c8805afff0c6;https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_linux_amd64.tar.gz;https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_linux_arm64.tar.gz"
  "hadolint;2.15.1;raw;hadolint;hadolint;hadolint;c7187db94eeeeca956519a6af171adc31453941a1e777961f6e680f697c8c507;f6198ef8090f404dbb771abfee086eb8c48ac177f30da7fd3510aca35b344b5d;https://github.com/hadolint/hadolint/releases/download/v2.15.1/hadolint-linux-x86_64;https://github.com/hadolint/hadolint/releases/download/v2.15.1/hadolint-linux-arm64"
  # Markdown language server. Ubuntu uses markdown-oxide rather than macOS's
  # marksman: marksman's Homebrew formula depends on dotnet@9, and a .NET
  # runtime is not something this adapter should pull onto a desktop.
  "markdown-oxide;0.25.12;tar1;markdown-oxide;markdown-oxide;markdown-oxide;ad4248cf5d3f0e9d9f120b579501c45dad9c46bfcb4ddec36d2cb85d68a58828;6634b644ff0bcc1b8fb27cc518f82618547ec43fe19d515a890e8e8756950020;https://github.com/Feel-ix-343/markdown-oxide/releases/download/v0.25.12/markdown-oxide-v0.25.12-x86_64-unknown-linux-gnu.tar.gz;https://github.com/Feel-ix-343/markdown-oxide/releases/download/v0.25.12/markdown-oxide-v0.25.12-aarch64-unknown-linux-gnu.tar.gz"
  # rldyour::ensure_git_delta_config configures delta as the global git pager on
  # both platforms, but Ubuntu never installed it, so the call silently skipped
  # on every Linux desktop.
  "delta;0.19.2;tar1;delta;delta;delta;8e695c5f586a8c53d6c3b01be0b4a422ed218bfed2a56191caebe373a1c18ab2;0bfce159a5cddd5feb3d6db4a616d883ff51253ce08ac7ec11cb1d208cfaab9e;https://github.com/dandavison/delta/releases/download/0.19.2/delta-0.19.2-x86_64-unknown-linux-gnu.tar.gz;https://github.com/dandavison/delta/releases/download/0.19.2/delta-0.19.2-aarch64-unknown-linux-gnu.tar.gz"
  "yq;4.53.3;tar0;yq_linux_amd64;yq_linux_arm64;yq;b4077cab0f9ee5ce8381e602d090daa69a0afb7e57eb9a5b20e9cb416d7f6794;42600522e7455282e11c71c9fc62dc8e98b05bcdb830210fe16eb673a871e866;https://github.com/mikefarah/yq/releases/download/v4.53.3/yq_linux_amd64.tar.gz;https://github.com/mikefarah/yq/releases/download/v4.53.3/yq_linux_arm64.tar.gz"
  # The archive also ships an `sg` shim. It is not published: upstream prints a
  # deprecation banner and exits non-zero, and on a host that has util-linux it
  # would shadow the setgid `sg`.
  "ast-grep;0.45.1;zip;ast-grep;ast-grep;ast-grep;76fb6555be6734fb5057dba8d2fb756430f374bb9e1af694cf1ce00e13238d63;9ee7ec49aada3dc05135d21977af089a33fc3154ada25bab102daca90b5098f2;https://github.com/ast-grep/ast-grep/releases/download/0.45.1/app-x86_64-unknown-linux-gnu.zip;https://github.com/ast-grep/ast-grep/releases/download/0.45.1/app-aarch64-unknown-linux-gnu.zip"
  # Command runner used across the estate's repositories. Ubuntu 26.04 ships
  # 1.45.0 against upstream 1.58.0; a justfile written against a newer feature
  # would fail on the distribution build, so the recipe runner is pinned like
  # every other tool whose exact behaviour a repository depends on. Both digests
  # were confirmed by download and matched against upstream's SHA256SUMS.
  "just;1.58.0;tar0;just;just;just;4a5cc2f53e6f0f8c59092a6cc38291eb729d46a7dd95d3ae582008881b84931d;748237128c4c40cbdabc65e841d05ceba13cc23a91eaba395495894c1d9764df;https://github.com/casey/just/releases/download/1.58.0/just-1.58.0-x86_64-unknown-linux-musl.tar.gz;https://github.com/casey/just/releases/download/1.58.0/just-1.58.0-aarch64-unknown-linux-musl.tar.gz"
  # File encryption for estate secrets at rest. Ubuntu ships 1.2.1 against
  # upstream 1.3.1; for a cryptographic tool the current release is the one to
  # carry. The archive also contains age-inspect and age-plugin-batchpass, which
  # are deliberately not published: only the two commands the estate uses are
  # linked, so the managed PATH stays exactly what the contract declares.
  "age;1.3.1;tar1;age,age-keygen;age,age-keygen;age,age-keygen;bdc69c09cbdd6cf8b1f333d372a1f58247b3a33146406333e30c0f26e8f51377;c6878a324421b69e3e20b00ba17c04bc5c6dab0030cfe55bf8f68fa8d9e9093a;https://github.com/FiloSottile/age/releases/download/v1.3.1/age-v1.3.1-linux-amd64.tar.gz;https://github.com/FiloSottile/age/releases/download/v1.3.1/age-v1.3.1-linux-arm64.tar.gz"
  # Interactive terminal tools that templates/terminal/zshrc binds an alias or
  # abbreviation to. Every one of these guards was dead on Ubuntu: the tool was
  # in the macOS brew set and in no Ubuntu manifest, so `command -v` was false
  # and the shell silently offered less than the template describes. None is
  # packaged acceptably across both supported releases -- eza is absent from
  # 24.04, lazygit and difftastic are in no Ubuntu archive at all, and jaq
  # arrived only in 24.10 -- so each is pinned rather than left to apt.
  "eza;0.23.5;tar0;eza;eza;eza;35c70c5c43c29108075e58b893234c67ef585f0b53a7eaf8e9e7d4eec9f339b4;40b87ae8628aa2ff0f0d2dc24ab52f689631366385c3da630bae745671fd71ec;https://github.com/eza-community/eza/releases/download/v0.23.5/eza_x86_64-unknown-linux-gnu.tar.gz;https://github.com/eza-community/eza/releases/download/v0.23.5/eza_aarch64-unknown-linux-gnu.tar.gz"
  "lazygit;0.64.1;tar0;lazygit;lazygit;lazygit;f8ea237c41f194cd799b48505518bfdaae4edf5a2ad6bd3d898e939785ee4532;8b7ca3b344e60340ad1f89f29b9868ee39bcaba5bb92ee818bbe65476bb8b6e7;https://github.com/jesseduffield/lazygit/releases/download/v0.64.1/lazygit_0.64.1_linux_x86_64.tar.gz;https://github.com/jesseduffield/lazygit/releases/download/v0.64.1/lazygit_0.64.1_linux_arm64.tar.gz"
  # difftastic publishes its binary as `difft`; the row is named for the command
  # it publishes, like every other row here.
  "difft;0.70.0;tar0;difft;difft;difft;2997d2bbe620534edbd79b0049f00ce84eef3fedb15c7822456d58e38d8b05c9;e729684907d67d1a1727a08f443877e19e40eeb2efebcd95c1b8f7fee4284e8e;https://github.com/Wilfred/difftastic/releases/download/0.70.0/difft-x86_64-unknown-linux-gnu.tar.gz;https://github.com/Wilfred/difftastic/releases/download/0.70.0/difft-aarch64-unknown-linux-gnu.tar.gz"
  "jaq;3.1.1;raw;jaq;jaq;jaq;5922c7b67d9bd6841d6676d1f954410c6bf04b47203dcb661c4f052dfef7f454;bdda42d5a8c060a2c7916b287a227e7750d5fccbd4c37aacf0ab863010921829;https://github.com/01mf02/jaq/releases/download/v3.1.1/jaq-x86_64-unknown-linux-gnu;https://github.com/01mf02/jaq/releases/download/v3.1.1/jaq-aarch64-unknown-linux-gnu"
)

# User-selected CLI tools that are not language hosts, LSPs, or scanners but
# belong on the desktop estate. Same row contract as PINNED_SOURCE_TOOLS
# (name;version;kind;members_x64;members_arm64;links;sha_x64;sha_arm64;url_x64;url_arm64).
# These are raw GitHub release binaries (kind=raw): the downloaded artifact IS
# the executable, no archive to unpack. Every digest was confirmed by
# downloading the artifact.
#
# herdr ships its own `herdr update` command that fetches https://herdr.dev/latest.json;
# that live manifest is discovery-only. The canonical source tag, URLs, and
# architecture hashes live in config/rldyour-contract.json and parity tests bind
# this shell row to them; installation never resolves mutable `latest` state.
USER_TOOLS=(
  "herdr;0.8.0;raw;herdr;herdr;herdr;b872ea7e40fa2cb17e857ac9b62b1bf26db7b403c622f5d2f3f5b35f6e9acd28;f647ac66468d9efbc642fe534fb284468f0aea60641606fc008dfc0d82a3ca87;https://github.com/herdrdev/herdr/releases/download/v0.8.0/herdr-linux-x86_64;https://github.com/herdrdev/herdr/releases/download/v0.8.0/herdr-linux-aarch64"
  # Telegram Desktop official portable build. Only Telegram/Telegram is
  # published. The binary also has an internal updater, disabled separately by
  # install_telegram_update_policy so it cannot mutate this receipt-bound tree.
  # x86_64 only: Telegram publishes no arm64 Linux portable build, so the arm64
  # digest and URL are deliberately empty and the row is skipped there. They
  # used to hold the x86_64 values, which meant an arm64 desktop verified the
  # SHA-256 of an executable it could not run.
  "telegram;7.0.9;tarx;Telegram/Telegram;Telegram/Telegram;telegram-desktop;d3c05df0259ab116d11d8c1cdc1403019d2a3be303ad3b46d16a84e19df6615f;;https://github.com/telegramdesktop/tdesktop/releases/download/v7.0.9/tsetup.7.0.9.tar.xz;"
)

# Telegram v7.0.9 commit a1e89e1f installs these four files from
# InstallLauncher(). Our externalupdater.d policy intentionally makes that
# function return before it writes anything, so bootstrap must publish the
# exact upstream assets itself. Rows are source_url;sha256;path under
# ~/.local/share, which is the location the contract declares.
TELEGRAM_DESKTOP_ASSETS=(
  "https://raw.githubusercontent.com/telegramdesktop/tdesktop/a1e89e1f64f08cb058caf1c61ff43f319f98a6ec/Telegram/Resources/art/logo_256.png;3fb1400c7dc9bbc3b5cb3ffedcbf4a9b09c53e28b57a7ff33a8a6b9048864090;icons/hicolor/256x256/apps/org.telegram.desktop.png"
  "https://raw.githubusercontent.com/telegramdesktop/tdesktop/a1e89e1f64f08cb058caf1c61ff43f319f98a6ec/Telegram/Resources/icons/tray_monochrome.svg;a93380f2c7e6aae4d5fde8940020bd966e97ad8c4880f45c016edfef3f5193e1;icons/hicolor/symbolic/apps/org.telegram.desktop-symbolic.svg"
  "https://raw.githubusercontent.com/telegramdesktop/tdesktop/a1e89e1f64f08cb058caf1c61ff43f319f98a6ec/Telegram/Resources/icons/tray_monochrome_attention.svg;2b67ee19839dbbb9f57f2d7433fd6dc1059634d6d081c5e4c422c14f53fcfcc7;icons/hicolor/symbolic/apps/org.telegram.desktop-attention-symbolic.svg"
  "https://raw.githubusercontent.com/telegramdesktop/tdesktop/a1e89e1f64f08cb058caf1c61ff43f319f98a6ec/Telegram/Resources/icons/tray_monochrome_mute.svg;efa1439bd60b58db7b755f5d21be854ea686a0e1e2f1aa6e43bf35c083ee72fc;icons/hicolor/symbolic/apps/org.telegram.desktop-mute-symbolic.svg"
)


usage() {
  cat <<'EOF'
Usage: scripts/ubuntu/install.sh

Internal Ubuntu 24.04/26.04 installer. Use scripts/bootstrap.sh so desktop,
server, GUI, Docker, hardening, and verification settings are composed safely.
EOF
}

rldyour::ubuntu::as_root() {
  rldyour::privilege::as_root "$@"
}

apt_install() {
  rldyour::ubuntu::as_root env DEBIAN_FRONTEND=noninteractive \
    apt-get install -y --no-install-recommends --no-upgrade "$@"
}

is_supported_ubuntu() {
  [ "$(uname -s)" = "Linux" ] && [ -r /etc/os-release ] || return 1
  (
    # shellcheck disable=SC1091
    . /etc/os-release
    [ "${ID:-}" = "ubuntu" ] && { [ "${VERSION_ID:-}" = "24.04" ] || [ "${VERSION_ID:-}" = "26.04" ]; }
  )
}

validate_target() {
  case "$PROFILE:$LOCAL_EXECUTION_POLICY:$DOCKER_MODE:$GUI_ENABLED" in
    desktop:source-lsp-only:none:0|desktop:source-lsp-only:none:1) ;;
    desktop-builds:local-dev-with-builds:rootful:0|desktop-builds:local-dev-with-builds:rootful:1) ;;
    server:container-execution-only:none:0|server:container-execution-only:rootful:0|server:container-execution-only:rootless:0) ;;
    *)
      rldyour::log "error" "invalid Ubuntu composition: profile=$PROFILE policy=$LOCAL_EXECUTION_POLICY docker=$DOCKER_MODE gui=$GUI_ENABLED"
      return 2
      ;;
  esac
  if [ "$RLDYOUR_DRY_RUN" -eq 0 ] && [ "$GUI_ENABLED" -eq 1 ]; then
    case "$(uname -m)" in
      x86_64|amd64) ;;
      *)
        rldyour::log "error" "Ubuntu GUI apply requires amd64: Google Chrome and Telegram Desktop publish no supported Linux ARM64 build"
        return 2
        ;;
    esac
  fi
  if [ "$RLDYOUR_DRY_RUN" -eq 0 ] && ! is_supported_ubuntu; then
    rldyour::log "error" "apply is supported only on Ubuntu 24.04 or 26.04"
    return 2
  fi
  if [ "$RLDYOUR_DRY_RUN" -eq 0 ] && [ "$EUID" -eq 0 ]; then
    rldyour::log "error" "create/login to that account with sudo, then rerun; use scripts/ubuntu/server.sh separately for root-only baseline work"
    return 2
  fi
}

install_apt_baseline() {
  rldyour::section "Install Ubuntu package baseline"
  if [ "$PROFILE" != server ]; then
    if [ "$GUI_ENABLED" -eq 1 ]; then
      rldyour::privilege::operation ubuntu-desktop-gui-system
    else
      rldyour::privilege::operation ubuntu-desktop-system
    fi
    return
  fi
  rldyour::ubuntu::as_root apt-get update
  apt_install "${APT_SOURCE_PACKAGES[@]}"
}

ensure_node_link() {
  local name="$1" source="$2" destination current
  destination="$HOME/.local/bin/$name"
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    if [ ! -L "$destination" ]; then
      rldyour::log "error" "unmanaged Node launcher exists; preserved: $destination"
      return 1
    fi
    current="$(readlink "$destination")"
    case "$current" in
      "$HOME/.local/share/rldyour/node/"*) ;;
      *) rldyour::log "error" "unmanaged Node symlink exists; preserved: $destination"; return 1 ;;
    esac
  fi
  ln -sfn "$source" "$destination"
}

rldyour::ubuntu::preflight_managed_link() {
  local name=$1 namespace=$2 current
  local destination="$HOME/.local/bin/$name"
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    [ -L "$destination" ] || {
      rldyour::log "error" "unmanaged launcher exists; preserved: $destination"
      return 1
    }
    current=$(readlink "$destination")
    case "$current" in
      "$namespace"/*) ;;
      *)
        rldyour::log "error" "unmanaged launcher symlink exists; preserved: $destination"
        return 1
        ;;
    esac
  fi
}

ensure_managed_tool_link() {
  local name=$1 source=$2 namespace=$3 destination current
  destination="$HOME/.local/bin/$name"
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    if [ ! -L "$destination" ]; then
      rldyour::log "error" "unmanaged tool launcher exists; preserved: $destination"
      return 1
    fi
    current="$(readlink "$destination")"
    case "$current" in
      "$namespace"/*) ;;
      *) rldyour::log "error" "unmanaged tool symlink exists; preserved: $destination"; return 1 ;;
    esac
  fi
  ln -sfn "$source" "$destination"
}

# Install every row of PINNED_SOURCE_TOOLS. One generic installer rather than a
# function per tool: the contract is identical, and duplicating it eight times
# is how a receipt or a preflight check quietly goes missing from one of them.
install_pinned_source_tools() {
  local row
  for row in "${PINNED_SOURCE_TOOLS[@]}"; do
    ensure_pinned_source_tool "$row" || return 1
  done
}

# Install user-selected CLI tools (USER_TOOLS). Same row contract and installer
# as PINNED_SOURCE_TOOLS — the two arrays differ only in taxonomy: pinned source
# tools are estate CI parity (gitleaks/osv/actionlint/...), user tools are
# operator-chosen desktop conveniences (herdr). Reusing ensure_pinned_source_tool
# keeps the receipt, SHA-256 verification, and managed-symlink contract uniform.
install_user_tools() {
  local row failed=0
  for row in "${USER_TOOLS[@]}"; do
    if [ "$GUI_ENABLED" -ne 1 ] && [ "${row%%;*}" = "telegram" ]; then
      continue
    fi
    if ! ensure_pinned_source_tool "$row"; then
      failed=1
    fi
  done
  return "$failed"
}

# Telegram's official Linux binary scans <working-dir>/externalupdater.d at
# startup and disables its internal updater when a file contains the exact
# executable path. Publish both the stable launcher and its receipt-bound real
# path: Telegram may derive cExeDir/cExeName from either side of the symlink.
# This also disables Telegram's self-generated, path-hashed desktop/D-Bus files;
# the repository-owned .desktop entry below is the only launcher contract.
rldyour::ubuntu::install_telegram_update_policy() {
  [ "$GUI_ENABLED" -eq 1 ] || return 0
  local launcher="$HOME/.local/bin/telegram-desktop"
  local namespace="$HOME/.local/share/rldyour/telegram"
  local policy_dir="$HOME/.local/share/TelegramDesktop/externalupdater.d"
  local policy="$policy_dir/macos-ubuntu-bootstrap"
  local marker="# Managed by macos-ubuntu-bootstrap: telegram-external-updater-v1"
  local resolved tmp

  if [ "$RLDYOUR_DRY_RUN" -eq 1 ]; then
    rldyour::log "info" "[DRY-RUN] install Telegram external-updater policy: ${policy}"
    return 0
  fi

  if [ ! -L "$launcher" ] || [ ! -x "$launcher" ]; then
    rldyour::log "error" "managed Telegram launcher is missing or not a symlink: ${launcher}"
    return 1
  fi
  case "$(readlink "$launcher")" in
    "$namespace"/*) ;;
    *)
      rldyour::log "error" "Telegram launcher escaped its managed namespace: ${launcher}"
      return 1
      ;;
  esac
  resolved="$(readlink -f -- "$launcher")" || return 1
  [ -x "$resolved" ] || {
    rldyour::log "error" "managed Telegram binary is unavailable: ${resolved}"
    return 1
  }

  if [ -L "$policy_dir" ] || { [ -e "$policy_dir" ] && [ ! -d "$policy_dir" ]; }; then
    rldyour::log "error" "Telegram updater-policy directory is unsafe; preserved: ${policy_dir}"
    return 1
  fi
  if [ -L "$policy" ] || { [ -e "$policy" ] && [ ! -f "$policy" ]; }; then
    rldyour::log "error" "Telegram updater policy is not a regular file; preserved: ${policy}"
    return 1
  fi
  if [ -f "$policy" ] && ! grep -Fxq "$marker" "$policy"; then
    rldyour::log "error" "unmanaged Telegram updater policy differs; preserved: ${policy}"
    return 1
  fi

  mkdir -p "$policy_dir" || return 1
  tmp="$(mktemp "${policy}.tmp.XXXXXX")" || return 1
  if ! printf '%s\n%s\n%s\n' "$marker" "$launcher" "$resolved" >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  chmod 0644 "$tmp" || { rm -f "$tmp"; return 1; }
  if [ -f "$policy" ] && cmp -s "$tmp" "$policy"; then
    rm -f "$tmp"
    rldyour::log "ok" "Telegram external-updater policy already current"
    return 0
  fi
  mv -f "$tmp" "$policy" || { rm -f "$tmp"; return 1; }
  rldyour::log "ok" "installed Telegram external-updater policy: ${policy}"
}

# Install the application and symbolic tray icons that Telegram normally
# publishes from InstallLauncher(). The updater-disabled build deliberately
# skips that function, so each upstream asset is pinned to the v7.0.9 source
# commit and verified before atomic publication. Divergent local icons are
# preserved and fail closed instead of being overwritten.
rldyour::ubuntu::install_telegram_desktop_assets() {
  [ "$GUI_ENABLED" -eq 1 ] || return 0

  local data_home="$HOME/.local/share"
  local icons_root="$data_home/icons/hicolor"
  local row url expected relative target parent actual tmp

  for row in "${TELEGRAM_DESKTOP_ASSETS[@]}"; do
    IFS=';' read -r url expected relative <<<"$row"
    target="$data_home/$relative"
    parent="$(dirname "$target")"

    if [ -L "$target" ] || { [ -e "$target" ] && [ ! -f "$target" ]; }; then
      rldyour::log "error" "Telegram desktop asset is not a regular file; preserved: ${target}"
      return 1
    fi
    if [ -f "$target" ]; then
      actual="$(rldyour::sha256_file "$target")" || return 1
      if [ "$actual" != "$expected" ]; then
        rldyour::log "error" "Telegram desktop asset diverged; preserved: ${target}"
        return 1
      fi
      if [ "$RLDYOUR_DRY_RUN" -eq 0 ]; then
        chmod 0644 "$target" || return 1
      fi
      rldyour::log "ok" "$(basename "$target") already matches Telegram v7.0.9"
      continue
    fi

    if [ "$RLDYOUR_DRY_RUN" -eq 1 ]; then
      rldyour::log "info" "[DRY-RUN] install pinned Telegram desktop asset: ${target}"
      continue
    fi
    if [ -L "$parent" ] || { [ -e "$parent" ] && [ ! -d "$parent" ]; }; then
      rldyour::log "error" "Telegram desktop asset directory is unsafe; preserved: ${parent}"
      return 1
    fi
    mkdir -p "$parent" || return 1
    [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
    tmp="$(mktemp "${target}.tmp.XXXXXX")" || return 1
    if ! rldyour::download_verified_file "$url" "$expected" "$tmp"; then
      rm -f "$tmp"
      return 1
    fi
    chmod 0644 "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$target" || { rm -f "$tmp"; return 1; }
    rldyour::log "ok" "installed pinned Telegram desktop asset: ${target}"
  done

  if [ "$RLDYOUR_DRY_RUN" -eq 0 ]; then
    # Icon-theme implementations watch the top-level theme mtime. Rebuild the
    # GTK cache when available so GNOME observes the repair immediately.
    touch "$icons_root" || return 1
    if command -v gtk-update-icon-cache >/dev/null 2>&1; then
      gtk-update-icon-cache --force --ignore-theme-index "$icons_root" >/dev/null || return 1
    fi
  fi
}

# Install one marker-owned desktop entry atomically. A matching managed marker
# authorizes an update (with a recoverable backup); unmarked/user-owned files
# are preserved. This lets repairs migrate Telegram's v1/v2 launcher to the
# upstream-aligned XCB v3 contract instead of keeping a broken managed file.
rldyour::ubuntu::install_desktop_entry() {
  local src=$1 dest=$2 source_marker dest_marker source_owner dest_owner
  local backup_root backup tmp

  if [ ! -f "$src" ] || [ -L "$src" ]; then
    rldyour::log "error" "desktop entry template is missing or unsafe: ${src}"
    return 1
  fi
  source_marker="$(grep -E '^# Managed by macos-ubuntu-bootstrap: desktop-entry-[a-z0-9-]+-v[0-9]+$' "$src" || true)"
  [ "$(printf '%s\n' "$source_marker" | grep -c .)" -eq 1 ] || {
    rldyour::log "error" "desktop entry template has no unique managed marker: ${src}"
    return 1
  }

  if [ -L "$dest" ] || { [ -e "$dest" ] && [ ! -f "$dest" ]; }; then
    rldyour::log "error" "desktop entry target is not a regular file; preserved: ${dest}"
    return 1
  fi
  if [ ! -e "$dest" ]; then
    rldyour::install_config_template "$src" "$dest"
    return
  fi
  if cmp -s "$src" "$dest"; then
    rldyour::log "ok" "$(basename "$dest") already current"
    return 0
  fi

  dest_marker="$(grep -E '^# Managed by macos-ubuntu-bootstrap: desktop-entry-[a-z0-9-]+-v[0-9]+$' "$dest" || true)"
  source_owner="$(printf '%s' "$source_marker" | sed -E 's/-v[0-9]+$//')"
  dest_owner="$(printf '%s' "$dest_marker" | sed -E 's/-v[0-9]+$//')"
  if [ -z "$dest_marker" ] || [ "$dest_owner" != "$source_owner" ]; then
    rldyour::log "warn" "$(basename "$dest") is user-owned or divergent -- kept as-is; template: $src"
    return 0
  fi
  if [ "$RLDYOUR_DRY_RUN" -eq 1 ]; then
    rldyour::log "info" "[DRY-RUN] update managed desktop entry: ${dest}"
    return 0
  fi

  backup_root="$HOME/.local/share/rldyour/backups/desktop-entries"
  mkdir -p "$backup_root" || return 1
  chmod 0700 "$backup_root" || return 1
  backup="$(mktemp "$backup_root/$(basename "$dest").XXXXXX")" || return 1
  cp -p "$dest" "$backup" || { rm -f "$backup"; return 1; }
  tmp="$(mktemp "${dest}.tmp.XXXXXX")" || return 1
  cp "$src" "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 0644 "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$dest" || { rm -f "$tmp"; return 1; }
  rldyour::log "ok" "updated managed $(basename "$dest"); backup: ${backup}"
}

# Install declarative .desktop entries from templates/desktop/. Files are
# copied verbatim (no templating) through the marker-aware update contract.
install_desktop_entries() {
  [ "$GUI_ENABLED" -eq 1 ] || {
    rldyour::log "info" "desktop entries skipped: gui disabled (profile=$PROFILE)"
    return 0
  }
  local entries_dir="$REPO_ROOT/templates/desktop"
  local target_dir="$HOME/.local/share/applications"
  local entry
  for entry in "$entries_dir"/*.desktop; do
    [ -f "$entry" ] || continue
    rldyour::ubuntu::install_desktop_entry "$entry" "$target_dir/$(basename "$entry")"
  done
}

# v1/v2 used the generic telegram.desktop filename, while Telegram itself sets
# QGuiApplication::desktopFileName to org.telegram.desktop when the updater is
# disabled. Retire only our marker-owned legacy entry so the desktop file ID,
# running App ID, icon identity, MIME handlers, and GNOME favorite all agree.
rldyour::ubuntu::retire_telegram_legacy_managed_entry() {
  local data_home="$HOME/.local/share"
  local legacy="$data_home/applications/telegram.desktop"
  local marker backup_root backup_dir

  [ -e "$legacy" ] || [ -L "$legacy" ] || return 0
  if [ -L "$legacy" ] || [ ! -f "$legacy" ]; then
    rldyour::log "error" "legacy Telegram desktop entry is unsafe; preserved: ${legacy}"
    return 1
  fi
  marker="$(grep -E '^# Managed by macos-ubuntu-bootstrap: desktop-entry-telegram-v[0-9]+$' "$legacy" || true)"
  if [ "$(printf '%s\n' "$marker" | grep -c .)" -ne 1 ]; then
    rldyour::log "error" "legacy Telegram desktop entry is user-owned or divergent; preserved: ${legacy}"
    return 1
  fi
  if [ "$RLDYOUR_DRY_RUN" -eq 1 ]; then
    rldyour::log "info" "[DRY-RUN] retire managed legacy Telegram desktop entry: ${legacy}"
    return 0
  fi

  backup_root="$HOME/.local/share/rldyour/backups/desktop-entries"
  mkdir -p "$backup_root" || return 1
  chmod 0700 "$backup_root" || return 1
  backup_dir="$(mktemp -d "$backup_root/retired-telegram.XXXXXX")" || return 1
  mv "$legacy" "$backup_dir/telegram.desktop" || return 1
  rldyour::log "ok" "retired managed legacy Telegram launcher; backup: ${backup_dir}/telegram.desktop"
}

# With its updater enabled Telegram writes a path-hashed .desktop file and a
# matching D-Bus activation service. Those stale files bypass the managed XCB
# launcher even after externalupdater.d is installed. Retire only files that
# match Telegram's exact generated naming/content contract; anything divergent
# is preserved and fails closed. Every moved file remains recoverable.
rldyour::ubuntu::retire_telegram_generated_integrations() {
  local launcher="$HOME/.local/bin/telegram-desktop" resolved candidate basename
  local expected_name backup_root="" backup_dir=""
  local -a candidates=()

  for candidate in \
    "$HOME/.local/share/applications"/org.telegram.desktop._*.desktop \
    "$HOME/.local/share/dbus-1/services"/org.telegram.desktop._*.service; do
    [ -e "$candidate" ] || [ -L "$candidate" ] || continue
    candidates+=("$candidate")
  done
  [ "${#candidates[@]}" -gt 0 ] || return 0

  # A fresh plan has neither an installed launcher nor generated integrations.
  # Discover candidates first so read-only planning never requires state that
  # the corresponding apply has not created yet. If a candidate does exist,
  # its provenance remains bound to the exact managed launcher below.
  if [ ! -L "$launcher" ] || [ ! -x "$launcher" ]; then
    rldyour::log "error" "managed Telegram launcher is unavailable during integration migration"
    return 1
  fi
  resolved="$(readlink -f -- "$launcher")" || return 1

  for candidate in "${candidates[@]}"; do
    basename="$(basename "$candidate")"
    if [[ ! "$basename" =~ ^org\.telegram\.desktop\._[0-9a-f]{32}\.(desktop|service)$ ]] ||
      [ -L "$candidate" ] || [ ! -f "$candidate" ]; then
      rldyour::log "error" "Telegram integration candidate is unsafe or unrecognized; preserved: ${candidate}"
      return 1
    fi
    case "$basename" in
      *.desktop)
        if ! grep -Fxq 'DBusActivatable=true' "$candidate" ||
          { ! grep -Fxq "TryExec=${launcher}" "$candidate" &&
            ! grep -Fxq "TryExec=${resolved}" "$candidate"; } ||
          { ! grep -Fxq "Exec=${launcher} -- %U" "$candidate" &&
            ! grep -Fxq "Exec=${resolved} -- %U" "$candidate"; }; then
          rldyour::log "error" "generated Telegram desktop entry diverged; preserved: ${candidate}"
          return 1
        fi
        ;;
      *.service)
        expected_name="${basename%.service}"
        if ! grep -Fxq "Name=${expected_name}" "$candidate" ||
          { ! grep -Fxq "Exec=${launcher}" "$candidate" &&
            ! grep -Fxq "Exec=${resolved}" "$candidate"; }; then
          rldyour::log "error" "generated Telegram D-Bus service diverged; preserved: ${candidate}"
          return 1
        fi
        ;;
    esac
  done

  if [ "$RLDYOUR_DRY_RUN" -eq 1 ]; then
    rldyour::log "info" "[DRY-RUN] retire ${#candidates[@]} generated Telegram desktop/D-Bus integration file(s)"
    return 0
  fi
  backup_root="$HOME/.local/share/rldyour/backups/telegram-integrations"
  mkdir -p "$backup_root" || return 1
  chmod 0700 "$backup_root" || return 1
  backup_dir="$(mktemp -d "$backup_root/generated.XXXXXX")" || return 1
  for candidate in "${candidates[@]}"; do
    mv "$candidate" "$backup_dir/$(basename "$candidate")" || return 1
  done
  rldyour::log "ok" "retired generated Telegram integrations; backup: ${backup_dir}"
}

# Rewrite mimeapps.list, dropping only [Added Associations] lines whose
# every handler was just retired. Kept as a named program so the shell
# function below stays readable.
RLDYOUR_PRUNE_ADDED_ASSOCIATIONS='import pathlib
import sys

source = pathlib.Path(sys.argv[1])
# Only the retired launchers, never the mimeapps.list backup that sits
# beside them in the same directory.
retired = {
    path.name
    for path in pathlib.Path(sys.argv[2]).iterdir()
    if path.name.endswith('\''.desktop'\'')
}
section = ""
for line in source.read_text(encoding='\''utf-8'\'').splitlines(keepends=True):
    stripped = line.strip()
    if stripped.startswith('\''['\'') and stripped.endswith('\'']'\''):
        section = stripped
    elif section == '\''[Added Associations]'\'' and '\''='\'' in stripped:
        key, _, value = stripped.partition('\''='\'')
        handlers = [h for h in value.split('\'';'\'') if h]
        survivors = [h for h in handlers if h not in retired]
        if handlers and not survivors:
            continue  # every handler on this line was retired
        if survivors != handlers:
            # Keep the association, drop only the dead references. Removing
            # the whole line would unregister a handler we never touched.
            line = key + '\''='\'' + '\'';'\''.join(survivors) + '\'';\n'\''
    sys.stdout.write(line)'

# GIO writes userapp-<Name>-<6 chars>.desktop whenever something picks a custom
# application for a scheme, and registers it under [Added Associations] in
# mimeapps.list. Those entries invoke the launcher directly -- `telegram-desktop
# -- %u` -- WITHOUT the `env QT_QPA_PLATFORM=xcb` wrapper the managed v3 entry
# exists for. They do not shadow the default handler, so the common path stays
# correct, but an application chooser, an enumerating caller, or a later default
# reset can still start Telegram in the Wayland mode that fails with
# EGL_BAD_MATCH on the estate's NVIDIA workstation. Retire only entries whose
# Exec is bound to the managed launcher; anything else is preserved.
rldyour::ubuntu::retire_telegram_userapp_entries() {
  local launcher="$HOME/.local/bin/telegram-desktop" resolved candidate name
  local applications="$HOME/.local/share/applications"
  local mimeapps="${XDG_CONFIG_HOME:-$HOME/.config}/mimeapps.list"
  local backup_root backup_dir tmp
  local -a candidates=() retired=()

  for candidate in "$applications"/userapp-*.desktop; do
    [ -e "$candidate" ] || [ -L "$candidate" ] || continue
    candidates+=("$candidate")
  done
  [ "${#candidates[@]}" -gt 0 ] || return 0

  if [ ! -L "$launcher" ] || [ ! -x "$launcher" ]; then
    rldyour::log "error" "managed Telegram launcher is unavailable during userapp migration"
    return 1
  fi
  resolved="$(readlink -f -- "$launcher")" || return 1

  for candidate in "${candidates[@]}"; do
    name="$(basename "$candidate")"
    # Not ours: a userapp entry for another application must survive intact.
    if ! grep -Eq "^Exec=(${launcher}|${resolved}|telegram-desktop)( |$)" "$candidate" 2>/dev/null; then
      continue
    fi
    if [ -L "$candidate" ] || [ ! -f "$candidate" ]; then
      rldyour::log "error" "Telegram userapp entry is unsafe; preserved: ${candidate}"
      return 1
    fi
    # Exact GIO shape. A hand-written file that merely looks similar is
    # preserved rather than retired.
    if [[ ! "$name" =~ ^userapp-.+-[A-Za-z0-9]{6}\.desktop$ ]] ||
      ! grep -Fxq 'NoDisplay=true' "$candidate" ||
      ! grep -Fxq 'Comment=Custom definition for Telegram Desktop' "$candidate"; then
      rldyour::log "error" "Telegram userapp entry diverged from the generated shape; preserved: ${candidate}"
      return 1
    fi
    retired+=("$candidate")
  done
  [ "${#retired[@]}" -gt 0 ] || return 0

  if [ "$RLDYOUR_DRY_RUN" -eq 1 ]; then
    rldyour::log "info" "[DRY-RUN] retire ${#retired[@]} generated Telegram userapp launcher(s) and their added associations"
    return 0
  fi

  backup_root="$HOME/.local/share/rldyour/backups/telegram-integrations"
  mkdir -p "$backup_root" || return 1
  chmod 0700 "$backup_root" || return 1
  backup_dir="$(mktemp -d "$backup_root/userapp.XXXXXX")" || return 1
  for candidate in "${retired[@]}"; do
    mv "$candidate" "$backup_dir/$(basename "$candidate")" || return 1
  done

  # Drop the now-dangling [Added Associations] lines that name exactly the
  # files just retired. Every other line, section and ordering is preserved
  # byte for byte: this file is owner-owned and only its dead references are
  # ours to remove.
  if [ -f "$mimeapps" ] && [ ! -L "$mimeapps" ]; then
    cp -p "$mimeapps" "$backup_dir/mimeapps.list" || return 1
    tmp="$(mktemp "${mimeapps}.tmp.XXXXXX")" || return 1
    if ! python3 -c "$RLDYOUR_PRUNE_ADDED_ASSOCIATIONS" "$mimeapps" "$backup_dir" >"$tmp"; then
      rm -f "$tmp"
      rldyour::log "error" "could not rewrite ${mimeapps}; retired files are in ${backup_dir}"
      return 1
    fi
    chmod --reference="$mimeapps" "$tmp" 2>/dev/null || chmod 0644 "$tmp"
    mv -f "$tmp" "$mimeapps" || { rm -f "$tmp"; return 1; }
  fi

  rldyour::log "ok" "retired ${#retired[@]} generated Telegram userapp launcher(s); backup: ${backup_dir}"
}

# Make every normal desktop launch resolve to the managed Telegram entry. Only
# an existing Telegram favorite is migrated; the bootstrap never adds a new
# favorite or rewrites unrelated GNOME ordering.
rldyour::ubuntu::configure_telegram_desktop_integration() {
  [ "$GUI_ENABLED" -eq 1 ] || return 0
  local desktop_id="org.telegram.desktop.desktop"
  if [ "$RLDYOUR_DRY_RUN" -eq 1 ]; then
    rldyour::log "info" "[DRY-RUN] refresh Telegram MIME handlers and migrate its GNOME favorite to ${desktop_id}"
    return 0
  fi

  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$HOME/.local/share/applications" || return 1
  fi
  if command -v gdbus >/dev/null 2>&1; then
    gdbus call --session --dest org.freedesktop.DBus \
      --object-path /org/freedesktop/DBus \
      --method org.freedesktop.DBus.ReloadConfig >/dev/null 2>&1 ||
      rldyour::log "warn" "session D-Bus config could not be reloaded; it will refresh at next login"
  fi
  if command -v xdg-mime >/dev/null 2>&1; then
    xdg-mime default "$desktop_id" x-scheme-handler/tg || return 1
    xdg-mime default "$desktop_id" x-scheme-handler/tonsite || return 1
  fi

  local favorites migrated
  if ! command -v gsettings >/dev/null 2>&1 ||
    ! favorites="$(gsettings get org.gnome.shell favorite-apps 2>/dev/null)"; then
    rldyour::log "warn" "GNOME favorites unavailable; Telegram launcher was installed without changing favorites"
    return 0
  fi
  migrated="$(python3 - "$favorites" <<'PY'
import ast
import re
import sys

raw = sys.argv[1]
if raw.startswith("@as "):
    raw = raw[4:]
values = ast.literal_eval(raw)
if not isinstance(values, list) or not all(isinstance(value, str) for value in values):
    raise SystemExit("favorite-apps is not a string array")
result = []
for value in values:
    if value == "telegram.desktop" or re.fullmatch(
        r"org\.telegram\.desktop\._[0-9a-f]+\.desktop", value
    ):
        value = "org.telegram.desktop.desktop"
    if value not in result:
        result.append(value)
print(repr(result))
PY
)" || return 1
  if [ "$migrated" != "$favorites" ]; then
    gsettings set org.gnome.shell favorite-apps "$migrated" || return 1
    rldyour::log "ok" "migrated Telegram favorite to ${desktop_id}"
  fi
}


ensure_pinned_source_tool() {
  local row=$1
  local name version kind members_x64 members_arm64 links sha_x64 sha_arm64 url_x64 url_arm64
  IFS=';' read -r name version kind members_x64 members_arm64 links \
    sha_x64 sha_arm64 url_x64 url_arm64 <<<"$row"

  local sha url members
  case "$(uname -m)" in
    x86_64|amd64) sha="$sha_x64"; url="$url_x64"; members="$members_x64" ;;
    aarch64|arm64) sha="$sha_arm64"; url="$url_arm64"; members="$members_arm64" ;;
    *) rldyour::log "error" "$name $version has no tracked artifact for $(uname -m)"; return 1 ;;
  esac
  # An empty pair is a deliberate declaration that upstream publishes nothing
  # for this architecture. Telegram is the only such row: it ships an x86_64
  # portable build only, and the fields used to be filled with the x86_64 URL
  # and digest -- so an arm64 desktop verified its SHA-256 happily and then
  # installed a binary it cannot execute.
  if [ -z "$url" ] || [ -z "$sha" ]; then
    rldyour::log "info" "$name $version: upstream publishes no $(uname -m) build; skipped"
    return 0
  fi

  local destination parent
  destination="$HOME/.local/share/rldyour/$name/$version"
  parent="$(dirname "$destination")"

  if [ "$RLDYOUR_DRY_RUN" -eq 1 ]; then
    rldyour::log "info" "[DRY-RUN] verify or install managed $name $version from the tracked SHA-256 artifact; external PATH binaries are preserved but never trusted"
    return 0
  fi

  local -a member_list link_list
  IFS=',' read -r -a member_list <<<"$members"
  IFS=',' read -r -a link_list <<<"$links"
  if [ "${#member_list[@]}" -ne "${#link_list[@]}" ]; then
    rldyour::log "error" "$name: members and links must be parallel lists"
    return 1
  fi

  mkdir -p "$HOME/.local/bin" "$parent"
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    if ! rldyour::ubuntu::validate_runtime_receipt \
      "$destination" "$name" "$version" "$sha" "${member_list[@]}"; then
      rldyour::log "error" "unmanaged or tampered $name destination exists; preserved: $destination"
      return 1
    fi
  else
    local archive stage
    archive="$(mktemp)"; stage="$(mktemp -d "$parent/.$name-$version.tmp.XXXXXX")"
    trap 'rm -rf "$archive"; [ -z "${stage:-}" ] || rm -rf "$stage"' RETURN
    rldyour::download_verified_file "$url" "$sha" "$archive" || return 1
    case "$kind" in
      tar0) tar -xzf "$archive" -C "$stage" ;;
      tar1) tar -xzf "$archive" --strip-components=1 -C "$stage" ;;
      tarx) tar -xJf "$archive" -C "$stage" ;;
      zip) unzip -q -o "$archive" -d "$stage" ;;
      raw) cp "$archive" "$stage/${member_list[0]}" ;;
      *) rldyour::log "error" "$name: unknown archive kind '$kind'"; return 1 ;;
    esac

    local member
    for member in "${member_list[@]}"; do
      if [ ! -f "$stage/$member" ]; then
        rldyour::log "error" "$name $version artifact does not contain $member"
        return 1
      fi
      chmod 0755 "$stage/$member"
    done
    rldyour::ubuntu::write_runtime_receipt \
      "$stage" "$name" "$version" "$sha" "${member_list[@]}" || return 1
    mv "$stage" "$destination"
    stage=""
    rm -f "$archive"
    trap - RETURN
  fi

  local i
  for i in "${!link_list[@]}"; do
    rldyour::ubuntu::preflight_managed_link "${link_list[$i]}" "$HOME/.local/share/rldyour/$name" || return 1
    ensure_managed_tool_link "${link_list[$i]}" "$destination/${member_list[$i]}" \
      "$HOME/.local/share/rldyour/$name" || return 1
  done
  rldyour::ensure_path
}

# `dart --version` prints one line — `Dart SDK version: X.Y.Z (channel) ...` —
# and older SDKs emitted it on stderr, so both streams are read. Kept as one
# helper because the version gate runs at three points in ensure_dart.
rldyour::ubuntu::dart_reported_version() {
  local binary=$1
  [ -x "$binary" ] || return 0
  "$binary" --version 2>&1 | awk 'NR == 1 { print $4 }'
}

rldyour::ubuntu::write_runtime_receipt() {
  local root=$1 runtime=$2 version=$3 archive_sha256=$4
  local relative key
  shift 4
  {
    printf '%s\n' '# Managed by macos-ubuntu-bootstrap: ubuntu-runtime-v1'
    printf 'runtime=%s\nversion=%s\narchive_sha256=%s\n' "$runtime" "$version" "$archive_sha256"
    for relative in "$@"; do
      [ -x "$root/$relative" ] || return 1
      key=${relative//\//_}
      printf 'sha256_%s=%s\n' "$key" "$(rldyour::sha256_file "$root/$relative")"
    done
  } >"$root/.rldyour-runtime-receipt"
  chmod 0600 "$root/.rldyour-runtime-receipt"
}

rldyour::ubuntu::validate_runtime_receipt() {
  local root=$1 runtime=$2 version=$3 archive_sha256=$4
  local receipt="$root/.rldyour-runtime-receipt" relative key expected
  shift 4

  [ ! -L "$root" ] && [ -d "$root" ] && [ -f "$receipt" ] && [ ! -L "$receipt" ] || return 1
  [ "$(grep -Fxc '# Managed by macos-ubuntu-bootstrap: ubuntu-runtime-v1' "$receipt")" -eq 1 ] || return 1
  [ "$(grep -Fxc "runtime=${runtime}" "$receipt")" -eq 1 ] || return 1
  [ "$(grep -Fxc "version=${version}" "$receipt")" -eq 1 ] || return 1
  [ "$(grep -Fxc "archive_sha256=${archive_sha256}" "$receipt")" -eq 1 ] || return 1
  for relative in "$@"; do
    [ -x "$root/$relative" ] || return 1
    key=${relative//\//_}
    [ "$(grep -c "^sha256_${key}=" "$receipt")" -eq 1 ] || return 1
    expected=$(sed -n "s/^sha256_${key}=//p" "$receipt")
    printf '%s' "$expected" | grep -Eq '^[0-9a-f]{64}$' || return 1
    [ "$(rldyour::sha256_file "$root/$relative")" = "$expected" ] || return 1
  done
}

ensure_node() {
  rldyour::section "Ensure Node.js LTS ${NODE_VERSION}"
  local arch sha filename url archive stage destination parent
  case "$(uname -m)" in
    x86_64|amd64) arch="x64"; sha="$NODE_SHA256_X64" ;;
    aarch64|arm64) arch="arm64"; sha="$NODE_SHA256_ARM64" ;;
    *) rldyour::log "error" "Node.js ${NODE_VERSION} has no tracked artifact for $(uname -m)"; return 1 ;;
  esac
  filename="node-v${NODE_VERSION}-linux-${arch}.tar.xz"
  url="https://nodejs.org/dist/v${NODE_VERSION}/${filename}"
  destination="$HOME/.local/share/rldyour/node/v${NODE_VERSION}"
  parent="$(dirname "$destination")"
  if [ "$RLDYOUR_DRY_RUN" -eq 1 ]; then
    rldyour::log "info" "[DRY-RUN] verify or install managed Node.js ${NODE_VERSION} from the tracked SHA-256 artifact; external PATH binaries are preserved but never trusted"
    return 0
  fi
  mkdir -p "$HOME/.local/bin" "$parent"
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    if ! rldyour::ubuntu::validate_runtime_receipt \
      "$destination" node "$NODE_VERSION" "$sha" \
      bin/node bin/npm bin/npx bin/corepack ||
      [ "$("$destination/bin/node" --version 2>/dev/null)" != "v${NODE_VERSION}" ]; then
      rldyour::log "error" "unmanaged or tampered Node destination exists; preserved: $destination"
      return 1
    fi
  else
    archive="$(mktemp)"; stage="$(mktemp -d "$parent/.node-${NODE_VERSION}.tmp.XXXXXX")"
    trap 'rm -rf "$archive"; [ -z "${stage:-}" ] || rm -rf "$stage"' RETURN
    rldyour::download_verified_file "$url" "$sha" "$archive" || return 1
    tar -xJf "$archive" --strip-components=1 -C "$stage"
    [ "$("$stage/bin/node" --version 2>/dev/null)" = "v${NODE_VERSION}" ] || {
      rldyour::log "error" "staged Node.js artifact did not report v${NODE_VERSION}"
      return 1
    }
    rldyour::ubuntu::write_runtime_receipt \
      "$stage" node "$NODE_VERSION" "$sha" \
      bin/node bin/npm bin/npx bin/corepack || return 1
    mv "$stage" "$destination"
    stage=""
    rm -f "$archive"
    trap - RETURN
  fi
  # Node is a pinned runtime only. npm/npx/corepack ship inside the verified
  # tarball (their integrity is recorded in the receipt) but are deliberately
  # NOT published to the managed PATH: uv and bun are the only package managers.
  rldyour::ubuntu::preflight_managed_link node "$HOME/.local/share/rldyour/node"
  ensure_node_link node "$destination/bin/node"
  rldyour::ensure_path
  [ "$("$HOME/.local/bin/node" --version)" = "v${NODE_VERSION}" ] || {
    rldyour::log "error" "managed Node.js launcher did not resolve to ${NODE_VERSION}"
    return 1
  }
}

ensure_uv() {
  local arch sha triple archive stage destination url parent
  case "$(uname -m)" in
    x86_64|amd64) arch="x86_64"; sha="$UV_SHA256_X64" ;;
    aarch64|arm64) arch="aarch64"; sha="$UV_SHA256_ARM64" ;;
    *) rldyour::log "error" "uv ${UV_VERSION} has no tracked artifact for $(uname -m)"; return 1 ;;
  esac
  triple="${arch}-unknown-linux-gnu"
  destination="$HOME/.local/share/rldyour/uv/${UV_VERSION}"
  parent="$(dirname "$destination")"
  if [ "$RLDYOUR_DRY_RUN" -eq 1 ]; then
    rldyour::log "info" "[DRY-RUN] verify or install managed uv ${UV_VERSION} from the tracked SHA-256 artifact; external PATH binaries are not trusted"
    return 0
  fi
  mkdir -p "$HOME/.local/bin" "$parent"
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    if ! rldyour::ubuntu::validate_runtime_receipt \
      "$destination" uv "$UV_VERSION" "$sha" uv uvx ||
      [ "$("$destination/uv" --version 2>/dev/null | awk '{ print $2 }')" != "$UV_VERSION" ]; then
      rldyour::log "error" "unmanaged or tampered uv destination exists; preserved: $destination"
      return 1
    fi
  else
    archive="$(mktemp)"; stage="$(mktemp -d "$parent/.uv-${UV_VERSION}.tmp.XXXXXX")"
    trap 'rm -rf "$archive"; [ -z "${stage:-}" ] || rm -rf "$stage"' RETURN
    url="https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-${triple}.tar.gz"
    rldyour::download_verified_file "$url" "$sha" "$archive"
    tar -xzf "$archive" --strip-components=1 -C "$stage"
    [ "$("$stage/uv" --version 2>/dev/null | awk '{ print $2 }')" = "$UV_VERSION" ] || {
      rldyour::log "error" "staged uv artifact did not report ${UV_VERSION}"
      return 1
    }
    rldyour::ubuntu::write_runtime_receipt "$stage" uv "$UV_VERSION" "$sha" uv uvx || return 1
    mv "$stage" "$destination"
    stage=""
    rm -f "$archive"
    trap - RETURN
  fi
  rldyour::ubuntu::preflight_managed_link uv "$HOME/.local/share/rldyour/uv"
  rldyour::ubuntu::preflight_managed_link uvx "$HOME/.local/share/rldyour/uv"
  ensure_managed_tool_link uv "$destination/uv" "$HOME/.local/share/rldyour/uv"
  ensure_managed_tool_link uvx "$destination/uvx" "$HOME/.local/share/rldyour/uv"
  "$HOME/.local/bin/uv" --version | grep -Fq "uv ${UV_VERSION}"
}

# Go, Rust, and Dart are source-analysis hosts on every profile.
install_compiled_language_hosts() {
  ensure_go
  ensure_rust
  ensure_dart
  install_pinned_source_tools
}

ensure_go() {
  rldyour::section "Ensure Go ${GO_VERSION} (gopls host)"
  local arch sha filename url archive stage destination parent
  case "$(uname -m)" in
    x86_64|amd64) arch="amd64"; sha="$GO_SHA256_AMD64" ;;
    aarch64|arm64) arch="arm64"; sha="$GO_SHA256_ARM64" ;;
    *) rldyour::log "error" "Go ${GO_VERSION} has no tracked artifact for $(uname -m)"; return 1 ;;
  esac
  filename="go${GO_VERSION}.linux-${arch}.tar.gz"
  url="https://go.dev/dl/${filename}"
  destination="$HOME/.local/share/rldyour/go/${GO_VERSION}"
  parent="$(dirname "$destination")"
  if [ "$RLDYOUR_DRY_RUN" -eq 1 ]; then
    rldyour::log "info" "[DRY-RUN] verify or install managed Go ${GO_VERSION} from the tracked SHA-256 artifact, then install gopls ${GOPLS_VERSION} through the module checksum database; external PATH binaries are preserved but never trusted"
    return 0
  fi
  mkdir -p "$HOME/.local/bin" "$parent"
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    if ! rldyour::ubuntu::validate_runtime_receipt \
      "$destination" go "$GO_VERSION" "$sha" bin/go bin/gofmt ||
      [ "$("$destination/bin/go" version 2>/dev/null | awk '{ print $3 }')" != "go${GO_VERSION}" ]; then
      rldyour::log "error" "unmanaged or tampered Go destination exists; preserved: $destination"
      return 1
    fi
  else
    archive="$(mktemp)"; stage="$(mktemp -d "$parent/.go-${GO_VERSION}.tmp.XXXXXX")"
    trap 'rm -rf "$archive"; [ -z "${stage:-}" ] || rm -rf "$stage"' RETURN
    rldyour::download_verified_file "$url" "$sha" "$archive" || return 1
    tar -xzf "$archive" --strip-components=1 -C "$stage"
    [ "$("$stage/bin/go" version 2>/dev/null | awk '{ print $3 }')" = "go${GO_VERSION}" ] || {
      rldyour::log "error" "staged Go artifact did not report go${GO_VERSION}"
      return 1
    }
    rldyour::ubuntu::write_runtime_receipt \
      "$stage" go "$GO_VERSION" "$sha" bin/go bin/gofmt || return 1
    mv "$stage" "$destination"
    stage=""
    rm -f "$archive"
    trap - RETURN
  fi
  rldyour::ubuntu::preflight_managed_link go "$HOME/.local/share/rldyour/go"
  rldyour::ubuntu::preflight_managed_link gofmt "$HOME/.local/share/rldyour/go"
  ensure_managed_tool_link go "$destination/bin/go" "$HOME/.local/share/rldyour/go"
  ensure_managed_tool_link gofmt "$destination/bin/gofmt" "$HOME/.local/share/rldyour/go"
  rldyour::ensure_path
  [ "$("$HOME/.local/bin/go" version | awk '{ print $3 }')" = "go${GO_VERSION}" ] || {
    rldyour::log "error" "managed Go launcher did not resolve to ${GO_VERSION}"
    return 1
  }
  ensure_gopls "$destination"
}

# gopls is built from an exact module version. The checksum database verifies
# every module in the build, so provenance is enforced without a tracked archive
# hash. GOBIN keeps the binary inside the managed Go tree.
ensure_gopls() {
  local goroot="$1" gobin
  gobin="$HOME/.local/share/rldyour/go/gopls/${GOPLS_VERSION}"
  if [ ! -x "$gobin/gopls" ]; then
    mkdir -p "$gobin"
    rldyour::log "info" "building gopls ${GOPLS_VERSION} through the module checksum database"
    env GOROOT="$goroot" GOBIN="$gobin" GOFLAGS=-mod=readonly \
      GOPROXY=https://proxy.golang.org,direct GOSUMDB=sum.golang.org \
      "$goroot/bin/go" install "golang.org/x/tools/gopls@${GOPLS_VERSION}" || {
      rldyour::log "error" "gopls ${GOPLS_VERSION} install failed"
      return 1
    }
  fi
  rldyour::ubuntu::preflight_managed_link gopls "$HOME/.local/share/rldyour/go"
  ensure_managed_tool_link gopls "$gobin/gopls" "$HOME/.local/share/rldyour/go"
  "$HOME/.local/bin/gopls" version >/dev/null 2>&1 || {
    rldyour::log "error" "managed gopls launcher is not executable"
    return 1
  }
}

ensure_rust() {
  rldyour::section "Ensure Rust ${RUST_VERSION} (rust-analyzer host)"
  local arch sha triple filename url archive stage destination parent components
  case "$(uname -m)" in
    x86_64|amd64) arch="x86_64"; sha="$RUST_SHA256_X86_64" ;;
    aarch64|arm64) arch="aarch64"; sha="$RUST_SHA256_AARCH64" ;;
    *) rldyour::log "error" "Rust ${RUST_VERSION} has no tracked artifact for $(uname -m)"; return 1 ;;
  esac
  triple="${arch}-unknown-linux-gnu"
  filename="rust-${RUST_VERSION}-${triple}.tar.xz"
  url="https://static.rust-lang.org/dist/${RUST_CHANNEL_DATE}/${filename}"
  destination="$HOME/.local/share/rldyour/rust/${RUST_VERSION}"
  parent="$(dirname "$destination")"
  components="rustc,cargo,rust-std-${triple},clippy-preview,rustfmt-preview,rust-analyzer-preview"
  if [ "$RLDYOUR_DRY_RUN" -eq 1 ]; then
    rldyour::log "info" "[DRY-RUN] verify or install managed Rust ${RUST_VERSION} (rustc, cargo, clippy, rustfmt, rust-analyzer) from the tracked SHA-256 artifact; external PATH binaries are preserved but never trusted"
    return 0
  fi
  mkdir -p "$HOME/.local/bin" "$parent"
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    if ! rldyour::ubuntu::validate_runtime_receipt \
      "$destination" rust "$RUST_VERSION" "$sha" \
      bin/rustc bin/cargo bin/rust-analyzer bin/rustfmt bin/clippy-driver ||
      [ "$("$destination/bin/rustc" --version 2>/dev/null | awk '{ print $2 }')" != "$RUST_VERSION" ]; then
      rldyour::log "error" "unmanaged or tampered Rust destination exists; preserved: $destination"
      return 1
    fi
  else
    archive="$(mktemp)"; stage="$(mktemp -d "$parent/.rust-${RUST_VERSION}.tmp.XXXXXX")"
    trap 'rm -rf "$archive"; [ -z "${stage:-}" ] || rm -rf "$stage"' RETURN
    rldyour::download_verified_file "$url" "$sha" "$archive" || return 1
    # The installer ships inside the SHA-256-verified archive; it is a verified
    # artifact, never remote code piped to a shell.
    mkdir -p "$stage/src" "$stage/prefix"
    tar -xJf "$archive" --strip-components=1 -C "$stage/src"
    "$stage/src/install.sh" --prefix="$stage/prefix" --disable-ldconfig \
      --components="$components" >/dev/null || {
      rldyour::log "error" "Rust ${RUST_VERSION} offline install failed"
      return 1
    }
    rm -rf "$stage/src"
    [ "$("$stage/prefix/bin/rustc" --version 2>/dev/null | awk '{ print $2 }')" = "$RUST_VERSION" ] || {
      rldyour::log "error" "staged Rust artifact did not report ${RUST_VERSION}"
      return 1
    }
    # Rust's bundled install.sh creates its prefix under the caller's umask, so
    # `umask 002` published a group-writable tree root. Go and Node avoid this only
    # because their trees come from `mktemp -d` at 0700. The receipt covers five
    # executables, so a writable directory beside them is enough to add a library
    # without invalidating it.
    if ! rldyour::_managed_tree_permissions normalize "$stage/prefix"; then
      rldyour::log "error" "could not normalize permissions on the staged Rust tree"
      return 1
    fi
    rldyour::ubuntu::write_runtime_receipt \
      "$stage/prefix" rust "$RUST_VERSION" "$sha" \
      bin/rustc bin/cargo bin/rust-analyzer bin/rustfmt bin/clippy-driver || return 1
    mv "$stage/prefix" "$destination"
    rm -rf "$stage"
    stage=""
    rm -f "$archive"
    trap - RETURN
  fi
  local tool
  for tool in rustc cargo rust-analyzer rustfmt clippy-driver cargo-clippy cargo-fmt; do
    [ -x "$destination/bin/$tool" ] || continue
    rldyour::ubuntu::preflight_managed_link "$tool" "$HOME/.local/share/rldyour/rust"
    ensure_managed_tool_link "$tool" "$destination/bin/$tool" "$HOME/.local/share/rldyour/rust"
  done
  rldyour::ensure_path
  [ "$("$HOME/.local/bin/rustc" --version | awk '{ print $2 }')" = "$RUST_VERSION" ] || {
    rldyour::log "error" "managed Rust launcher did not resolve to ${RUST_VERSION}"
    return 1
  }
}

# Dart SDK host (ADR 0005). The stable channel publishes one self-contained zip
# per architecture whose only top-level entry is `dart-sdk/`, so the wrapper is
# stripped exactly the way ensure_rust strips its own. `dart` is the single
# published link: `dart language-server` backs Dart/Flutter source analysis and
# `dart mcp-server` is the transport the rldyour-mcps `dart-flutter` server
# executes. Both ship inside this archive — there is no second install path.
ensure_dart() {
  rldyour::section "Ensure Dart ${DART_VERSION} (analysis-server and MCP host)"
  local arch sha filename url archive stage destination parent reported
  case "$(uname -m)" in
    x86_64|amd64) arch="x64"; sha="$DART_SHA256_X64" ;;
    aarch64|arm64) arch="arm64"; sha="$DART_SHA256_ARM64" ;;
    *) rldyour::log "error" "Dart ${DART_VERSION} has no tracked artifact for $(uname -m)"; return 1 ;;
  esac
  filename="dartsdk-linux-${arch}-release.zip"
  url="https://storage.googleapis.com/dart-archive/channels/stable/release/${DART_VERSION}/sdk/${filename}"
  destination="$HOME/.local/share/rldyour/dart/${DART_VERSION}"
  parent="$(dirname "$destination")"
  if [ "$RLDYOUR_DRY_RUN" -eq 1 ]; then
    rldyour::log "info" "[DRY-RUN] verify or install managed Dart ${DART_VERSION} from the tracked SHA-256 artifact, publishing dart for the analysis server and the dart-flutter MCP transport; external PATH binaries are preserved but never trusted"
    return 0
  fi
  mkdir -p "$HOME/.local/bin" "$parent"
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    if ! rldyour::ubuntu::validate_runtime_receipt \
      "$destination" dart "$DART_VERSION" "$sha" bin/dart bin/dartaotruntime ||
      [ "$(rldyour::ubuntu::dart_reported_version "$destination/bin/dart")" != "$DART_VERSION" ]; then
      rldyour::log "error" "unmanaged or tampered Dart destination exists; preserved: $destination"
      return 1
    fi
    # The receipt covers only the declared executables. A writable directory
    # beside them is enough to add or swap a snapshot without invalidating it.
    if ! rldyour::_managed_tree_permissions validate "$destination"; then
      rldyour::log "error" "managed Dart tree has unsafe ownership or permissions; preserved: $destination"
      return 1
    fi
  else
    archive="$(mktemp)"; stage="$(mktemp -d "$parent/.dart-${DART_VERSION}.tmp.XXXXXX")"
    trap 'rm -rf "$archive"; [ -z "${stage:-}" ] || rm -rf "$stage"' RETURN
    rldyour::download_verified_file "$url" "$sha" "$archive" || return 1
    # unzip has no --strip-components; the archive's single top-level `dart-sdk`
    # directory is promoted explicitly instead.
    mkdir -p "$stage/src"
    unzip -q "$archive" -d "$stage/src" || {
      rldyour::log "error" "Dart ${DART_VERSION} archive did not unpack"
      return 1
    }
    if [ ! -d "$stage/src/dart-sdk" ] || [ -L "$stage/src/dart-sdk" ]; then
      rldyour::log "error" "Dart ${DART_VERSION} archive layout changed; expected a single dart-sdk directory"
      return 1
    fi
    mv "$stage/src/dart-sdk" "$stage/prefix"
    rm -rf "$stage/src"
    reported="$(rldyour::ubuntu::dart_reported_version "$stage/prefix/bin/dart")"
    [ "$reported" = "$DART_VERSION" ] || {
      rldyour::log "error" "staged Dart artifact reported '${reported:-unknown}', expected ${DART_VERSION}"
      return 1
    }
    # The SDK zip records its directories as 0775, so a permissive umask cannot
    # save the tree: umask only clears bits it never adds. Normalize before the
    # receipt is written so the published tree is not group-writable.
    if ! rldyour::_managed_tree_permissions normalize "$stage/prefix"; then
      rldyour::log "error" "could not normalize permissions on the staged Dart tree"
      return 1
    fi
    rldyour::ubuntu::write_runtime_receipt \
      "$stage/prefix" dart "$DART_VERSION" "$sha" bin/dart bin/dartaotruntime || return 1
    mv "$stage/prefix" "$destination"
    rm -rf "$stage"
    stage=""
    rm -f "$archive"
    trap - RETURN
  fi
  rldyour::ubuntu::preflight_managed_link dart "$HOME/.local/share/rldyour/dart"
  ensure_managed_tool_link dart "$destination/bin/dart" "$HOME/.local/share/rldyour/dart"
  rldyour::ensure_path
  [ "$(rldyour::ubuntu::dart_reported_version "$HOME/.local/bin/dart")" = "$DART_VERSION" ] || {
    rldyour::log "error" "managed Dart launcher did not resolve to ${DART_VERSION}"
    return 1
  }
  # The MCP transport is the reason this host exists; prove the subcommand is
  # present rather than assuming the SDK shipped it.
  "$HOME/.local/bin/dart" mcp-server --version >/dev/null 2>&1 || {
    rldyour::log "error" "managed Dart ${DART_VERSION} does not expose 'dart mcp-server'"
    return 1
  }
  rldyour::ensure_dart_telemetry_disabled "$HOME/.local/bin/dart" || return 1
  rldyour::log "ok" "Dart ${DART_VERSION} published with language-server and mcp-server support"
}

ensure_bun() {
  local arch sha archive stage destination url parent extract_dir
  case "$(uname -m)" in
    x86_64|amd64)
      # Standard Bun x64 requires AVX2; older CPUs need the baseline build.
      if rldyour::cpu_has_avx2; then
        arch="x64"; sha="$BUN_SHA256_X64"
      else
        arch="x64-baseline"; sha="$BUN_SHA256_X64_BASELINE"
        rldyour::log "info" "AVX2 absent; selecting Bun ${BUN_VERSION} x64-baseline artifact"
      fi
      ;;
    aarch64|arm64) arch="aarch64"; sha="$BUN_SHA256_ARM64" ;;
    *) rldyour::log "error" "Bun ${BUN_VERSION} has no tracked artifact for $(uname -m)"; return 1 ;;
  esac
  destination="$HOME/.local/share/rldyour/bun/${BUN_VERSION}"
  parent="$(dirname "$destination")"
  if [ "$RLDYOUR_DRY_RUN" -eq 1 ]; then
    rldyour::log "info" "[DRY-RUN] verify or install managed Bun ${BUN_VERSION} from the tracked SHA-256 artifact; external PATH binaries are not trusted"
    return 0
  fi
  mkdir -p "$HOME/.local/bin" "$parent"
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    if ! rldyour::ubuntu::validate_runtime_receipt \
      "$destination" bun "$BUN_VERSION" "$sha" bun ||
      [ "$("$destination/bun" --version 2>/dev/null)" != "$BUN_VERSION" ]; then
      rldyour::log "error" "unmanaged or tampered Bun destination exists; preserved: $destination"
      return 1
    fi
  else
    archive="$(mktemp)"; stage="$(mktemp -d "$parent/.bun-${BUN_VERSION}.tmp.XXXXXX")"
    trap 'rm -rf "$archive"; [ -z "${stage:-}" ] || rm -rf "$stage"' RETURN
    url="https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}/bun-linux-${arch}.zip"
    rldyour::download_verified_file "$url" "$sha" "$archive"
    extract_dir="$stage/extracted"
    mkdir "$extract_dir"
    unzip -q "$archive" -d "$extract_dir"
    mv "$extract_dir/bun-linux-${arch}/bun" "$stage/bun"
    rm -rf "$extract_dir"
    chmod 0755 "$stage/bun"
    [ "$("$stage/bun" --version 2>/dev/null)" = "$BUN_VERSION" ] || {
      rldyour::log "error" "staged Bun artifact did not report ${BUN_VERSION}"
      return 1
    }
    rldyour::ubuntu::write_runtime_receipt "$stage" bun "$BUN_VERSION" "$sha" bun || return 1
    mv "$stage" "$destination"
    stage=""
    rm -f "$archive"
    trap - RETURN
  fi
  rldyour::ubuntu::preflight_managed_link bun "$HOME/.local/share/rldyour/bun"
  rldyour::ubuntu::preflight_managed_link bunx "$HOME/.local/share/rldyour/bun"
  ensure_managed_tool_link bun "$destination/bun" "$HOME/.local/share/rldyour/bun"
  ensure_managed_tool_link bunx "$destination/bun" "$HOME/.local/share/rldyour/bun"
  [ "$("$HOME/.local/bin/bun" --version)" = "$BUN_VERSION" ]
}

# Shared installer for a single pinned, content-addressed standalone binary
# (starship/atuin/carapace). Mirrors ensure_uv/ensure_bun: download the tracked
# SHA-256 tarball, stage it, verify the reported version, write a runtime
# receipt, and publish exactly one managed PATH link. External PATH binaries are
# preserved but never trusted; an unmanaged/tampered destination is fail-closed.
rldyour::ubuntu::ensure_standalone_tool() {
  local name=$1 version=$2 url=$3 sha=$4 strip=$5 binrel=$6
  local destination parent archive stage namespace
  namespace="$HOME/.local/share/rldyour/${name}"
  destination="${namespace}/${version}"
  parent="$(dirname "$destination")"
  if [ "$RLDYOUR_DRY_RUN" -eq 1 ]; then
    rldyour::log "info" "[DRY-RUN] verify or install managed ${name} ${version} from the tracked SHA-256 artifact; external PATH binaries are not trusted"
    return 0
  fi
  mkdir -p "$HOME/.local/bin" "$parent"
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    if ! rldyour::ubuntu::validate_runtime_receipt \
      "$destination" "$name" "$version" "$sha" "$binrel" ||
      ! "$destination/$binrel" --version 2>/dev/null | grep -Fq "$version"; then
      rldyour::log "error" "unmanaged or tampered ${name} destination exists; preserved: $destination"
      return 1
    fi
  else
    archive="$(mktemp)"; stage="$(mktemp -d "$parent/.${name}-${version}.tmp.XXXXXX")"
    trap 'rm -rf "$archive"; [ -z "${stage:-}" ] || rm -rf "$stage"' RETURN
    rldyour::download_verified_file "$url" "$sha" "$archive" || return 1
    tar -xzf "$archive" --strip-components="$strip" -C "$stage"
    [ -x "$stage/$binrel" ] || {
      rldyour::log "error" "staged ${name} artifact is missing ${binrel}"
      return 1
    }
    "$stage/$binrel" --version 2>/dev/null | grep -Fq "$version" || {
      rldyour::log "error" "staged ${name} artifact did not report ${version}"
      return 1
    }
    rldyour::ubuntu::write_runtime_receipt "$stage" "$name" "$version" "$sha" "$binrel" || return 1
    mv "$stage" "$destination"
    stage=""
    rm -f "$archive"
    trap - RETURN
  fi
  rldyour::ubuntu::preflight_managed_link "$name" "$namespace"
  ensure_managed_tool_link "$name" "$destination/$binrel" "$namespace"
  "$HOME/.local/bin/$name" --version 2>/dev/null | grep -Fq "$version"
}

ensure_starship() {
  rldyour::section "Ensure Starship ${STARSHIP_VERSION}"
  local triple sha
  case "$(uname -m)" in
    x86_64|amd64) triple="x86_64-unknown-linux-gnu"; sha="$STARSHIP_SHA256_X64" ;;
    aarch64|arm64) triple="aarch64-unknown-linux-musl"; sha="$STARSHIP_SHA256_ARM64" ;;
    *) rldyour::log "error" "Starship ${STARSHIP_VERSION} has no tracked artifact for $(uname -m)"; return 1 ;;
  esac
  rldyour::ubuntu::ensure_standalone_tool starship "$STARSHIP_VERSION" \
    "https://github.com/starship/starship/releases/download/v${STARSHIP_VERSION}/starship-${triple}.tar.gz" \
    "$sha" 0 starship
}

ensure_atuin() {
  rldyour::section "Ensure Atuin ${ATUIN_VERSION}"
  local triple sha
  case "$(uname -m)" in
    x86_64|amd64) triple="x86_64-unknown-linux-gnu"; sha="$ATUIN_SHA256_X64" ;;
    aarch64|arm64) triple="aarch64-unknown-linux-gnu"; sha="$ATUIN_SHA256_ARM64" ;;
    *) rldyour::log "error" "Atuin ${ATUIN_VERSION} has no tracked artifact for $(uname -m)"; return 1 ;;
  esac
  # atuin tarballs nest the binary under atuin-<triple>/; strip that leading dir.
  rldyour::ubuntu::ensure_standalone_tool atuin "$ATUIN_VERSION" \
    "https://github.com/atuinsh/atuin/releases/download/v${ATUIN_VERSION}/atuin-${triple}.tar.gz" \
    "$sha" 1 atuin
}

ensure_carapace() {
  rldyour::section "Ensure Carapace ${CARAPACE_VERSION}"
  local arch sha
  case "$(uname -m)" in
    x86_64|amd64) arch="amd64"; sha="$CARAPACE_SHA256_X64" ;;
    aarch64|arm64) arch="arm64"; sha="$CARAPACE_SHA256_ARM64" ;;
    *) rldyour::log "error" "Carapace ${CARAPACE_VERSION} has no tracked artifact for $(uname -m)"; return 1 ;;
  esac
  rldyour::ubuntu::ensure_standalone_tool carapace "$CARAPACE_VERSION" \
    "https://github.com/carapace-sh/carapace-bin/releases/download/v${CARAPACE_VERSION}/carapace-bin_${CARAPACE_VERSION}_linux_${arch}.tar.gz" \
    "$sha" 0 carapace
}

# Optional, explicit-opt-in, reversible login-shell change. OFF by default; only
# runs when RLDYOUR_SET_LOGIN_SHELL=1. Ensures the real zsh binary is listed in
# /etc/shells, records the prior login shell for rollback, then chsh the owner.
ensure_login_shell() {
  [ "$SET_LOGIN_SHELL" -eq 1 ] || {
    rldyour::log "info" "login shell change disabled (set RLDYOUR_SET_LOGIN_SHELL=1 to opt in)"
    return 0
  }
  rldyour::section "Set zsh as the login shell (opt-in)"
  local zsh_bin owner prev_file current
  zsh_bin="$(command -v zsh 2>/dev/null || true)"
  [ -n "$zsh_bin" ] || {
    rldyour::log "error" "zsh not found; cannot set the login shell"
    return 1
  }
  # Refuse anything but a real, root-owned system zsh (never a $HOME shim).
  case "$zsh_bin" in
    /usr/bin/zsh|/bin/zsh|/usr/local/bin/zsh) ;;
    *)
      rldyour::log "error" "refusing to set an unexpected zsh path as login shell: $zsh_bin"
      return 1
      ;;
  esac
  owner="$(id -un)"
  prev_file="$HOME/.config/rldyour/previous-login-shell"
  if [ "$RLDYOUR_DRY_RUN" -eq 1 ]; then
    rldyour::log "info" "[DRY-RUN] ensure ${zsh_bin} is in /etc/shells, record the prior login shell to ${prev_file}, then chsh -s ${zsh_bin} ${owner}"
    return 0
  fi
  if ! grep -Fxq "$zsh_bin" /etc/shells 2>/dev/null; then
    printf '%s\n' "$zsh_bin" | rldyour::ubuntu::as_root tee -a /etc/shells >/dev/null
  fi
  current="$(getent passwd "$owner" | awk -F: '{ print $7 }')"
  if [ "$current" = "$zsh_bin" ]; then
    rldyour::log "ok" "login shell already ${zsh_bin}"
    return 0
  fi
  mkdir -p "$(dirname "$prev_file")"
  if [ ! -f "$prev_file" ]; then
    printf '%s\n' "$current" >"$prev_file"
    chmod 0600 "$prev_file"
  fi
  rldyour::ubuntu::as_root chsh -s "$zsh_bin" "$owner" || {
    rldyour::log "error" "chsh failed; login shell unchanged"
    return 1
  }
  rldyour::log "ok" "login shell set to ${zsh_bin}; rollback: chsh -s \"\$(cat ${prev_file})\" ${owner}"
}

install_python_source_tools() {
  rldyour::section "Install isolated Python source-analysis tools"
  local entry name version
  for entry in "${PYTHON_SOURCE_TOOLS[@]}"; do
    name="${entry%%==*}"
    version="${entry#*==}"
    # Reproducible: skip only when the EXACT pinned version is already installed;
    # otherwise force-install the pin so a stale/divergent version is corrected.
    if [ "${RLDYOUR_DRY_RUN:-1}" -eq 1 ]; then
      # `uv tool list` materializes ~/.cache/uv before it can answer.
      rldyour::log "info" "[DRY-RUN] ensure pinned uv tool: ${entry}"
      continue
    fi
    if uv tool list 2>/dev/null | grep -Eq "^${name}[[:space:]]+v?${version//./\\.}([[:space:]]|$)"; then
      rldyour::log "ok" "pinned uv tool present: ${entry}"
    else
      rldyour::run uv tool install --force "$entry"
    fi
  done
}

install_bun_lsps() {
  rldyour::section "Install registry-backed language servers and source checks"
  local entry name version
  for entry in "${BUN_LSP_PACKAGES[@]}"; do
    name="${entry%@*}"
    version="${entry##*@}"
    # Reproducible: skip only when the EXACT pinned version is already installed;
    # otherwise install the pin so a stale/divergent version is corrected.
    if [ "${RLDYOUR_DRY_RUN:-1}" -eq 1 ]; then
      # `bun pm ls -g` creates ~/.bun/install/global before it can answer, so a
      # plan may not ask. State the pin the apply will converge on.
      rldyour::log "info" "[DRY-RUN] ensure pinned Bun source tool: ${entry}"
      continue
    fi
    if bun pm ls -g 2>/dev/null | grep -Fq "${name}@${version}"; then
      rldyour::log "ok" "pinned Bun source tool present: ${entry}"
    else
      rldyour::run bun add -g --ignore-scripts "$entry"
    fi
  done
}

install_ai_runtimes() { rldyour::install_vendor_ai_clis; }

# Set by install_gui_apps when a required desktop step failed. Reported at the
# end of main so a cosmetic-looking layer cannot strand the layers behind it,
# and cannot report success either.
GUI_LAYER_FAILED=0

install_gui_apps() {
  if [ "$PROFILE" = "server" ] || [ "$GUI_ENABLED" -ne 1 ]; then
    rldyour::log "info" "GUI application layer disabled"
    return 0
  fi
  rldyour::section "Install verified Ubuntu GUI applications"
  # Desktop customization: GNOME dock, Russian layout, Chrome, Firefox removal.
  rldyour::section "Configure Ubuntu desktop (dock, keyboard, browser)"
  local desktop_script
  desktop_script="$(dirname "${BASH_SOURCE[0]}")/desktop.sh"
  if [ -f "$desktop_script" ]; then
    # desktop.sh now distinguishes a cosmetic step from a required one and
    # returns non-zero only for the latter. Swallowing that into a warning is
    # what let a desktop missing required applications, or still carrying Firefox, report a
    # successful apply and then pass strict verification.
    if ! rldyour::run bash "$desktop_script"; then
      GUI_LAYER_FAILED=1
      rldyour::log "error" "desktop customization failed a required step"
    fi
  fi
}

run_server_layer() {
  local resolved_user=""
  # No Docker work for the plain desktop profile. Server and desktop-builds
  # both reach this function; desktop-builds installs Docker-only via --skip-baseline.
  if [ "$PROFILE" = "desktop" ]; then
    return 0
  fi
  if [ "$SKIP_SYSTEM" -eq 1 ]; then
    return 0
  fi
  if ! is_supported_ubuntu; then
    if [ "$RLDYOUR_DRY_RUN" -eq 1 ]; then
      rldyour::section "Ubuntu server module"
      rldyour::log "info" "[DRY-RUN] Docker Engine ($DOCKER_MODE)"
      [ "$PROFILE" != "desktop-builds" ] || rldyour::log "info" "[DRY-RUN] server baseline skipped"
      rldyour::log "info" "[DRY-RUN] UFW=$ENABLE_UFW, SSH hardening=$HARDEN_SSH, Fail2ban=$WITH_FAIL2BAN"
      return 0
    fi
    rldyour::log "error" "server layer requires Ubuntu 24.04 or 26.04"
    return 2
  fi
  local -a args=(--docker-mode "$DOCKER_MODE" --skip-verify)
  # desktop-builds installs Docker only — no openssh/chrony/unattended-upgrades.
  if [ "$PROFILE" = "desktop-builds" ]; then
    args+=(--skip-baseline)
  fi
  if [ "$RLDYOUR_DRY_RUN" -eq 1 ]; then args+=(--plan); else args+=(--apply); fi
  [ "$ENABLE_UFW" -eq 1 ] && args+=(--enable-ufw)
  if [ "$HARDEN_SSH" -eq 1 ]; then
    resolved_user=$(rldyour::ubuntu_server::resolve_ssh_user "${RLDYOUR_SERVER_SSH_USER:-}")
    export RLDYOUR_SERVER_SSH_USER=$resolved_user
    args+=(--harden-ssh --ssh-user "$resolved_user")
  fi
  [ "$WITH_FAIL2BAN" -eq 1 ] && args+=(--enable-fail2ban)
  rldyour::ubuntu_server::main "${args[@]}"
}

# Record the proven device state as a canonical receipt. This runs only after
# strict verification has passed, so the receipt describes a state something
# else already proved -- it is a record, never the proof itself. ADR 0007
# describes this mechanism; until this call existed, nothing invoked it and the
# document described something that did not run.
build_device_receipt() {
  rldyour::section "Record the device integrity receipt"
  python3 "$REPO_ROOT/scripts/device_integrity.py" build --profile "$PROFILE" --replace-invalid || {
    rldyour::log "error" "device receipt could not be built from the applied state"
    return 1
  }
}

verify_apply() {
  if [ "$RLDYOUR_DRY_RUN" -eq 1 ]; then
    rldyour::log "info" "plan complete; verification runs only after apply"
  elif [ "$SKIP_CHECKS" -eq 0 ]; then
    RLDYOUR_PROFILE="$PROFILE" RLDYOUR_GUI_ENABLED="$GUI_ENABLED" \
      RLDYOUR_DOCKER_MODE="$DOCKER_MODE" \
      RLDYOUR_SERVER_ENABLE_UFW="$ENABLE_UFW" \
      RLDYOUR_SERVER_HARDEN_SSH="$HARDEN_SSH" \
      RLDYOUR_SERVER_ENABLE_FAIL2BAN="$WITH_FAIL2BAN" \
      bash "$SCRIPT_DIR/verify.sh" --strict
    build_device_receipt
  fi
}

main() {
  local user_tools_failed=0
  if [ "${1:-}" = "--help" ]; then
    usage
    exit 0
  fi

  rldyour::assert_root "$REPO_ROOT"
  rldyour::ensure_path
  validate_target
  local privilege_required=0
  if [ "$SKIP_SYSTEM" -eq 0 ] || { [ "$PROFILE" != server ] && [ "$GUI_ENABLED" -eq 1 ]; }; then
    privilege_required=1
  fi
  rldyour::privilege::preflight "$PROFILE" "$GUI_ENABLED" "$privilege_required"
  rldyour::section "macos-ubuntu-bootstrap (Ubuntu) installer"
  rldyour::log "info" "mode: $([ "$RLDYOUR_DRY_RUN" -eq 1 ] && echo dry-run || echo apply); profile: $PROFILE; gui: $GUI_ENABLED; docker: $DOCKER_MODE; policy: $LOCAL_EXECUTION_POLICY"

  if [ "$SKIP_SYSTEM" -eq 0 ]; then
    install_apt_baseline
    ensure_node
    ensure_uv
    ensure_bun
    ensure_starship
    ensure_atuin
    ensure_carapace
    rldyour::ensure_path
    install_python_source_tools
    rldyour::ensure_git_perf
    rldyour::ensure_git_delta_config
    rldyour::install_terminal_configs "$REPO_ROOT/templates/terminal"
    ensure_login_shell
  else
    rldyour::log "warn" "system layer skipped by explicit recovery flag"
  fi

  [ "$SKIP_LSPS" -eq 1 ] || install_bun_lsps
  [ "$SKIP_LSPS" -eq 1 ] || install_compiled_language_hosts

  # Herdr is useful locally and over SSH, so it is installed on every profile.
  # Telegram and desktop integration remain GUI-only.
  if ! install_user_tools; then
    user_tools_failed=1
  fi
  if [ "$GUI_ENABLED" -eq 1 ]; then
    install_desktop_entries
    case "$(uname -m)" in
      x86_64|amd64)
        rldyour::ubuntu::install_telegram_update_policy
        rldyour::ubuntu::install_telegram_desktop_assets
        # Migrate the favorite before retiring legacy/generated launchers.
        rldyour::ubuntu::configure_telegram_desktop_integration
        rldyour::ubuntu::retire_telegram_legacy_managed_entry
        rldyour::ubuntu::retire_telegram_generated_integrations
        rldyour::ubuntu::retire_telegram_userapp_entries
        rldyour::ubuntu::configure_telegram_desktop_integration
        ;;
    esac
  else
    rldyour::log "info" "desktop entries skipped: gui disabled"
  fi
  install_gui_apps
  run_server_layer

  # The harness layer runs LAST of the installing layers, and deliberately so.
  # It delegates to a separate module whose own fail-closed guards depend on local
  # state this repository does not own: a stale builder profile under the harness
  # target, or a checkout whose modes came from the caller's umask. Under
  # `set -euo pipefail` an abort here used to strand every layer behind it - the
  # language servers, compiled hosts, and pinned scanners
  # verify.sh requires. Ordering it last keeps the failure fatal, which it must be,
  # while making it fatal to itself instead of to the whole device.
  [ "$SKIP_AI" -eq 1 ] || install_ai_runtimes

  # Every optional-layer failure is reported here, once, after every layer has
  # been attempted. The user-tool result used to be reported earlier, before
  # install_gui_apps, run_server_layer and install_ai_runtimes -- so a single
  # divergent Herdr, which is a user tool on every profile including server,
  # left a server without Docker, without the vendor AI CLIs and without
  # verification, while the message claimed every repair had been attempted.
  # A failure here must stay fatal to the run; it must not be fatal to the
  # layers behind it.
  if [ "$user_tools_failed" -ne 0 ]; then
    rldyour::log "error" "one or more user tools remain unmanaged or divergent; every other layer was still attempted"
  fi
  if [ "$GUI_LAYER_FAILED" -ne 0 ]; then
    rldyour::log "error" "desktop customization failed a required step; every other layer was still attempted"
  fi
  if [ "$user_tools_failed" -ne 0 ] || [ "$GUI_LAYER_FAILED" -ne 0 ]; then
    return 1
  fi
  verify_apply
  rldyour::log "info" "Run 'bash scripts/auth-handoff.sh' for user-controlled sign-in steps."
}

# Guard so the main flow only runs when executed directly, not when sourced.
# This mirrors the pattern in scripts/ubuntu/server.sh and makes install.sh safe
# to source from tests and other scripts that only need its function definitions.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
