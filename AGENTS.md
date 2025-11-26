# Repository Guidelines

## Project Structure & Module Organization

- `bash/`: standalone shell utilities (git helpers, QR/UUID generators, branch pruning, gif tooling); keep new scripts hyphenated and self-contained.
- `ai/`: Codex/OpenAI-assisted workflows (auto-commit, lint/test fixers); expects API keys from `.env`.
- `python-scripts/`: Pipenv-managed utilities (e.g., DynamoDB cleanup, contact whitelist generator).
- `aws-cloudformation/`: CloudFormation templates such as `ForceMFA.json`.
- Root: `stringify.js` (JSON compactor), `k9.sh` (kill ports), `.env.example`, `gif/` outputs, `node_modules/`.

## Build, Test, and Development Commands

- Install deps: `yarn install` for Node tools; `pipenv install --dev` (Python 3.8) for Python scripts.
- JSON helper: `node stringify.js <file>` or `yarn stringify <file>` prints single-line JSON to stdout.
- Formatting: `pipenv run black .` (or `pipenv run black . --check`); `yarn watch-py` auto-formats touched `.py` files.
- Shell scripts: make executable with `chmod +x <script>` and run directly.

## Coding Style & Naming Conventions

- Shell: prefer `set -euo pipefail`, 2-space indents, lowercase-hyphen file names, and small helpers (`log`, `require_cmd`) as in `ai/gc.sh`.
- Python: format with Black, use snake_case, avoid side effects in module scope; read config from env vars when practical.
- Node: ESM modules (`"type": "module"`), semicolons, minimal dependencies; keep CLI usage and error handling consistent with `stringify.js`.

## Testing Guidelines

- No dedicated test suite; rely on targeted checks.
- Python: run `pipenv run black . --check` and execute scripts with sample data.
- Shell: `bash -n <script>` (and `shellcheck` if available); dry-run destructive commands and document expected side effects.
- Node: run helpers against fixture files to verify stdout-only behavior and non-zero exit codes on bad input.

## Commit & Pull Request Guidelines

- Follow existing history: concise, imperative subjects (e.g., “Add Codex lint auto-fix runner script”); use bodies sparingly.
- Group related script changes per commit; avoid mixing language stacks unless tightly coupled.
- PRs should describe intent, usage examples, and any required env vars or external services. Include before/after notes for scripts that mutate remote state.
- Update relevant docs and mention validation commands executed.

## Environment & Security Notes

- Copy `.env.example` to `.env` and provide `OPENAI_API_KEY` / `DEEPSEEK_API_KEY` for `ai/` helpers; never commit secrets.
- When interacting with AWS or other external systems, prefer test resources, confirm IAM permissions, and note blast radius in reviews.
