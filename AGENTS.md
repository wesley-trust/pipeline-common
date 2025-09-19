# Agent Handbook

## Mission Overview
- **Repository scope:** Shared Azure DevOps pipeline templates (`pipeline-common`) consumed via the dispatcher repo (`wesley-trust/pipeline-dispatcher`). Everything here is PowerShell-first (no inline bash) and is designed to be extended through the dispatcher.
- **Primary entry point:** `templates/main.yml` – all consumer pipelines must extend this template through the dispatcher to stay compliant with the consistency rules noted in `README.md`.
- **Key philosophy:** lock sources early (initialise stage publishes a snapshot), run validation before review/deploy, and reuse scripts/tasks across all technologies (Terraform, Bicep, PowerShell).
- **License:** MIT (`LICENSE`).

## Directory Map (current as of repo snapshot)
- `README.md` – high-level purpose and highlights.
- `docs/CONFIGURE.md` – deep-dive consumer guide (parameter flow, action model, environment design, review controls, DR mode, token replacement, etc.). Treat this as the canonical reference for behaviour.
- `templates/` – main templates split by grain:
  - `main.yml` – enforced entry point; wires initialise, validation, review, deploy stages.
  - `stages/` – stage-level composition (`validation-stage.yml`, `review-stage.yml`, `environment-region-deploy-stage.yml`, `initialise-stage.yml`).
  - `jobs/` – job-level templates organised by concern (`validation/`, `review/`, `initialise/`). Jobs consume scripts exclusively.
  - `steps/` – single-step building blocks (AzureCLI, PowerShell, artifact publish/download, Replace Tokens, Key Vault import, secure file download).
  - `variables/include.yml` – compile-time include matrix controlling `common`, `region`, `env`, and `env-region` variable files via flags.
- `scripts/` – PowerShell implementations called by templates (Terraform/Bicep runners, initialise installers, branch/variable/token validators, etc.). All scripts assume pwsh and are meant to run inside the locked snapshot path when invoked from pipelines.
- `docs/` – supporting documentation.
- `archive/` – reserved for deprecated assets. Move files no longer part of the solution to this directory, maintaining structure as required.

## How Things Fit Together
1. **Consumer pipeline (`*.pipeline.yml`)** lives in the consumer repo (see `wesley-trust/pipeline-examples` for reference). It collects parameters + actionGroups and extends the matching settings template.
2. **Consumer settings (`*.settings.yml`)** declares the dispatcher resource (`wesley-trust/pipeline-dispatcher`) and passes a single `configuration` object (environments, pools, variables, actionGroups, flags, etc.).
3. **Dispatcher (`pipeline-dispatcher`)** extends `/templates/pipeline-dispatcher.yml`, which fetches this repo as resource `PipelineCommon` and re-extends `templates/main.yml` with the same `configuration`.
4. **Main template** materialises stages:
   - Optional **Initialise** (global + per-environment) – publishes source snapshot, installs tooling (Terraform/Bicep) driven by `initialise-*` jobs.
   - **Validation** – only emits jobs that are relevant based on `configuration.validation` flags and detected action group types. Enforces environment model, branch allow-list, variable include sanity, token target existence, and technology linting (Terraform fmt/validate, Bicep build, PSScriptAnalyzer).
   - Optional **Review** – runs Terraform plan / Bicep what-if / PowerShell preview jobs based on `runReviewStage`, `runTerraformPlan`, `runBicepWhatIf`, and action metadata. Outputs artifacts for manual inspection.
   - **Deploy** – per-environment deployment stages split by region (secondary first, primary last). Uses deployment jobs bound to Azure DevOps Environments for approvals. Supports DR invocation (`drInvocation`), per-action pre/post deploy hooks, token replacement, additional repo checkout, Key Vault import, manual/schedule/PR gating, and regional agent capability demands.

## Configuration Primitives
- **`configuration.environments`** (array) defines logical environments with: `name`, `class` (`development|test|acceptance|production`), `primaryRegion`, optional `secondaryRegions`, `drRegion`, `allowedBranches`, `pool` (either `{ name }` or `{ vmImage }`), optional `serviceConnection`, skip flags, and stage dependencies (`dependsOn`, `dependsOnRegion`, `dependsOnSecondaryRegions`). Production runs only when `enableProduction` is true.
- **`configuration.actionGroups`** describes the unified action model. Each group can target specific environments and nest sequential `actions`. Supported `type` values: `terraform`, `bicep`, `powershell`. Actions inherit the group type and must not declare their own. Token replacement defaults per tech can be overridden via `tokenTargetPatterns`, `tokenPrefix`, `tokenSuffix`. Use `dependsOn` to order actionGroups when sequential execution is required.
- **`configuration.validation`** toggles validation jobs (`enableBranchAllowlist`, `enableVariableIncludes`, `enableTokenTargets`). Tech-specific validator jobs light up automatically when matching action group types are present.
- **Variables** load compile-time via `templates/variables/include.yml`. Global defaults live under `configuration.variables`, per-environment overrides under `env.variables`. Flags (`includeCommon`, `includeRegionOnly`, `includeEnv`, `includeEnvRegion`) prevent missing-file failures when layers are unused.
- **Additional integrations:**
  - `configuration.additionalRepositories` → adds repo resources to dispatcher and checks them out automatically in jobs.
  - `configuration.keyVault` (`name`, `secretsFilter`) → pulls secrets via `AzureKeyVault@2` before steps.
  - `configuration.initialise` (`runGlobal`, per-env `env.initialise.runPerEnvironment`) → controls initialise stage generation.
  - `configuration.pipelineCommonRef` → forces dispatcher to reference a specific branch/tag of this repo.

## Script Inventory (highlights)
- `scripts/terraform_run.ps1` – wraps `terraform init/plan/apply` with workspace selection and tfvars support.
- `scripts/initialise_terraform.ps1` – downloads a pinned Terraform version suitable for Hosted agents (uses platform sniffing + unzip).
- `scripts/bicep_run.ps1` – drives validate/what-if/deploy for RG, subscription, management group, or tenant scopes; supports mode overrides.
- `scripts/initialise_bicep.ps1` – installs/updates Azure CLI Bicep tooling.
- `scripts/ps_analyse.ps1` – executes PSScriptAnalyzer for PowerShell actions.
- `scripts/branch_check.ps1` – enforces runtime branch allow-list per environment.
- `scripts/validate_variable_includes.ps1`, `scripts/validate_token_targets.ps1`, `scripts/validate_environment_model.ps1`, `scripts/validate_pools.ps1` – static validation helpers invoked during the Validation stage.

## Working With Examples
- Sample consumer pipelines, settings, and assets live in the dedicated repo `wesley-trust/pipeline-examples` under `examples/consumer`.
  - Each `.pipeline.yml` exposes runtime toggles (`enableProduction`, `runReviewStage`, `drInvocation`, per-env skip booleans) and defines `actionGroups` inline.
  - Each `.settings.yml` consumes those params, wires up the dispatcher resource, and passes `configuration`.
- The example assets (`examples/assets/…`) referenced throughout `docs/CONFIGURE.md` are hosted in that repo; update both repos in lockstep when introducing new parameters or breaking changes.

## Dispatcher Notes
- Production dispatcher repo (`wesley-trust/pipeline-dispatcher`) is not checked in here. Keep template and dispatcher updates coordinated so consumers remain compatible.

## Testing & Validation Guidance
- No automated unit tests live in this repo; validation occurs via pipeline runs. When editing templates/scripts:
  - Run `pwsh` linting locally where feasible (`pwsh -File scripts/ps_analyse.ps1` etc.).
  - For YAML templates, rely on Azure DevOps pipeline validation (`az pipelines validate` or Draft runs) – document expected compile-time behaviour if you cannot execute it.
  - Ensure documentation (this file and `docs/CONFIGURE.md`) reflects behavioural changes.
- Ensure Replace Tokens extension (`qetza.replacetokens`) and Azure Key Vault task are available in target organisations; templates assume v5 of Replace Tokens.

## Operational Gotchas
- All scripts assume PowerShell Core; do not introduce Bash. Hosted Linux agents are the default fallback (`ubuntu-latest`).
- Keep `actionGroups[*].name` unique per environment/region to avoid duplicate deployment job names.
- When enabling `poolRegionDemand`, agents must advertise `region == <regionName>` or jobs will hang waiting for capabilities.
- DR mode (`drInvocation: true`) suppresses secondary region stages and swaps dependencies to the DR region. Ensure `drRegion` and `dependsOnDRRegion` are set per environment before enabling.
- Production environments stay disabled unless the runtime parameter `enableProduction` is true **and** the `prod` environment is defined with class `production`.
- Token replacement defaults target technology-specific patterns – override `tokenTargetPatterns` if your file layout differs to avoid no-op replacements.

## Quick Actions for New Agents
1. Read `README.md` for high-level context, then skim `docs/CONFIGURE.md` for behavioural specifics.
2. Clone or reference `wesley-trust/pipeline-examples` to reproduce consumer setups; copy the settings structure when introducing new features.
3. Document any template/script changes in this file and, when appropriate, `docs/CONFIGURE.md`.
4. Coordinate dispatcher updates alongside template changes to keep consumers pinned to compatible versions.

## Local Validation Guide

### Why
Maintaining the pipeline templates without immediate access to Azure DevOps validation proved risky. The local test harness allows you to exercise the most failure-prone parts before raising PRs or queueing a pipeline. The suite catches syntax problems, missing template/script references, and PowerShell lint issues up front.

### Prerequisites
- PowerShell 7.x (`pwsh` is bundled in this repo's dev container).
- Git (used to fetch `wesley-trust/pipeline-dispatcher` into `.cache/pipeline-dispatcher`).
- Internet access on first run so the harness can install the `Pester` (>= 5.0.0) and `powershell-yaml` modules, and to hydrate the dispatcher/pipeline repositories.
- The `wesley-trust/pipeline-examples` repository checked out next to this repo (`../pipeline-examples`). The consumer YAML there is used as live compile targets.
- Populate `config/azdo-preview.config.psd1` with non-sensitive defaults (organisation URL, project name, branch refs, pipeline IDs). Secrets such as PATs stay out of source control.
- Provide an Azure DevOps PAT via `AZURE_DEVOPS_EXT_PAT`, `AZDO_PERSONAL_ACCESS_TOKEN`, or `scripts/set_azdo_pat.ps1` so preview requests can authenticate; the test harness now fails fast when the preview prerequisites are missing.

### Running the Tests
```powershell
pwsh -File scripts/invoke_local_tests.ps1
```
What the runner does:
- Loads `tests/Templates.Tests.ps1`, which drives `Pester`.
- Parses every template in `templates/` to confirm the YAML is well-formed.
- Verifies every static `template:` include resolves to a file inside this repo.
- Verifies every static `script:` reference resolves to a file under `scripts/`.
- Parses every consumer example in `../pipeline-examples/examples/consumer` to ensure the dispatcher contracts remain valid.
- Clones or refreshes `wesley-trust/pipeline-dispatcher` into `.cache/pipeline-dispatcher` and asserts the dispatcher template extends `templates/main.yml@PipelineCommon`.
- Executes `scripts/ps_analyse.ps1` so PSScriptAnalyzer runs across the `scripts/` directory (warnings are reported but only errors fail the suite).
- Triggers Azure DevOps previews and fails the run if the Azure DevOps settings or PAT are missing.

The command exits non-zero on any failure, which is what we should rely on before marking work complete.

### Azure DevOps Preview (Optional)
The test suite enforces Azure DevOps preview checks and fails when the following prerequisites are absent. Make sure an Azure DevOps PAT and the key environment variables are provided before running the harness:

- `AZDO_ORG_SERVICE_URL` – your organisation URL (e.g. `https://dev.azure.com/<org>`)
- `AZDO_PROJECT` – the target project
- `AZURE_DEVOPS_EXT_PAT` **or** `AZDO_PERSONAL_ACCESS_TOKEN` – a PAT with at least `Read & execute` permissions for Pipelines
- (Definition preview only) `AZDO_PIPELINE_IDS` – comma-separated pipeline IDs (e.g. `132`)

When these are present, `tests/Templates.Tests.ps1` runs two checks:

1. `scripts/preview_examples.ps1`
   - Calls the hidden `_apis/pipelines/{id}/runs?api-version=7.1-preview.1` endpoint with `previewRun = true`, injecting repository overrides for `wesley-trust/pipeline-common` and `wesley-trust/pipeline-dispatcher`.
   - Sends the pipeline YAML as `yamlOverride` so Azure DevOps validates the exact template content in this workspace.
   - Fails the run if Azure DevOps returns validation or compilation errors.

2. `scripts/preview_pipeline_definitions.ps1`
   - Uses the same `_apis/pipelines/{id}/runs?api-version=7.1-preview.1` endpoint with `previewRun = true` for each configured pipeline ID (e.g. definition 132).
   - Overrides the repository refs so Azure DevOps compiles the pipeline using the current branch of `pipeline-common`/`pipeline-dispatcher` before you queue a real run.
   - Surfaces validation issues returned from the service as test failures.

You can trigger the previews manually as well:

```bash
export AZURE_DEVOPS_EXT_PAT=<pat>
export AZDO_ORG_SERVICE_URL=https://dev.azure.com/<organisation>
export AZDO_PROJECT=<project>
export AZDO_PIPELINE_IDS=132
pwsh -File scripts/preview_examples.ps1
pwsh -File scripts/preview_pipeline_definitions.ps1
```

Use the `-PipelineCommonRef`, `-PipelineDispatcherRef`, or `-ExamplesBranch` switches to align the preview with a feature branch.

To avoid exporting the same non-sensitive values repeatedly, store them in `config/azdo-preview.config.psd1` (already seeded with the wesleytrust defaults). The harness loads that file automatically; you only need to supply a PAT via `AZURE_DEVOPS_EXT_PAT` or `AZDO_PERSONAL_ACCESS_TOKEN`.

### Azure DevOps CI Pipeline
- `azure-pipelines.yml` runs the same validation suite on `ubuntu-latest`, publishes the NUnit results, and expects a secret variable `AzureDevOpsPat` in the pipeline.
- `validation.pipeline.yml` / `validation.settings.yml` provide an alternative pipeline definition that extends the shared templates via the dispatcher. Add a secret variable named `AZURE_DEVOPS_EXT_PAT` (or run `scripts/set_azdo_pat.ps1` locally) and queue the pipeline to execute the validation stage through the shared action model.

### Adding New Tests
When a regression slips through, add a targeted assertion to `tests/Templates.Tests.ps1` (or create a new file under `tests/`). Keep the checks fast (< 30 seconds) so they can run before every PR.

### Habit Checklist
- Run `pwsh -File scripts/invoke_local_tests.ps1` before pushing.
- If the suite fails, fix the template/script first; do not ignore warnings without converting them into explicit excludes.
- Update this document whenever the validation flow changes so the team stays aligned.
