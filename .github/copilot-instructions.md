# Copilot Instructions for AI Agents

## Project Purpose & Architecture
- **`pipeline-common`** provides reusable Azure DevOps pipeline templates (YAML) for standardizing validation and deployment across consumer repos. All automation is PowerShell Core (no bash/inline scripts).
- **Primary entry point:** `templates/main.yml` (all consumer pipelines must extend this via the dispatcher repo).
- **Major components:**
  - `templates/`: Modular YAML templates for stages, jobs, steps, and variable includes.
  - `scripts/`: PowerShell Core scripts for all automation (e.g., `terraform_run.ps1`, `bicep_run.ps1`, `ps_analyse.ps1`).
  - **Dispatcher integration:** The `wesley-trust/pipeline-dispatcher` repo wires up the main template and passes a single `configuration` object.
- **Design principles:**
  - Lock sources early (initialise stage publishes a snapshot)
  - Run validation before review/deploy
  - Reuse scripts/tasks for all supported technologies (Terraform, Bicep, PowerShell)

## Key Workflows
- **Local validation:**
  - Run `pwsh -File scripts/invoke_local_tests.ps1` (requires changes to be committed and pushed). This lints PowerShell, checks YAML, and validates template/script references.
  - Azure DevOps validation: push to a feature/bugfix branch, then run pipeline previews or full runs.
- **No automated unit tests:** Validation is via pipeline runs and the local harness. See `AGENTS.md` for full workflow.
- **Branching:** Always work on a feature/bugfix branch. Do not run validation on unpushed work.

## Project-Specific Conventions
- **No Bash:** All scripts must be PowerShell Core. Do not introduce bash or inline scripts.
- **Extensibility:** Add new scripts to `scripts/` and reference them in templates. All jobs/steps are modular and reusable.
- **Token replacement:** Defaults are technology-specific; override with `tokenTargetPatterns` if needed.
- **Unique actionGroup names:** Ensure `actionGroups[*].name` is unique per environment/region.
- **DR mode:** Use `drInvocation` to deploy only to DR region (see `AGENTS.md`).
- **Variable includes:** Controlled by flags in `templates/variables/include.yml` (common, region, env, env-region).

## Integration & External Dependencies
- **Dispatcher:** All consumer pipelines are wired through the dispatcher (`pipeline-dispatcher`).
- **Key Vault:** Use `configuration.keyVault` to import secrets before jobs.
- **Additional repos:** Add to `configuration.additionalRepositories` for automatic checkout.
- **Consumer onboarding:** Reference patterns in `wesley-trust/pipeline-examples` (see `examples/consumer/`).

## References & Further Reading
- `README.md` and `AGENTS.md`: High-level and deep-dive documentation
- `docs/CONFIGURE.md`: Parameter flow, action model, environment design
- Example consumer pipelines: `wesley-trust/pipeline-examples/examples/consumer/`

---

**If unsure about a workflow or convention, check `AGENTS.md` and `docs/CONFIGURE.md` first, or review the dispatcher and examples repos.**
