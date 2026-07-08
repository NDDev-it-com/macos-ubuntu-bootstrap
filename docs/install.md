# Установка и матрица зависимостей

## 1) План установки

- `bash scripts/bootstrap.sh --platform macos`
- `bash scripts/bootstrap.sh --platform ubuntu` (профиль по умолчанию: `server`)
- `bash scripts/bootstrap.sh --platform ubuntu --profile desktop`
- `bash scripts/bootstrap.sh --platform macos --apply`
- `bash scripts/bootstrap.sh --platform ubuntu --apply` (server, headless)
- `bash scripts/bootstrap.sh --platform ubuntu --profile desktop --apply`
- `bash scripts/ci/validate.sh` (CI-safe check)
- `bash scripts/ci/lint.sh` (shell syntax + shellcheck for all installer scripts)

## 1a) Профили: server vs desktop (`--profile`, 0.2.8)

Профиль ортогонален ОС: `--profile server|desktop`. По умолчанию `auto` -
macOS всегда `desktop` (это GUI-воркстейшн), Ubuntu по умолчанию `server`.

- **server** (headless Ubuntu): полный terminal-first CLI-стек - shell, `starship`,
  `atuin`, `tmux`, `zoxide`, `fzf`, `carapace`, все CLI dev-инструменты, LSP, AI CLI,
  browser/CloakBrowser слой. **Без GUI-приложений.** Сервер полноценно работает в терминале.
- **desktop**: слой `server` **плюс** GUI-desktop-слой - терминал-эмулятор (Ghostty:
  на macOS через Homebrew cask, на Ubuntu через snap, best-effort) и Nerd-шрифт
  (JetBrainsMono Nerd Font). macOS поддерживает только `desktop`.

## 2) Наборы зависимостей

### macOS

#### Системный слой

- `git`
- `curl`
- `ca-certificates`
- `brew` (Homebrew)
- `node` (target >=22)
- `go`
- `shellcheck`, `shfmt`
- `llvm` (для `clangd`)
- `cmake`, `qt` (заголовки Qt для clangd C++/Qt LSP)
- `openjdk` (JDK для jdtls/Kotlin LSP; линкуется через `brew link --force`)
- `vscode-langservers-extracted`
- `docker-language-server`
- `taplo`, `marksman`, `markdown-oxide`
- `terraform-ls`, `helm-ls`, `cmake-language-server`
- `libxml2`, `xmlstarlet`
- `uv`
- `bun`
- `python3`
- `rustup` + `rust-analyzer`
- `dart`
- `r` (R runtime для R languageserver)

#### Python tooling (через `uv tool`)

- `pyright` (поставляет оба бинарника: `pyright` и `pyright-langserver`)
- `pytest`

#### Расширенные языковые LSP (Homebrew)

- `basedpyright` (улучшенный форк pyright, фичи Pylance вне VS Code)
- `ruff` (LSP-режим встроен; lint + format для Python)
- `ty` (опционально; beta type-checker от Astral на Rust)
- `jdtls` (Java LSP, Eclipse JDT-LS)
- `kotlin-language-server` (Kotlin LSP, требует JDK)
- `gopls` (Go LSP)

#### Расширенные SQL LSP

- `postgres-language-server` (Supabase; ставится через `brew install postgres-language-server`)
- `sqls` (multi-DB SQL LSP; ставится через `go install github.com/sqls-server/sqls@latest`)

#### Quality-gate CLI (Homebrew)

- `shfmt`, `shellcheck` (shell lint + format)
- `oxlint`, `biome` (JS/TS/JSON/CSS lint + format)
- `osv-scanner` (уязвимости зависимостей, универсально)
- `gitleaks` (секреты в коде/git)
- `semgrep` (SAST, мультиязычный)
- `hadolint` (Dockerfile lint, без Docker daemon)
- `actionlint` (GitHub Actions workflows)
- `yamllint`, `markdownlint-cli2` (YAML / Markdown)

#### Базовые утилиты (Homebrew)

- `fd`, `eza`, `bat`, `xh`, `git-delta` (delta)
- `watchexec`, `hyperfine`, `just`
- `jq`, `prettier`, `pandoc`, `kubeconform`, `mise`
- search / data / http / repo (0.2.8): `ripgrep` (rg), `yq`, `dasel`, `miller` (mlr),
  `httpie`, `ghq`, `cargo-nextest`, `github-mcp-server`
- Deno JS/TS runtime (0.2.8): `deno`

#### Терминальный слой (0.2.3)

- shell-стек: `antidote`, `zsh-completions`, `olets/tap/zsh-abbr`, `starship`,
  `atuin`, `fzf`, `zoxide`, `carapace`
- Ghostty (Homebrew cask; только macOS)
- TUI/CLI: `gh`, `lazygit`, `yazi`, `jaq`, `jnv`, `duckdb`, `ast-grep`, `scc`,
  `difftastic`, `tmux`
- modern-unix волна: `dust`, `dua-cli`, `duf`, `procs`, `btop`, `doggo`,
  `gping`, `hexyl`, `sd`, `viddy`, `tealdeer`
- managed zsh-шаблоны из `templates/terminal/`: `~/.zshenv`, `~/.zprofile`,
  `~/.zshrc`, `~/.zsh_plugins.txt`, `~/.config/starship.toml` - первым идёт
  agent-gate (нейтрализация интерактива для AI-агентов); установщик никогда
  не перезаписывает файлы, изменённые пользователем (предупреждает и оставляет)
- глобальные git-ключи производительности (`core.fsmonitor`,
  `core.untrackedCache`, `fetch.writeCommitGraph`) и конфиг пейджера `delta`
  (ставится только если `delta` присутствует)

#### AI CLI рантаймы

- `claude-code` -> `@anthropic-ai/claude-code@2.1.204`
- `codex` -> `@openai/codex@0.142.5`
- `opencode` -> `opencode-ai@1.17.15`
- `agy` -> `https://antigravity.google/cli/install.sh`
- `mimo` -> `@mimo-ai/cli@0.1.4`

#### LSP / терминальные language-серверы (bun global)

- `typescript`
- `@vtsls/language-server` (замена `typescript-language-server`; выбран Zed/LazyVim)
- `yaml-language-server`
- `bash-language-server`
- `dockerfile-language-server-nodejs` (команда `docker-langserver`)
- `vscode-langservers-extracted` (HTML/CSS/JSON servers)
- `gh-actions-language-server`
- `taplo`, `marksman`, `markdown-oxide`
- `rust-analyzer`, `gopls`, `clangd`

#### R language server

- `languageserver` (R package; ставится через `R -e install.packages('languageserver')`)

#### Браузер-провайдеры

- `chrome-devtools-mcp` -> `chrome-devtools-mcp@1.5.0` (bun global)
- `playwright-cli` -> `@playwright/cli@0.1.15` (bun global) + `playwright-cli install --skills`
- Microsoft Webwright -> pinned GitHub checkout (`4a46f282...`, best-effort venv install)

#### CloakBrowser (default privacy-first Chromium)

- `cloakbrowser==0.4.8` (Python wrapper) в изолированном venv под
  `~/.local/share/rldyour/cloakbrowser/.venv`; free-tier бинарь Chromium (линия
  v146) скачивается и проверяется по Ed25519-подписи (`ensure_binary`).
- managed-лаунчеры на PATH: `cloak-chromium` (резолвит и exec'ает реальный
  версионный бинарь) и `cloak-chromium-stealth` (+ дефолтные stealth-аргументы).
- managed CDP-демон на `127.0.0.1:9222` (launchd на macOS, systemd `--user` на
  Linux, `KeepAlive`) - headless CloakBrowser, к которому каждый адаптерный
  `chrome-devtools-mcp` подключается через `--browserUrl`; Webwright/Playwright
  используют `cloak-chromium` как executable (`AGENT_BROWSER_EXECUTABLE_PATH`).
- Pro (v148+) активируется только `CLOAKBROWSER_LICENSE_KEY` из
  `~/.zshenv.secrets`, никогда не коммитится. Пропустить весь слой:
  `RLDYOUR_SKIP_CLOAKBROWSER=1`.

### Ubuntu / server

#### Системный слой (apt)

- `ca-certificates`
- `build-essential`
- `clang`, `clangd`, `cmake`
- `curl`
- `gpg`
- `git`
- `jq`, `yamllint`, `pandoc`, `fd-find`, `bat` (бинарь `batcat`), `xmlstarlet`, `libxml2-utils`
- `eza` (best-effort: есть в Debian 13 / Ubuntu 24.10+; на старых LTS пропускается с предупреждением)
- `lsb-release`
- `node` (target >=22 via NodeSource)
- `python3`, `python3-pip`
- `shellcheck`, `shfmt`
- `unzip`, `wget`, `zip`, `gnupg`
- `uv`
- `bun`
- `rustup` + `rust-analyzer`
- `dart`
- `go` (`golang-go`)
- `default-jdk` (JDK для jdtls/Kotlin LSP)
- `r-base` (R runtime для R languageserver)

#### Терминальный слой (0.2.3)

- apt-подмножество: `fzf`, `zoxide`, `tmux`, `btop`, `duf`, `hexyl`, `gh`
- официальные установщики: `starship` (starship.rs), `atuin` (setup.atuin.sh),
  `xh` (ducaale/xh install.sh)
- `antidote` через `git clone --depth=1` в `~/.antidote`
- те же managed zsh-шаблоны (`templates/terminal/`) и git-ключи
  производительности/delta-конфиг, что и на macOS

#### AI CLI рантаймы

- `claude-code` -> `@anthropic-ai/claude-code@2.1.204`
- `codex` -> `@openai/codex@0.142.5`
- `opencode` -> `opencode-ai@1.17.15`
- `agy` -> `https://antigravity.google/cli/install.sh`
- `mimo` -> `@mimo-ai/cli@0.1.4`

#### Python tooling (через `uv tool`)

- `pyright` (поставляет оба бинарника: `pyright` и `pyright-langserver`)
- `ruff`
- `pytest`
- `ty` (Astral type-checker; macOS-паритет, 0.2.8)
- `cmake-language-server` (macOS-паритет, 0.2.8)

#### LSP / терминальные language-серверы (bun global)

- `typescript`
- `@vtsls/language-server` (замена `typescript-language-server`)
- `yaml-language-server`
- `bash-language-server`
- `dockerfile-language-server-nodejs` (команда `docker-langserver`)
- `vscode-langservers-extracted` (HTML/CSS/JSON servers)
- `@taplo/cli` (taplo для Ubuntu)
- `gh-actions-language-server`
- `marksman` (pinned GitHub release)
- `rust-analyzer` (через `rustup component add`)
- `gopls` (через apt)
- `clangd` (через apt)

#### macOS-паритет modern-unix (0.2.8)

- apt: `ripgrep`, `httpie`, `miller` (mlr), `qtbase5-dev` (Qt-заголовки для clangd C++/Qt)
- cargo (best-effort, `ensure_cargo_parity_tools`): `dust`, `procs`, `sd`, `difftastic`
  (difft), `jaq`, `hyperfine`, `just`, `tealdeer` (tldr), `ast-grep`, `watchexec`,
  `gping`, `cargo-nextest`, `markdown-oxide` (LSP)
- официальные install-скрипты (best-effort, `ensure_extra_runtimes`): `deno`
  (deno.land), `mise` (mise.run), `carapace` (carapace.sh)
- **gitlab-ci-ls удалён в 0.2.8** (владелец не использует GitLab; паритет с macOS,
  где он не ставился).

#### Desktop-слой (только `--profile desktop`, 0.2.8)

- Ghostty terminal emulator через `snap install ghostty --classic` (best-effort;
  на snapless-хостах ставьте kitty/alacritty вручную).
- JetBrainsMono Nerd Font -> `~/.local/share/fonts` (+ `fc-cache`).
- Профиль `server` этот слой пропускает намеренно (headless), но получает полный
  terminal-first CLI-стек.

#### Полный LSP-паритет Ubuntu (0.2.8) — пробел закрыт

Ранее отсутствовавшие LSP теперь ставятся `ensure_parity_lsps` по проверенным
официальным каналам (best-effort, идемпотентно, dry-run-aware):

- `terraform-ls` — HashiCorp apt repo (`apt.releases.hashicorp.com`).
- `helm_ls` — GitHub release `helm_ls_linux_<arch>` (mrjosh/helm-ls, pin `v0.5.4`) → `~/.local/bin`.
- `jdtls` — Eclipse tarball (`download.eclipse.org/jdtls/snapshots`) → `~/.local/share/jdtls`
  (+ `openjdk-21-jdk`, `python3`).
- `kotlin-language-server` — GitHub release `server.zip` (fwcd, pin `1.3.13`) → `~/.local/share`
  (+ `openjdk-21-jre`).
- `postgres-language-server` — GitHub release binary (supabase-community, pin `0.25.5`) → `~/.local/bin`
  (LSP-команда `postgres-language-server lsp-proxy`).

Остаются `optional` в `ubuntu/verify.sh` (установка — best-effort загрузка бинарников,
может транзиентно упасть на конкретном хосте/арх), но ставятся автоматически.

#### Google Cloud CLI (0.2.8)

- macOS: `brew install --cask gcloud-cli` (`ensure_gcloud`).
- Ubuntu: официальный apt repo `packages.cloud.google.com`, пакет `google-cloud-cli`.
- Бинарь: `gcloud` (+ `gsutil`, `bq`).

#### Опциональные личные приложения (desktop, 0.2.8)

- macOS: casks `discord`, `obs` (`ensure_personal_apps`).
- Ubuntu desktop: snap `discord`, `obs-studio` (только `--profile desktop`).
- Отключить: `RLDYOUR_SKIP_PERSONAL_APPS=1`.

#### Quality-gate CLI (bun global, где нет apt-пакета)

- `biome`, `oxlint` (JS/TS/JSON lint + format)
- `markdownlint-cli2`, `prettier`
- `@ansible/language-server`

#### Security / quality scanners (verify.sh required, ставятся отдельными каналами)

- `basedpyright` (через `uv tool install basedpyright`)
- `osv-scanner` (binary install script от Google)
- `gitleaks` (binary install script от GitHub)
- `semgrep` (через `pip3 install --user semgrep`)
- `hadolint` (статический binary с GitHub releases)
- `actionlint` (binary install script от rhysd)
- `yamllint`, `shellcheck`, `shfmt` (через apt)

#### Расширенные SQL/R LSP (best-effort)

- `sqls` (через `go install github.com/sqls-server/sqls@latest`)
- R `languageserver` (через `R install.packages`)

#### Cargo-hosted LSPs (best-effort)

- `gitlab-ci-ls` (через `cargo install gitlab-ci-ls`)

#### Браузер-провайдеры

- `chrome-devtools-mcp` -> `chrome-devtools-mcp@1.5.0` (bun global)
- `playwright-cli` -> `@playwright/cli@0.1.15` (bun global) + `playwright-cli install --skills`
- Microsoft Webwright -> pinned GitHub checkout (`4a46f282...`, best-effort venv install)

## 3) CI/CD

CI для модуля:

- workflow: `.github/workflows/ci.yml`
- триггеры: `push` в `main`, `pull_request`, `workflow_dispatch`
- матрица: `ubuntu-latest`, `macos-latest`
- шаги:
  - `bash scripts/ci/lint.sh`
  - `bash scripts/ci/validate.sh` (syntax + shellcheck + contract + plan-run)
  - запуск `bootstrap.sh` через матричный шаг для `${{ matrix.platform }}`:
    - `mode=plan`: `bash scripts/bootstrap.sh --platform ${{matrix.platform}} --plan --skip-checks`
    - `mode=apply`: `bash scripts/bootstrap.sh --platform ${{matrix.platform}} --apply`
  - cross-check "нецелевой" платформы в plan-режиме
- параметризация workflow:
  - `mode: plan|apply` (по умолчанию `plan`)
  - `platform: both|macos|ubuntu` (по умолчанию `both`)
- примеры ручного запуска:
  - `gh workflow run .github/workflows/ci.yml -f mode=plan -f platform=both`
  - `gh workflow run .github/workflows/ci.yml -f mode=apply -f platform=macos`
- cross-platform parity:
  - при ручном `mode=plan` и `platform=both` второй job выполняет плановый cross-check целевой ОС.
- Security hardening workflows:
  - `.github/workflows/codeql.yml` - GitHub CodeQL
  - `.github/workflows/secret-scan.yml` - Gitleaks по git history
  - `.github/workflows/scorecard.yml` - OSSF Scorecard
  - `.github/workflows/dependency-review.yml` - проверка зависимостей в PR
  - `.github/workflows/dependency-check.yml` - проверка pin-совпадений между macOS и Ubuntu профилями
  - `.github/workflows/validate.yml` - базовая валидация bootstrap скриптов и контракта
  - `.github/workflows/pytest.yml` - smoke-тесты bootstrap entrypoint
  - `.github/workflows/actionlint.yml` - lint GitHub Actions workflow
  - `.github/workflows/cross-platform.yml` - валидация структуры в Linux/macOS/Windows раннерах
  - `.github/workflows/release.yml` - release manifest/SBOM/attestations/теги
- Дополнительно в репозитории включены:
  - Secret scanning + push protection
  - Dependabot security alerts + Dependabot security updates
  - Branch protection на `main` (1 review, запрет force push/delete, required code owner review, `bootstrap-gate`)

`Advanced Security`/security-oriented capabilities включены в пределах возможностей публичного режима GitHub и требований policy:
secret scanning, push protection, CodeQL, OSSF Scorecard, Dependabot alerts/updates, secret scanning, dependency review, branch protection и CI-аттестации релизов.

## 4) Проверка после установки

```bash
bash scripts/macos/verify.sh --strict --skip-optional
bash scripts/ubuntu/verify.sh --strict --skip-optional
```

Если хочется проверить со всеми опциональными runtime:

```bash
bash scripts/macos/verify.sh --strict
bash scripts/ubuntu/verify.sh --strict
```
