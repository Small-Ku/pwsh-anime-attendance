$ErrorActionPreference = 'Stop'

$mergeScriptPath = Join-Path $PSScriptRoot 'Merge-ModuleScripts.ps1'
& $mergeScriptPath

$moduleManifestPath = Join-Path $PSScriptRoot 'AnimeAttendance\AnimeAttendance.psd1'
Import-Module $moduleManifestPath -Force

Register-AnimeAttendanceSchedule
