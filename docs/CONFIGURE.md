# Consumer Guide: Using pipeline-common

This guide explains how to consume the shared Azure DevOps pipeline templates in `pipeline-common` with a safe, modular, and upgrade-friendly setup. It covers defaults, overrides, the unified task model, environments, validation, regional rollouts, approvals, and examples (including a Pester-only pipeline).

## Overview

- Reference implementations live in `wesley-trust/pipeline-examples` under `examples/consumer`.
- You keep two consumer-side files per example:
  - `<example>.pipeline.yml` (top-level): declares standard triggers, individual parameters (e.g., enableProduction, runReviewStage, per-environment skip booleans), and an `actionGroups` object in the unified main-group/child model.
  - `<example>.settings.yml`: composes a single `configuration` object from the pipeline parameters, actionGroups, and defaults. It extends the shared dispatcher and passes only `configuration` through.
  - The shared dispatcher lives in the dispatcher repo (`wesley-trust/pipeline-dispatcher/templates/pipeline-dispatcher.yml`) and references the `PipelineCommon` resource alias to extend `templates/main.yml`.
- All scripts run PowerShell 7 (pwsh) from a central `pipeline-common/scripts/` folder via reusable task templates. Inline scripts are not allowed.
- The initialise stage locks sources by publishing a snapshot artifact; every later stage downloads and uses the same snapshot.

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
- Multiple `development` and `test` allowed; at most one `acceptance` and one `production`. When `enableProduction` is true, an `acceptance` (pre-production) environment must exist and cannot be skipped.
- Each env can define:
  - `primaryRegion: '<code>'` (singular)
  - `secondaryRegions: [ ... ]` (zero or more)
  - `allowedBranches: [ 'main', 'release/*', '*' ]`
  - `pool`: agent pool selection
  - `serviceConnection`: Azure service connection override
  - `skipEnvironment: true|false` (skip this environment; ignored for `acceptance` when `enableProduction` is true)
  - `dependsOn: 'previousEnvName'`
  - `dependsOnRegion: 'weu'` (optional; helps gate next env on the prior env primary)

## Parameter Flow (single configuration object)

```
<example>.pipeline.yml (parameters + actionGroups) →
<example>.settings.yml (compose `configuration`) →
pipeline-dispatcher/templates/pipeline-dispatcher.yml (pass `configuration`) →
templates/main.yml@PipelineCommon (consume `configuration`)
```

## Unified Action Model (deploy)

- One actionGroup = one deployment job per environment-region.
- Actions (optional) run sequentially within that job.
- Multiple actionGroups at the same level run as separate jobs (parallel when permitted) and can be chained with `dependsOn` for ordered execution.
- Each actionGroup has the same structure (default displayName = upper(replace(name, '_', ' ')) unless overridden):

```
- name: terraform_apply            # required, unique per env/region
  displayName: Terraform Apply     # optional; defaults to name with `_` → ` `
  enabled: true                    # optional; default true
  environments: ['dev','prod']     # optional scoping; default all
  dependsOn: ['bicep_deploy']      # optional; waits for listed actionGroup names in the same env/region
  type: terraform|bicep|powershell

  # Common optional:
  preDeploy: { scripts: [ { script, arguments } ] }
  postDeploy: { scripts: [ { script, arguments } ] }
  tokenReplaceEnabled: true|false
  tokenTargetPatterns: ['path/**/pattern']
  tokenPrefix: '#{{'
  tokenSuffix: '}}'

  # Terraform specifics:
  workingDirectory: infra/terraform
  varFilesString: path/to/single/params.tfvars

  # Bicep specifics:
  scope: resourceGroup|subscription|managementGroup|tenant
  resourceGroupName: rg-name
  location: westeurope
  templatePath: infra/bicep/main.bicep
  parametersFile: infra/bicep/params.bicepparam
  additionalParameters: ''         # optional extra arguments passed to az stack (e.g. "--parameters foo=bar")
  managementGroupId: ''
  subscriptionId: ''
  mode: incremental|complete        # can be overridden globally by configuration.bicepModeOverride
  allowDeleteOnUnmanage: true|false # default false; temporarily sets action-on-unmanage to deleteAll
  cleanupStack: true|false          # resource group and subscription scopes; deletes the deployment stack instead of running a deployment

  # PowerShell specifics:
  scriptPath: scripts/custom.ps1
  arguments: '-Env $(Environment)'
  scriptTask: pwsh|azureCli|azurePowerShell   # optional; defaults to pwsh
  workingDirectory: tests/powershell          # optional; relative to locked snapshot (defaults to repo root)

  # Optional actions (same shape as an actionGroup entry, but no further nesting and they inherit the parent type):
  actions:
    - name: part1
      ... (fields same as above) ...
```

> Actions never declare their own `type`; set it on the containing actionGroup and it applies to every action in that group. Use `dependsOn` when you need sequential execution across actionGroups for a given environment/region — the dispatcher resolves the names you list into the underlying job dependencies, so keep `actionGroups[*].name` unique within each environment/region.

> When `allowDeleteOnUnmanage` is true the deployment switches the Bicep stack’s `action-on-unmanage` setting to `deleteAll` for that run and restores it to `detachAll` once the deployment finishes, matching the default safe posture. The toggle applies to resource group, subscription, and management group scopes; Azure CLI currently does not expose deployment stacks at tenant scope, so `allowDeleteOnUnmanage` is rejected there. Stack names follow the convention automatically: `ds-<resourceGroup>` for resource group deployments, `ds-sub-<resourceGroup>` for subscription deployments, and `ds-mg-<managementGroupId>` for management group deployments. Enable `cleanupStack` when the stack needs to be retired — the script skips the deployment and calls the matching `az stack <scope> delete`, using `allowDeleteOnUnmanage` to decide whether deletion detaches (default) or removes the managed resources (`deleteAll`).

> Review-stage Bicep what-if jobs respect `cleanupStack`: when the flag is true they emit explanatory text and export the current stack inventory with the planned action (Delete/Detach) instead of running `az deployment … what-if`, so reviewers see the exact teardown that will execute.

## Validation (auto-discovered)

- Validation stage is modular and composes only required jobs:
  - Settings: validates pool config and environment model.
  - Branch Allow-List: checks `allowedBranches` per environment.
  - Variable Includes: preflight compile-time variable includes for `variableRoot`.
  - Token Targets: preflight that token replacement patterns resolve to at least one file.
  - Bicep: lint analysis for action groups declared as type `bicep`.
  - Terraform: `fmt`/`validate` for action groups declared as type `terraform`.
  - PowerShell: PSScriptAnalyzer for action groups declared as type `powershell`.
  - Custom validation scripts: consumer-provided, run against the locked source snapshot.

- Flags (in settings: `configuration.validation`), defaults true unless stated:
  - `enableBranchAllowlist`
  - `enableVariableIncludes`
  - `enableTokenTargets`
  - (tech-specific jobs are auto-included when matching actionGroups exist)

## Review Stage Control

- A single switch controls the entire Review stage, which runs technology-specific checks (e.g., Bicep What‑If, Terraform Plan):
  - `configuration.runReviewStage: true|false` (default true)
- Individual action groups control whether their review job is emitted:
  - Terraform groups: `runTerraformPlan: true|false` (default true when omitted)
  - Bicep groups: `runBicepWhatIf: true|false` (default true when omitted)
  - PowerShell groups: `runPowerShellReview: true|false` (default false when omitted)
- When `runReviewStage` is false, the Review stage is skipped for non-production environments. Production deployments always run the Review stage.

## Token Replacement

- Centralised via `templates/steps/replace-tokens.yml` (requires Qetza Replace Tokens extension).
- Multiple targets supported per task via `tokenTargetPatterns` array.
- Configure at either the `actionGroup` or individual `action` level. Actions inherit prefix/suffix defaults from their parent.
- Defaults when enabled and `tokenTargetPatterns` are omitted:
  - `actionGroup.tokenReplaceEnabled: true` → Terraform action groups evaluate `**/*.tfvars` in each declared `workingDirectory`; Bicep action groups evaluate `**/*.bicepparam` once per group.
  - `action.tokenReplaceEnabled: true` → Terraform actions continue to target `**/*.tfvars` under their `workingDirectory`; Bicep actions target only their declared `parametersFile` to avoid double-processing shared parameter assets.
- Override defaults with `tokenTargetPatterns` on the relevant scope; omit the property to fall back to the behaviour above. `tokenPrefix`/`tokenSuffix` honour the same inheritance (action → actionGroup → default `#{{` / `}}`).
- Applied in review (plan/what-if) and deployment phases; disable with `tokenReplaceEnabled: false` on either scope. PowerShell validation/review runs accept the same flags.

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

- Add to any `action` of `type: powershell` (group-level `scriptTask`/`serviceConnection` values act as defaults):
  - `scriptTask: pwsh|azureCli|azurePowerShell` — selects the underlying task. `pwsh` stays on `PowerShell@2`; `azureCli` swaps to `AzureCLI@2` with `addSpnToEnvironment` so Az CLI and Az PowerShell share the injected service principal; `azurePowerShell` runs via `AzurePowerShell@5` for organisations that prefer the Az module.
  - `serviceConnection: '<service connection name or variable>'` — overrides the environment-level connection when a task needs a different subscription/tenant. Required for `scriptTask: azureCli`/`azurePowerShell` so the task can authenticate.
  - `azurePowerShellVersion: '<version>'` — optional when `scriptTask: azurePowerShell`; defaults to `LatestVersion`.
  - `delayMinutes: <number>` — inserts a non-blocking Delay task before execution.
  - `runInValidation: true|false` — also runs this action in the Validation stage.
- PowerShell review jobs are enabled per action group via `runPowerShellReview: true|false` (defaults to false). When enabled you must supply a review script per action using either `reviewScriptPath` (relative to the locked snapshot) or `reviewScriptFullPath`; actions without a review script are skipped. You can still override behaviour with `reviewScriptTask`, `reviewServiceConnection`, `reviewAzurePowerShellVersion`, `reviewArguments` (defaults to `arguments`), `reviewDisplayName` (defaults to the action display name), `reviewCondition`, `reviewWorkingDirectory` (relative to the locked snapshot), or `reviewWorkingDirectoryFullPath`.
- Token replacement for PowerShell actions is supported in Validation and Review via `tokenReplaceEnabled`, `tokenTargetPatterns`, `tokenPrefix`, `tokenSuffix`.
- To reuse the deployment logic, explicitly set `reviewScriptPath` to the same script the deploy action uses. `reviewArguments` defaults to the deployment arguments when omitted.

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
- acceptance should succeed before production; set `prod.dependsOn: preprod` and optionally `prod.dependsOnRegion: '<preprod-primary>'` to ensure gating.

## Regional Rollouts & Approvals

- Per environment, regional stages execute secondaries first, primary last (singular `primaryRegion`). All regions (secondary + primary) always deploy.
- The next environment depends only on the previous environment’s primary region stage. Specify `env.dependsOn` and optionally `env.dependsOnRegion` to make the dependency explicit.
- Each regional task runs as a deployment job bound to the environment (`environment: <env>`), so Azure DevOps Environment approvals/checks apply.

## Initialise (Global vs Per-Environment)

- Controls (in settings → configuration):
  - `initialise.runGlobal: bool` — runs a single Initialise stage before Validation/Review/Deploy.
  - `initialise.runPerEnvironment: bool` — runs a Initialise stage for each environment.
  - Per environment override: `env.initialiseRequired: bool` — force run when true, force skip when false.
- Defaults: If both are false or omitted, no Initialise stages are created.
- Ordering & dependencies:
  - Global Initialise (if enabled) runs first and gates Validation.
  - Per-Environment Initialise (if enabled or `initialiseRequired` true) runs before that environment’s Review/Deploy and uses the environment’s pool.
  - Validation has no dependency on Initialise when no Global Initialise is enabled.

- Outcomes (truth table):
  - runGlobal=false, env.initialise.runPerEnvironment=false → no Initialise for that env.
  - runGlobal=true, env.initialise.runPerEnvironment=false → Global gates all; no per‑env stage.
  - runGlobal=false, env.initialise.runPerEnvironment=true → Per‑env stage gates that env only.
  - runGlobal=true, env.initialise.runPerEnvironment=true → Global first, then per‑env stage gates that env.

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

- Use a single tfvars file for all environments (e.g., `wesley-trust/pipeline-examples/examples/assets/terraform/vars.tfvars`) and drive differences via Replace Tokens.

## PipelineCommon Ref Override

- In settings `configuration`, set `pipelineCommonRef` to override the default `refs/heads/main` for the `PipelineCommon` resource in the dispatcher.

## Examples

- Shared dispatcher: `wesley-trust/pipeline-dispatcher/templates/pipeline-dispatcher.yml` (all examples extend and pass one `configuration`).
- Consumer pipelines:
  - `wesley-trust/pipeline-examples/examples/consumer/bicep.pipeline.yml`
  - `wesley-trust/pipeline-examples/examples/consumer/terraform.pipeline.yml`
  - `wesley-trust/pipeline-examples/examples/consumer/pester.pipeline.yml`
  - `wesley-trust/pipeline-examples/examples/consumer/powershell.pipeline.yml`
  - `wesley-trust/pipeline-examples/examples/consumer/bicep-plus-tests.pipeline.yml`
- Variables folder layout under consumer examples:
  - `wesley-trust/pipeline-examples/examples/consumer/vars/common.yml`
  - `wesley-trust/pipeline-examples/examples/consumer/vars/env/<env>.yml`
  - `wesley-trust/pipeline-examples/examples/consumer/vars/<env>/region/<region>.yml`
  - If you don’t use env or env/region files, set the include flags in settings instead of creating empty files.
- Secure files: use `templates/steps/download-secure-file.yml` and pass `$(downloadSecureFile.secureFilePath)` to scripts.
- Artifact publish/download: see `templates/steps/publish-artifact.yml` and `templates/steps/download-artifact.yml`.

## Pester via PowerShell Action

- See `wesley-trust/pipeline-examples/examples/consumer/pester.pipeline.yml` for a Pester-only pipeline using PowerShell actions.
  - Four test types: unit, integration, regression, smoke (functional).
  - Triggers: `trigger` for unit (CI), `pr` for integration; regression/smoke on-demand.
  - Each selected test type becomes a separate action executed via PowerShell (concurrent across actionGroups).


## Notes

- Display name derivation uses `upper(replace(name, '_', ' '))`. You can explicitly set `displayName` to override.
- For strict gating of “next env waits on previous env’s primary region”, add `dependsOn` and `dependsOnRegion` to environments for clarity.
- Replace Tokens requires the Qetza extension to be installed.
