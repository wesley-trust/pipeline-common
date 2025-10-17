# pipeline-common

Reusable Azure DevOps YAML templates that standardise validation and deployment workflows for Wesley Trust repositories. Consumer pipelines call this repo through the dispatcher so that stages, jobs, and scripts stay consistent across Bicep, Terraform, and PowerShell workloads.

## Quick Links
- `AGENTS.md` – AI-focused handbook explaining runtime behaviour and validation tooling.
- `docs/CONFIGURE.md` – canonical parameter reference and deep-dive guidance for consumers.
- `pipeline-dispatcher` repo – dispatcher templates that lock this repository and merge configuration defaults.
- `pipeline-examples` repo – sample consumer pipelines showing how to compose `*.pipeline.yml` and `*.settings.yml` pairs.

## Why It Exists
- Enforce a single entry point: all pipelines must extend `templates/main.yml` so initialise, validation, review, and deploy stages run with the same rules.
- Provide modular building blocks: stages, jobs, and steps can be enabled per action group to support Terraform, Bicep, and PowerShell workloads.
- Protect route-to-live: initialise publishes a snapshot that every later job reuses, ensuring deployments operate on the exact validated sources.
- Keep scripts reusable: all execution happens via PowerShell modules under `scripts/`, avoiding inline tooling drift across repos.

## Repository Layout
- `templates/main.yml` – master template that composes initialise, validation, optional review, and environment deploy stages.
- `templates/stages/` – stage definitions such as `validation-stage.yml`, `review-stage.yml`, and `environment-region-deploy-stage.yml`.
- `templates/jobs/` – technology-specific jobs for Terraform, Bicep, PowerShell, and initialise helpers.
- `templates/steps/` – single-step templates (AzureCLI, PowerShell, publish/download artifacts, Replace Tokens, Key Vault import, etc.).
- `templates/variables/include.yml` – compile-time matrix controlling which variable files (common/env/region/env-region) are loaded.
- `templates/variables/include-overrides.yml` – injects action-level overrides (dynamic deployment versions, suffix tokens, arbitrary key/value pairs) when action groups enable variable overrides.
- `scripts/` – PowerShell implementations used by jobs (initialise installers, validators, Terraform/Bicep runners, previews).
- `tests/` – Pester suites covering template compilation and helper scripts. `scripts/invoke_local_tests.ps1` orchestrates them locally.
- `config/` – optional configuration for Azure DevOps preview tooling (for example `config/azdo-preview.config.psd1` with org/project defaults).
- `docs/` – supporting documentation, including `CONFIGURE.md`.
- `archive/` – staging area for deprecated assets that should remain available for audit.

## Working With the Dispatcher
1. Consumer repository defines two files: `<service>.pipeline.yml` (parameters) and `<service>.settings.yml` (dispatcher handshake).
2. The settings file declares repository `PipelineDispatcher` and extends `/templates/pipeline-configuration-dispatcher.yml@PipelineDispatcher`.
3. The dispatcher merges opinionated defaults, then re-extends `/templates/pipeline-common-dispatcher.yml@PipelineDispatcher`, which declares this repo as `PipelineCommon` and calls `templates/main.yml`.
4. Action groups, environment metadata, validation toggles, and additional resources flow through the `configuration` object to this repo.

## Validation and Testing
- Run `pwsh -File scripts/invoke_local_tests.ps1` for local smoke tests before pushing.
- PowerShell action groups can set `kind: pester` so the templates wire up `PublishTestResults@2` automatically, following the naming convention `TestResults/<actionGroup>_<action>.xml`. Override with `testResultsFiles` when consumer scripts emit to a custom path.
- To preview how Azure DevOps compiles templates, export the required PAT environment variables and execute `scripts/preview_examples.ps1` or `scripts/preview_pipeline_definitions.ps1` (docs cover parameters).
- CI pipeline (`azure-pipelines.yml`) executes the same validation suite with NUnit reporting; configure a PAT as secret `AzureDevOpsPat` when enabling it in Azure DevOps.
- PowerShell action groups can opt into `variableOverridesEnabled: true` to inject ephemeral variables (for example, dynamic deployment versions or test-only flags). Overrides are processed via `templates/variables/include-overrides.yml`; see `docs/CONFIGURE.md` for schema details.

## Extending the Templates
- Add new jobs or steps under `templates/jobs/` and `templates/steps/` so they can be reused by multiple consumers.
- Use feature flags in `configuration` when introducing behaviour that existing pipelines should opt into gradually.
- When tests or preview jobs need unique identifiers, supply `variableOverridesEnabled: true` plus `variableOverrides` on an action group. The overrides merge with the standard variable includes and expose dynamic suffix helpers from `include-overrides.yml`.
- Document schema or behavioural changes in both this README and `docs/CONFIGURE.md`, then communicate through dispatcher release notes so consumers can adopt safely.

## Related Repositories
- `wesley-trust/pipeline-dispatcher` – dispatcher templates that lock this repo and apply shared defaults.
- `wesley-trust/pipeline-examples` – example consumer repos demonstrating action groups, schedules, and environment overrides.
- Service repositories such as `bicep-container-services` and `bicep-network-services` consume these templates via the dispatcher.

## Getting Help
Raise issues or discussions in the corresponding GitHub project. When reporting a problem, include:
- Consumer repository + branch.
- Dispatcher ref (`PipelineDispatcher` resource) and desired `PipelineCommon` ref.
- The compiled YAML snippet or validation output that highlights the failure.
