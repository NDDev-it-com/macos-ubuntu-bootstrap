# Установка и матрица зависимостей

## 1) План установки

- `bash scripts/bootstrap.sh --platform macos`
- `bash scripts/bootstrap.sh --platform ubuntu`
- `bash scripts/bootstrap.sh --platform macos --apply`
- `bash scripts/bootstrap.sh --platform ubuntu --apply`
- `bash scripts/ci/validate.sh` (CI-safe check)

## 2) Наборы зависимостей

### macOS

#### Системный слой

- `git`
- `curl`
- `ca-certificates`
- `brew` (Homebrew)
- `node` (target >=22)
- `go`
- `shellcheck`
- `llvm` (для `clangd`)
- `cmake`
- `vscode-langservers-extracted`
- `docker-language-server`
- `taplo`
- `marksman`
- `qtdeclarative`
- `qtlanguageserver`
- `uv`
- `bun`
- `python3`
- `rustup` + `rust-analyzer`
- `dart`

#### AI CLI рантаймы

- `claude-code` → `@anthropic-ai/claude-code@2.1.199`
- `codex` → `@openai/codex@0.142.5`
- `opencode` → `opencode-ai@1.17.13`
- `agy` → `https://antigravity.google/cli/install.sh`
- `mimo` → `@mimo-ai/cli@0.1.4`

#### Python tooling (через `uv tool`)

- `pyright-langserver`
- `pyright`
- `ruff`
- `pytest`

#### LSP / терминальные language-серверы

- `typescript`
- `typescript-language-server`
- `yaml-language-server`
- `bash-language-server`
- `dockerfile-language-server-nodejs` (команда `docker-language-server`)
- `vscode-langservers-extracted` (HTML/CSS/JSON servers)
- `taplo`
- `marksman`
- `rust-analyzer`
- `gopls`
- `clangd`

### Ubuntu / server

#### Системный слой

- `ca-certificates`
- `build-essential`
- `clang`
- `clangd`
- `curl`
- `gpg`
- `git`
- `jq`
- `lsb-release`
- `node` (target >=22 via NodeSource)
- `python3`
- `python3-pip`
- `shellcheck`
- `unzip`
- `wget`
- `zip`
- `uv`
- `bun`
- `rustup` + `rust-analyzer`
- `dart`
- `go` (`golang-go`)

#### AI CLI рантаймы

- `claude-code` → `@anthropic-ai/claude-code@2.1.199`
- `codex` → `@openai/codex@0.142.5`
- `opencode` → `opencode-ai@1.17.13`
- `agy` → `https://antigravity.google/cli/install.sh`
- `mimo` → `@mimo-ai/cli@0.1.4`

#### Python tooling (через `uv tool`)

- `pyright-langserver`
- `pyright`
- `ruff`
- `pytest`

#### LSP / терминальные language-серверы

- `typescript`
- `typescript-language-server`
- `yaml-language-server`
- `bash-language-server`
- `dockerfile-language-server-nodejs` (команда `docker-language-server`)
- `vscode-langservers-extracted` (HTML/CSS/JSON servers)
- `taplo`
- `marksman`
- `rust-analyzer`
- `gopls`
- `clangd`

## 3) CI/CD

CI для модуля:

- workflow: `.github/workflows/ci.yml`
- триггеры: `push` в `main`, `pull_request`, `workflow_dispatch`
- матрица: `ubuntu-latest`, `macos-latest`
- шаги:
  - `bash scripts/ci/validate.sh` (syntax + shellcheck + contract + plan-run)
  - `bash scripts/bootstrap.sh --platform ${{matrix.platform}} --plan --skip-checks`
  - cross-check "нецелевой" платформы в plan режиме

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
