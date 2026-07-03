# Установка и матрица зависимостей

## 1) План установки

- `bash scripts/bootstrap.sh --platform macos`
- `bash scripts/bootstrap.sh --platform ubuntu`
- `bash scripts/bootstrap.sh --platform macos --apply`
- `bash scripts/bootstrap.sh --platform ubuntu --apply`
- `bash scripts/ci/validate.sh` (CI-safe check)
- `bash scripts/ci/lint.sh` (shell syntax + shellcheck for all installer scripts)

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
- `uv`
- `bun`
- `python3`
- `rustup` + `rust-analyzer`
- `dart`

#### AI CLI рантаймы

- `claude-code` -> `@anthropic-ai/claude-code@2.1.199`
- `codex` -> `@openai/codex@0.142.5`
- `opencode` -> `opencode-ai@1.17.13`
- `agy` -> `https://antigravity.google/cli/install.sh`
- `mimo` -> `@mimo-ai/cli@0.1.4`

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

- `claude-code` -> `@anthropic-ai/claude-code@2.1.199`
- `codex` -> `@openai/codex@0.142.5`
- `opencode` -> `opencode-ai@1.17.13`
- `agy` -> `https://antigravity.google/cli/install.sh`
- `mimo` -> `@mimo-ai/cli@0.1.4`

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
