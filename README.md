pipeline-common
================

Reusable Azure DevOps YAML pipeline templates to standardize validation and deployment workflows across repositories. Consumers extend the main template via a dispatcher pipeline to keep task selection and configuration modular.

Highlights
- Enforced entry via `templates/main.yml` (use Azure DevOps “Protect YAML pipelines” to enforce extends from this repo/ref).
- Modular stages/jobs/tasks for Bicep, Terraform, Pester, and PowerShell.
- Automatic variable loading from common/env/region files.
- Route-to-live orchestration with optional per-environment review artifacts (Terraform plan / Bicep what-if).
- Pre/Post deploy hooks.
- No inline scripts — all execution goes through `scripts/` + reusable task templates.

Structure
- `templates/main.yml` – enforced entry. Composes validation, optional review, and environment deploy stages.
- `templates/stages/*` – validation, review, environment deploy.
- `templates/jobs/*` – task-specific jobs (bicep, terraform, pester, powershell, pre/post hooks).
- `templates/steps/*` – reusable single-step templates (AzureCLI, PowerShell, publish/download artifacts, publish test results).
- `templates/steps/download-secure-file.yml` – reusable secure file download.
- `templates/variables/include.yml` – compile-time variable includes (common/region-only/env/env+region) with include flags.
- `examples/` – copy-paste consumer samples (top-level pipeline, settings, dispatcher, vars/).
- `scripts/` – centralized script implementations used by tasks (terraform, bicep, pester, examples).

Dispatcher and Tagging
- The dispatcher declares `resources.repositories` for this repo and sets the `ref` to a default (e.g., `refs/tags/v1.0.0` or a branch).
- You can override the `ref` by setting the `pipelineCommonRef` parameter in your settings file.
- Azure DevOps supports using template expressions for `resources.repositories[*].ref` at compile time; variables are not allowed here.

Enforce Extends
- In Azure DevOps project settings, enable “Protect YAML pipelines” and configure template enforcement, limiting pipelines to extend from this repository/ref.

Usage
- See `examples/consumer/*` for a ready-to-copy set of files for a consumer repo.
- Example schedule snippet is included in `examples/consumer/azure-pipelines.yml` (commented).

Global scripting
- PowerShell Core everywhere (pwsh). No bash or inline scripts.
- All scripts live under `scripts/` and are invoked via reusable task templates.

Pools & Variables
- Agent pool selection is provided by consumers (default + per-environment override) and passed into templates.
- Variable groups can be supplied via `variableGroups`.
- Variables are loaded at compile-time from common/env/region YAML files with deterministic order. Include flags allow safely omitting layers (no blank files required).

Deployment & RTL integrity
- Setup stage publishes source snapshot as an artifact; all later jobs download it to ensure identical inputs.
- Deployment uses `deployment` jobs bound to Azure DevOps Environments for approvals/checks.
- Regional rollouts per environment are supported (primary/secondary); stages include region in the display name.
- Optional production gate (`enableProduction`) and skip-environments list enforced in templates.
- Allowed branches per environment enforced via `scripts/branch_check.ps1`.

Validation
- Built-in validation includes: environment model checks, Bicep lint, Terraform fmt/validate, PSScriptAnalyzer, Pester.
- Consumers can add custom validation scripts that run against the locked source snapshot.

Additional integrations
- Additional repositories: declare in settings under `configuration.additionalRepositories`; dispatcher adds resources and jobs checkout them automatically.
- Key Vault secrets import: configure `configuration.keyVault` (name + secretsFilter) to load masked variables before jobs.
- DR invocation mode: pipeline parameter `drInvocation`; when true, deploys only to configured `env.drRegion` and gates on `dependsOnDRRegion`.

Token replacement
- Integrates Replace Tokens extension with `templates/steps/replace-tokens.yml` for review/apply phases.

Route-to-live integrity
- A `setup` stage publishes a snapshot of the self repository as a pipeline artifact.
- Every subsequent job downloads that exact snapshot and uses it as its working copy (no fresh checkouts of `self`).
- This guarantees the same files/versions are used throughout validation, review, and deployment stages.

Reusable task templates
- Azure CLI: `templates/steps/azurecli.yml` (scriptPath + args + optional service connection)
- PowerShell: `templates/steps/powershell.yml` (scriptPath + args + pwsh)
- Publish artifact: `templates/steps/publish-artifact.yml`
- Download artifact: `templates/steps/download-artifact.yml`
- Publish test results: `templates/steps/publish-test-results.yml`

Notes
- Terraform steps use shell scripting for portability. If your org uses Microsoft’s Terraform tasks, swap the script with `TerraformCLI@1` tasks.
- Bicep uses `AzureCLI@2`. Ensure the service connection has appropriate permissions.
- Variable files are YAML templates containing a `variables:` root.
- Review stages only run for tasks that support review artifacts (Terraform, Bicep).
