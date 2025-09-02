# Consumer Guide: Using pipeline-common

This guide explains how to consume the shared Azure DevOps pipeline templates in `pipeline-common` with a safe, modular, and upgrade-friendly setup. It covers defaults, overrides, the unified task model, environments, validation, regional rollouts, approvals, and examples (including a Pester-only pipeline).

## Overview

- You keep two consumer-side files per example:
  - `<example>.pipeline.yml` (top-level): declares standard triggers, individual parameters (e.g., enableProduction, runReviewStage, per-environment skip booleans), and an `actionGroups` object in the unified main-group/child model.
  - `<example>.settings.yml`: composes a single `configuration` object from the pipeline parameters, actionGroups, and defaults. It extends the shared dispatcher and passes only `configuration` through.
  - The shared dispatcher lives at `examples/dispatcher/dispatcher.yml` and references the `PipelineCommon` resource alias to extend `templates/main.yml`.
- All scripts run PowerShell 7 (pwsh) from a central `pipeline-common/scripts/` folder via reusable task templates. Inline scripts are not allowed.
- The setup stage locks sources by publishing a snapshot artifact; every later stage downloads and uses the same snapshot.

## Defaults vs. Overrides

- Sensible defaults exist in `pipeline-common`. Consumers override by setting fields under `configuration` in `*.settings.yml`.
 - Commonly overridden:
  - `configuration.environments`: name, class, regions, allowed branches, pool, serviceConnection
  - `configuration.actionGroups`: action group selections
  - `configuration.defaultPool` and per-env `env.pool`
  - `configuration.variableGroups`
  - `configuration.runReviewStage`, `configuration.enableProduction`
  - `configuration.bicepModeOverride` (forces Bicep mode at runtime)

## Environment Model

- Environments have a `class`: `development`, `test`, `acceptance`, `production`.
- Multiple `development` and `test` allowed; at most one `acceptance` and one `production` (not mandatory).
- Each env can define:
  - `primaryRegion: '<code>'` (singular)
  - `secondaryRegions: [ ... ]` (zero or more)
  - `allowedBranches: [ 'main', 'release/*', '*' ]`
  - `pool`: agent pool selection
  - `serviceConnection`: Azure service connection override
  - `skipEnvironment: true|false` (skip this environment)
  - `dependsOn: 'previousEnvName'`
  - `dependsOnPrimaryRegion: 'weu'` (optional; helps gate next env on the prior env primary)

## Parameter Flow (single configuration object)

```
<example>.pipeline.yml (parameters + actionGroups) →
<example>.settings.yml (compose `configuration`) →
examples/dispatcher/dispatcher.yml (pass `configuration`) →
templates/main.yml@PipelineCommon (consume `configuration`)
```

## Unified Action Model (deploy)

- One actionGroup = one deployment job per environment-region.
- Actions (optional) run sequentially within that job.
- Multiple actionGroups at the same level run as separate jobs (parallel when permitted).
- Each actionGroup has the same structure (default displayName = upper(replace(name, '_', ' ')) unless overridden):

```
- name: terraform_apply            # required, unique per env/region
  displayName: Terraform Apply     # optional; defaults to name with `_` → ` `
  enabled: true                    # optional; default true
  environments: ['dev','prod']     # optional scoping; default all
  type: terraform|bicep|powershell

  # Common optional:
  preDeploy: { scripts: [ { script, arguments } ] }
  postDeploy: { scripts: [ { script, arguments } ] }
  tokenReplaceEnabled: true|false
  tokenTargetPatterns: ['path/**/pattern']

  # Terraform specifics:
  workingDirectory: infra/terraform
  varFilesString: path/to/single/params.tfvars

  # Bicep specifics:
  scope: resourceGroup|subscription|managementGroup|tenant
  resourceGroupName: rg-name
  location: westeurope
  templatePath: infra/bicep/main.bicep
  parametersFile: infra/bicep/params.bicepparam
  additionalParameters: ''
  managementGroupId: ''
  subscriptionId: ''
  mode: incremental|complete        # can be overridden globally by configuration.bicepModeOverride

  # PowerShell specifics:
  scriptPath: scripts/custom.ps1
  arguments: '-Env $(Environment)'

  # Optional actions (same shape as an actionGroup entry, but no further nesting):
  actions:
    - name: part1
      type: bicep
      ... (fields same as above) ...
```

## Validation (auto-discovered)

- Validation stage is modular and composes only required jobs:
  - Settings: validates pool config and environment model.
  - Branch Allow-List: checks `allowedBranches` per environment.
  - Variable Includes: preflight compile-time variable includes for `variableRoot`.
  - Token Targets: preflight that token replacement patterns resolve to at least one file.
  - Bicep: lint analysis for discovered actions of type `bicep`.
  - Terraform: `fmt`/`validate` for discovered actions of type `terraform`.
  - PowerShell: PSScriptAnalyzer for discovered actions of type `powershell`.
  - Custom validation scripts: consumer-provided, run against the locked source snapshot.

- Flags (in settings: `configuration.validation`), defaults true unless stated:
  - `enableBranchAllowlist`
  - `enableVariableIncludes`
  - `enableTokenTargets`
  - (tech-specific jobs are auto-included if corresponding actions exist)

## Review Stage Control

- A single switch controls the entire Review stage, which runs technology-specific checks (e.g., Bicep What‑If, Terraform Plan):
  - `configuration.runReviewStage: true|false` (default true)
- Optional per‑technology toggles (default true when omitted):
  - `configuration.runTerraformPlan`
  - `configuration.runBicepWhatIf`
- When `runReviewStage` is false, the Review stage is skipped and the pipeline proceeds directly to deployments.

## Token Replacement

- Centralized via `templates/steps/replace-tokens.yml` (requires Qetza Replace Tokens extension).
- Multiple targets supported per task via `tokenTargetPatterns` array.
- Defaults if not specified:
  - Terraform: `**/*.tfvars` under a task’s working directory.
  - Bicep: `**/*.bicepparam`.
- Applied in review (plan/what-if) and deployment phases; can be overridden per task; disable with `tokenReplaceEnabled: false`.

## Additional Repository Checkouts

- In settings under `configuration.additionalRepositories`, declare repositories to be available during Validation/Review/Deploy (e.g., Bicep modules):

  ```yaml
  configuration:
    additionalRepositories:
      - alias: Modules
        name: org/project.modules
        ref: refs/heads/main
  ```

- The dispatcher adds them under `resources.repositories`, and templates `checkout` them automatically before steps.

## Key Vault Secret Import

- In settings, configure Key Vault secret import to expose secrets as masked variables in jobs:

  ```yaml
  configuration:
    keyVault:
      name: kv-example
      secretsFilter: 'app-*'  # comma-separated or glob
  ```

- Requires a service connection with permissions to read secrets. Import runs (no-op if not configured):
  - Validation jobs
  - Review jobs
  - Deployment jobs

## PowerShell Action Enhancements

- Add to any `action` of `type: powershell`:
  - `delayMinutes: <number>` — inserts a non-blocking Delay task before execution.
  - `runInValidation: true|false` — also runs this action in the Validation stage.
  - `runInReview: true|false` — also runs this action in the Review stage.
- Token replacement for PowerShell actions is supported in Validation and Review via `tokenReplaceEnabled`, `tokenTargetPatterns`, `tokenPrefix`, `tokenSuffix`.

## DR Invocation Mode

- To deploy to the DR region as the effective primary when the usual primary is unavailable:
  - Pipeline parameter: `drInvocation: true|false` (examples include this and pass it to settings).
  - In settings per environment:
    - `drRegion: '<region>'` — effective primary when DR is invoked.
    - `dependsOnDRRegion: '<region>'` — next environment’s gate when DR is invoked.
- Behavior:
  - Only DR region stages are generated; secondary region stages are suppressed.
  - Next environment gates on the prior environment’s DR stage.
  - Toggle `drInvocation: false` to return to normal (secondaries then primary; gate on primary).

## Region-Based Agent Demands

- Per environment, set `poolRegionDemand: true` to require agents with capability `region == <currentRegion>` for deployment jobs.
- This applies to region-scoped deployment jobs. Ensure your agents advertise a `region` capability.

## Production Safety & Branch Controls

- Production runs only when `configuration.enableProduction: true` (runtime parameter gate).
- Each environment job enforces branch allow-list (wildcards) via `scripts/branch_check.ps1`.
- acceptance should succeed before production; set `prod.dependsOn: preprod` and optionally `prod.dependsOnPrimaryRegion: '<preprod-primary>'` to ensure gating.

## Regional Rollouts & Approvals

- Per environment, regional stages execute secondaries first, primary last (singular `primaryRegion`). All regions (secondary + primary) always deploy.
- The next environment depends only on the previous environment’s primary region stage. Specify `env.dependsOn` and optionally `env.dependsOnPrimaryRegion` to make the dependency explicit.
- Each regional task runs as a deployment job bound to the environment (`environment: <env>`), so Azure DevOps Environment approvals/checks apply.

## Setup (Global vs Per-Environment)

- Controls (in settings → configuration):
  - `setup.runGlobal: bool` — runs a single Setup stage before Validation/Review/Deploy.
  - `setup.runPerEnvironment: bool` — runs a Setup stage for each environment.
  - Per environment override: `env.setupRequired: bool` — force run when true, force skip when false.
- Defaults: If both are false or omitted, no Setup stages are created.
- Ordering & dependencies:
  - Global Setup (if enabled) runs first and gates Validation.
  - Per-Environment Setup (if enabled or `setupRequired` true) runs before that environment’s Review/Deploy and uses the environment’s pool.
  - Validation has no dependency on Setup when no Global Setup is enabled.

- Outcomes (truth table):
  - runGlobal=false, env.setup.runPerEnvironment=false → no Setup for that env.
  - runGlobal=true, env.setup.runPerEnvironment=false → Global gates all; no per‑env stage.
  - runGlobal=false, env.setup.runPerEnvironment=true → Per‑env stage gates that env only.
  - runGlobal=true, env.setup.runPerEnvironment=true → Global first, then per‑env stage gates that env.

## Pools (Hosted vs Self‑Hosted)

- For `configuration.defaultPool` and each `environment.pool`, you may set either:
  - `name: '<self-hosted-pool-name>'` (self‑hosted), or
  - `vmImage: '<hosted-image>'` (e.g., `ubuntu-latest`, `windows-latest`).
- Precedence and resolution:
  - If `pool.name` is set, the job uses `pool: { name: <name> }`.
  - Else if `pool.vmImage` is set, the job uses `pool: { vmImage: <vmImage> }`.
  - Else it falls back to `defaultPool` with the same rules.
- Conflict guard: do not set both `name` and `vmImage` on the same pool. Validation fails fast if both are provided.

## Variables & Loading Order (compile-time)

- Variables are included at compile time using templates so values are available during compilation. Deterministic order:
  1. `vars/common.yml`
  2. `vars/region/<region>.yml` (region-only, across all environments)
  3. `vars/env/<env>.yml`
  4. `vars/<env>/region/<region>.yml`
- Missing files can be safely omitted via include flags; no need for blank files.
  - Global defaults (in settings under `configuration.variables`):
    - `includeCommon: true|false` (default true)
    - `includeRegionOnly: true|false` (default true)
    - `includeEnv: true|false` (default true)
    - `includeEnvRegion: true|false` (default true)
  - Per‑environment overrides (optional):
    - `environment.variables.includeCommon|includeRegionOnly|includeEnv|includeEnvRegion`
  - These flags control whether the corresponding template is included at compile‑time and avoid file‑not‑found errors when a layer is not used.

## Defaults Location

- Define defaults in the settings files when composing the `configuration` object. Pipelines provide per‑run values only (individual parameters and actionGroups).

## Run Conditions

- Two ways to control when a task runs:
  - Simple flags: `runConditions.manualOnly|scheduleOnly|prOnly`
  - Explicit `condition` expression (Azure DevOps runtime condition)

## Terraform Params (single file)

- Use a single tfvars file for all environments (e.g., `examples/assets/terraform/vars.tfvars`) and drive differences via Replace Tokens.

## PipelineCommon Ref Override

- In settings `configuration`, set `pipelineCommonRef` to override the default `refs/heads/main` for the `PipelineCommon` resource in the dispatcher.

## Examples

- Shared dispatcher: `examples/dispatcher/dispatcher.yml` (all examples extend and pass one `configuration`).
- Consumer pipelines:
  - `examples/consumer/bicep.pipeline.yml`
  - `examples/consumer/terraform.pipeline.yml`
  - `examples/consumer/pester.pipeline.yml`
  - `examples/consumer/powershell.pipeline.yml`
  - `examples/consumer/bicep-plus-tests.pipeline.yml`
- Variables folder layout under consumer examples:
  - `examples/consumer/vars/common.yml`
  - `examples/consumer/vars/env/<env>.yml`
  - `examples/consumer/vars/<env>/region/<region>.yml`
  - If you don’t use env or env/region files, set the include flags in settings instead of creating empty files.
- Secure files: use `templates/steps/download-secure-file.yml` and pass `$(downloadSecureFile.secureFilePath)` to scripts.
- Artifact publish/download: see `templates/steps/publish-artifact.yml` and `templates/steps/download-artifact.yml`.

## Pester via PowerShell Action

- See `examples/consumer/pester.pipeline.yml` for a Pester-only pipeline using PowerShell actions.
  - Four test types: unit, integration, regression, smoke (functional).
  - Triggers: `trigger` for unit (CI), `pr` for integration; regression/smoke on-demand.
  - Each selected test type becomes a separate action executed via PowerShell (concurrent across actionGroups).
  - The legacy `templates/jobs/run-pester.yml` is archived under `archive/`.

## Notes

- Display name derivation uses `upper(replace(name, '_', ' '))`. You can explicitly set `displayName` to override.
- For strict gating of “next env waits on previous env’s primary region”, add `dependsOn` and `dependsOnPrimaryRegion` to environments for clarity.
- Replace Tokens requires the Qetza extension to be installed.
