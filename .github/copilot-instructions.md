# Copilot Instructions for AI Agents

## Project Overview
- This repo (`pipeline-common`) provides **reusable Azure DevOps pipeline templates** (YAML) for standardising validation and deployment across consumer repos. All execution is PowerShell-first (no inline bash) and is extended via the dispatcher (`wesley-trust/pipeline-dispatcher`).
- The **primary entry point** is `templates/main.yml`. All consumer pipelines must extend this template through the dispatcher to ensure compliance and consistency.
- **Key design:** lock sources early (initialise stage publishes a snapshot), run validation before review/deploy, and reuse scripts/tasks for all supported technologies (Terraform, Bicep, PowerShell).

## Architecture & Structure
- **Templates:**
  - `templates/main.yml`: entry point, wires initialise, validation, review, and deploy stages.
  - `templates/stages/`, `templates/jobs/`, `templates/steps/`: modular composition for each stage/job/step.
  - `templates/variables/include.yml`: controls variable file includes (common, region, env, env-region) via flags.
- **Scripts:** All scripts are PowerShell Core and live in `scripts/`. No inline scripts or bash allowed. Examples: `terraform_run.ps1`, `bicep_run.ps1`, `ps_analyse.ps1`, `branch_check.ps1`.
- **Validation:**
  - Built-in: environment model, Bicep lint, Terraform fmt/validate, PSScriptAnalyzer.
  - Custom validation: add scripts to `scripts/` and invoke via templates.
- **Consumer onboarding:** Reference patterns in `wesley-trust/pipeline-examples` for new consumer repos.

## Developer Workflows
- **Local validation:**
  - Run `pwsh -File scripts/invoke_local_tests.ps1` to lint PowerShell, check YAML syntax, and validate template/script references. Requires changes to be committed and pushed.
  - Azure DevOps validation: push changes to a feature/bugfix branch, then run pipeline previews or full runs.
- **Testing:** No automated unit tests; rely on pipeline runs and local harness. See `AGENTS.md` for full local validation workflow.
- **Branching:** Always work on a feature/bugfix branch. Do not run validation on unpushed work.

## Project Conventions
- **No Bash:** All automation is PowerShell Core. Do not introduce bash or inline scripts.
- **Extensibility:** All jobs and steps are modular and reusable. Add new scripts to `scripts/` and reference them in templates.
- **Token replacement:** Defaults are technology-specific; override with `tokenTargetPatterns` if needed.
- **Unique actionGroup names:** Ensure `actionGroups[*].name` is unique per environment/region.
- **DR mode:** Use `drInvocation` to deploy only to DR region; see `AGENTS.md` for details.

## Integration Points
- **Dispatcher:** `pipeline-dispatcher` repo wires up the main template and passes the configuration object.
- **Key Vault:** Configure `configuration.keyVault` to import secrets before jobs.
- **Additional repos:** Add to `configuration.additionalRepositories` for automatic checkout.

## References
- See `README.md` and `AGENTS.md` for high-level and deep-dive documentation.
- See `docs/CONFIGURE.md` for parameter flow, action model, and environment design.
- Example consumer pipelines: `wesley-trust/pipeline-examples/examples/consumer/`.

---

**If you are unsure about a workflow or convention, check `AGENTS.md` and `docs/CONFIGURE.md` first, or review the dispatcher and examples repos.**
