# rldyour New Mac / Ubuntu Bootstrap

Модуль подготавливает всю базу для установки и контроля AI-конфигураций:
`Claude Code`, `Codex`, `OpenCode`, `Antigravity CLI`, `MiMoCode`.

В репозитории есть две отдельные ОС-ветви с собственной иерархией:

- `scripts/macos/...` — профиль `macos`
- `scripts/ubuntu/...` — профиль `ubuntu` (для ПК/сервера)

## Быстрый старт

```bash
cd /path/to/rldyour-new-mac-or-ubuntu
bash scripts/bootstrap.sh --platform macos --apply
bash scripts/bootstrap.sh --platform ubuntu --apply
```

По умолчанию режим — план (`--plan`), без изменений в системе.

```bash
bash scripts/bootstrap.sh --platform macos
bash scripts/bootstrap.sh --platform ubuntu
```

- `--skip-system` — не трогать Node/bun/uv/rust/dart/system tools
- `--skip-ai` — не ставить AI CLI-рантаймы
- `--skip-lsps` — не ставить LSP
- `--skip-checks` — не запускать `verify`
- `--strict` — усилить поведение проверок в install/verify

## Дерево проекта

```text
.
├── .github/
│   └── workflows/
│       └── ci.yml
├── scripts/
│   ├── bootstrap.sh           # общий entrypoint для обеих ОС
│   ├── lib/
│   │   └── common.sh          # общие helpers (лог, run, require, ensure_path)
│   ├── macos/
│   │   ├── install.sh
│   │   └── verify.sh
│   ├── ubuntu/
│   │   ├── install.sh
│   │   └── verify.sh
│   └── ci/
│       ├── lint.sh
│       └── validate.sh
├── docs/
│   └── install.md
└── config/
    └── rldyour-contract.json
```

## Что ставится

- Runtime:
  - Node.js (>=22), `bun`, `python` + `uv`, `go`, `rustup`, `dart`, `git`, `curl`
- AI CLI:
  - `@anthropic-ai/claude-code@2.1.199`
  - `@openai/codex@0.142.5`
  - `opencode-ai@1.17.13`
  - `agy` (Antigravity CLI)
  - `@mimo-ai/cli@0.1.4` (`mimo`)
- Python tools (через `uv tool`):
  - `pyright-langserver`, `pyright`, `ruff`, `pytest`
- LSP:
  - `typescript`, `typescript-language-server`
  - `yaml-language-server`, `bash-language-server`
  - `vscode-langservers-extracted` (HTML/CSS/JSON)
  - `dockerfile-language-server-nodejs` (команда `docker-language-server`)
  - `taplo`
  - `marksman`
  - `rust-analyzer`, `gopls`, `clangd`

Сборка ориентирована на серверный Ubuntu и desktop/macOS и работает через shared bootstrap API:

```bash
bash scripts/bootstrap.sh --platform macos --plan --skip-checks
bash scripts/bootstrap.sh --platform ubuntu --plan --skip-checks
```

## Проверки

- `bash scripts/ci/lint.sh` — shell syntax + `shellcheck` для всех ключевых bootstrap-скриптов
- `bash scripts/ci/validate.sh` — синтаксис + shellcheck + контракт + плановые dry-run для macOS и Ubuntu
- `bash scripts/macos/verify.sh [--strict] [--skip-optional]`
- `bash scripts/ubuntu/verify.sh [--strict] [--skip-optional]`
- GitHub Actions: `.github/workflows/ci.yml` (матрица `macos-latest` + `ubuntu-latest`)
- Дополнительно:
  - `.github/workflows/codeql.yml` — CodeQL анализ (python)
  - `.github/workflows/dependency-review.yml` — проверка зависимостей в PR
  - `.github/workflows/ci.yml` включает `workflow-lint` с actionlint
  - `.github/dependabot.yml` — автообновления GitHub Actions зависимостей
- Для ручного запуска CI:
  - `gh workflow run .github/workflows/ci.yml -f mode=plan -f platform=both`
  - `gh workflow run .github/workflows/ci.yml -f mode=apply -f platform=macos`
- Inputs:
  - `mode=plan|apply` (по умолчанию `plan`)
  - `platform=both|macos|ubuntu` (по умолчанию `both`)

## Безопасность репозитория

- Включены:
  - Secret scanning
  - Secret scanning push protection
  - Dependabot security alerts
  - Dependabot security updates
  - Защита ветки `main`:
    - required reviews: 1
    - required status check: `bootstrap-gate`
    - запрет force push и удаления ветки
    - обязательное разрешение разрешения бесед в PR (conversation resolution)

## Версионность и лицензия

- CLAUDE: `2.1.199`
- Codex: `0.142.5`
- OpenCode: `1.17.13`
- MiMoCode: `0.1.4`
- Репозиторий: `AGPL-3.0-or-later` (`LICENSE`, `NOTICE`)
