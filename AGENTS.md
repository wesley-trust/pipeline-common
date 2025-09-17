# Agent Handbook

## Mission Overview
- **Repository scope:** Shared Azure DevOps pipeline templates (`pipeline-common`) consumed via the dispatcher repo (`wesley-trust/pipeline-dispatcher`). Everything here is PowerShell-first (no inline bash) and is designed to be extended through the dispatcher.
- **Primary entry point:** `templates/main.yml` – all consumer pipelines must extend this template through the dispatcher to stay compliant with the consistency rules noted in `README.md`.
- **Key philosophy:** lock sources early (setup stage publishes a snapshot), run validation before review/deploy, and reuse scripts/tasks across all technologies (Terraform, Bicep, PowerShell).
- **License:** MIT (`LICENSE`).

## Directory Map (current as of repo snapshot)
- `README.md` – high-level purpose and highlights.
- `docs/CONFIGURE.md` – deep-dive consumer guide (parameter flow, action model, environment design, review controls, DR mode, token replacement, etc.). Treat this as the canonical reference for behaviour.
- `templates/` – main templates split by grain:
  - `main.yml` – enforced entry point; wires setup, validation, review, deploy stages.
  - `stages/` – stage-level composition (`validation-stage.yml`, `review-stage.yml`, `environment-region-deploy-stage.yml`, `initialise-stage.yml`).
  - `jobs/` – job-level templates organised by concern (`validation/`, `review/`, `initialise/`). Jobs consume scripts exclusively.
  - `steps/` – single-step building blocks (AzureCLI, PowerShell, artifact publish/download, Replace Tokens, Key Vault import, secure file download).
  - `variables/include.yml` – compile-time include matrix controlling `common`, `region`, `env`, and `env-region` variable files via flags.
- `scripts/` – PowerShell implementations called by templates (Terraform/Bicep runners, setup installers, branch/variable/token validators, etc.). All scripts assume pwsh and are meant to run inside the locked snapshot path when invoked from pipelines.
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
- **`configuration.actionGroups`** describes the unified action model. Each group can target specific environments and nest sequential `actions`. Supported `type` values: `terraform`, `bicep`, `powershell`. Actions inherit the group type and must not declare their own. Token replacement defaults per tech can be overridden via `tokenTargetPatterns`, `tokenPrefix`, `tokenSuffix`.
- **`configuration.validation`** toggles validation jobs (`enableBranchAllowlist`, `enableVariableIncludes`, `enableTokenTargets`). Tech-specific validator jobs light up automatically when matching action group types are present.
- **Variables** load compile-time via `templates/variables/include.yml`. Global defaults live under `configuration.variables`, per-environment overrides under `env.variables`. Flags (`includeCommon`, `includeRegionOnly`, `includeEnv`, `includeEnvRegion`) prevent missing-file failures when layers are unused.
- **Additional integrations:**
  - `configuration.additionalRepositories` → adds repo resources to dispatcher and checks them out automatically in jobs.
  - `configuration.keyVault` (`name`, `secretsFilter`) → pulls secrets via `AzureKeyVault@2` before steps.
  - `configuration.setup` (`runGlobal`, per-env `env.setup.runPerEnvironment`) → controls setup stage generation.
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
