# Copilot Instructions for AI Agents

## Project Purpose & Architecture
## Purpose & Big picture
- `pipeline-common` provides reusable Azure DevOps pipeline templates and PowerShell automation used by the dispatcher (`pipeline-dispatcher`) and consumer examples (`pipeline-examples`).
- Primary template: `templates/main.yml` — everything is composed from `templates/` and `templates/variables/include.yml`.

## What matters for an AI coding agent (quick bullets)
- Work in PowerShell-only automation. All runtime scripts live under `scripts/` (e.g. `terraform_run.ps1`, `bicep_run.ps1`, `ps_analyse.ps1`). Do not add Bash.
- Consumers extend `templates/main.yml` via the dispatcher; inspect `pipeline-dispatcher/templates/pipeline-configuration-dispatcher.yml` (entry point) and `pipeline-dispatcher/templates/pipeline-common-dispatcher.yml` (declares `PipelineCommon`) alongside `pipeline-examples/examples/consumer/*` for end-to-end usage examples.
- Validation is local-first: the harness `scripts/invoke_local_tests.ps1` is the canonical check before pushing changes.

## Key workflows & concrete commands
- Local validation (required):
  - Commit your changes to a feature branch and push. Then run:
    - `pwsh -File scripts/invoke_local_tests.ps1`
  - The harness runs Pester, YAML/template includes resolution, script reference checks and optional Azure DevOps preview checks.
- Azure preview (optional, needs PAT):
  - `pwsh -File scripts/preview_examples.ps1` and `pwsh -File scripts/preview_pipeline_definitions.ps1` (see `config/azdo-preview.config.psd1` for settings).

## Prerequisites (local agent)
- PowerShell 7.x (`pwsh`) and Git are required. The harness installs Pester and `powershell-yaml` on first run (Internet required).
- The local validation harness expects the `pipeline-examples` repo to be available next to this repo (e.g. sibling folder `../pipeline-examples`) so example consumer pipelines can be validated.

## Preview environment variables
- To run the Azure DevOps preview scripts you need a PAT and basic org/project settings. Common env vars:
  - `AZURE_DEVOPS_EXT_PAT` or `AZDO_PERSONAL_ACCESS_TOKEN` (PAT)
  - `AZDO_ORG_SERVICE_URL` (e.g. `https://dev.azure.com/<org>`)
  - `AZDO_PROJECT` (project name)
  - Optional: `AZDO_PIPELINE_IDS` (comma-separated pipeline IDs for previewing definitions)
  - `config/azdo-preview.config.psd1` can be used to avoid exporting env vars every time.

## Files & places to inspect (high value)
- `templates/main.yml` — entry point and stage composition.
- `templates/variables/include.yml` — how compile-time variable layers are included.
- `scripts/` — all deploy/validate helper scripts (`initialise_*.ps1`, `terraform_run.ps1`, `bicep_run.ps1`, `ps_analyse.ps1`).
- `docs/CONFIGURE.md`, `AGENTS.md` — behavioural and onboarding documentation.
- `tests/` — Pester-based tests used by the harness (e.g. `tests/Templates.Tests.ps1`).

## Project-specific conventions & patterns
- No Bash: PowerShell Core only. Scripts are expected to run under `pwsh`.
- Lock sources early: the initialise stage publishes a snapshot used by later stages — see `templates/stages/initialise-stage.yml` and `scripts/initialise_*.ps1`.
- Token replacement and variable includes are controlled centrally (search for `tokenTargetPatterns`, `tokenPrefix`, `tokenSuffix` in `templates/steps/`).
- `actionGroups` model: consumer `*.settings.yml` files provide `configuration.actionGroups` that the dispatcher passes through; ensure `actionGroups[*].name` is unique per environment/region.
- DR mode: consumers may set `drInvocation: true` to target DR region behaviour.
- Agent demands: some jobs use `poolRegionDemand` and expect agents to advertise `region == <regionName>` capability.

## Integration points & dependencies
- Dispatcher: `pipeline-dispatcher` composes with this repo — update both when changing dispatcher contract.
- Examples: `pipeline-examples/examples/consumer/` shows consumer settings and pipelines to mirror.
- Key Vault & additional repositories: configured via `configuration.keyVault` and `configuration.additionalRepositories` respectively.

## Quick tips for edits
- When adding scripts, place them under `scripts/` and reference them from `templates/steps/` using the existing patterns.
- Run the local harness after edits and push the branch before invoking Azure previews.
- Update `docs/CONFIGURE.md` and `AGENTS.md` when behaviour or parameters change.

## Minimal contract for adding scripts / templates / tests
- Scripts: create under `scripts/`, use `param()` for arguments, include a short header comment describing inputs/outputs, and avoid platform-specific Bash usage — `pwsh` only.
- Templates: place new steps in `templates/steps/` or jobs in `templates/jobs/`; when adding a static `script:` reference, point to a file inside `scripts/` (the harness verifies script paths).
- Tests: add a concise Pester test under `tests/` (e.g. `tests/MyFeature.Tests.ps1`) that validates template include resolution or a script's linting; the harness picks up `tests/*.Tests.ps1`.

## Troubleshooting pointers
- PSScriptAnalyzer failures: run `pwsh -File scripts/ps_analyse.ps1` locally to reproduce rules used by the harness.
- Missing template includes: the harness reports exact `template:` lines that fail to resolve — check relative paths and `templates/variables/include.yml` flags.
- Preview failures: ensure your branch is committed and pushed; preview endpoints compile the remote branch tip, not local unpushed edits.

## Where to look for examples in this repo
- Example scripts: `scripts/*_run.ps1`, `scripts/initialise_*.ps1`, `scripts/ps_analyse.ps1`.
- Example consumer pipelines: open `../pipeline-examples/examples/consumer/*.pipeline.yml`.

---

If any of these sections are unclear or you'd like me to expand examples (e.g., show a small patch that adds a script + template step + a harness test), tell me which area to expand.
