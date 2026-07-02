# Repository Guidelines

## Project Structure & Module Organization
Core source files live in `src/`, split by numeric prefixes such as `000-common.ps1`, `020-skcommon.ps1`, and `991-sign.ps1` so merge order is explicit. `Merge-ModuleScripts.ps1` concatenates those files into the generated module under `AnimeAttendance/`. Root entry scripts are `sign.ps1` for manual runs and `sign_schedule.ps1` for Windows Task Scheduler setup. Treat `.tmp/` as scratch/debug output, not source. For new provider work, start with .agents/add-platform.md.

## Build, Test, and Development Commands
Use PowerShell from the repo root.

```powershell
./Merge-ModuleScripts.ps1
```
Rebuilds `AnimeAttendance/AnimeAttendance.psm1`, copies non-`.ps1` resources, and runs syntax checks on each source file and the merged module.

```powershell
./sign.ps1
```
Rebuilds, imports the generated module, and runs `Invoke-AnimeAttendance` with `sign.json`.

```powershell
./sign_schedule.ps1
```
Rebuilds, imports the module, and registers the scheduled task.

## Coding Style & Naming Conventions
Follow the existing PowerShell style: tabs for indentation, PascalCase function names, and descriptive script names with numeric ordering prefixes in `src/`. Keep shared helpers in lower-numbered files and user-facing entrypoints near the end of the sequence. Preserve the `##MOD_EXEC## Export-ModuleMember ...` markers because the merge script relies on them to build exports, and keep the existing `$Profiie` parameter spelling where handlers already use it. `biome.json` enables tab-based formatting; do not reformat the repo to spaces.

## Testing Guidelines
There is no separate Pester suite in this checkout. The required validation path is `./Merge-ModuleScripts.ps1`; contributors should treat a clean `Syntax OK` pass as the minimum gate before committing. After merge validation, run `./sign.ps1` against a local `sign.json` when changing runtime behavior for a provider or scheduler flow. Prefer real API-driven checks over HTML-only guesses when verifying dynamic pages or task completion.

## Commit & Pull Request Guidelines
Recent history uses short conventional prefixes such as `feat:`, `fix:`, `refactor:`, `docs:`, and `ci:`. Keep commits focused and scoped to one behavioral change. Pull requests should state which platform flow changed (`hoyolab`, `skport`, `skland`, Discord, or scheduling), list the commands run for validation, and include sample console output or screenshots only when they clarify a user-visible behavior change.

## Security & Configuration Tips
Do not commit real credentials from `sign.json`; keep examples in `sign.example.json`. If you add provider-specific config, document it in both `README.md` and `README_ZH.md` so the English and Chinese setup guides stay aligned. For Discord reuse flows, keep embeds identifiable with stable `footer.text`, `description`, and field keys so multiple profiles do not overwrite each other in reused webhook messages.
