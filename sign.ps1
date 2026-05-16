$ErrorActionPreference = 'Stop'

$mergeScriptPath = Join-Path $PSScriptRoot 'Merge-ModuleScripts.ps1'
& $mergeScriptPath

$moduleManifestPath = Join-Path $PSScriptRoot 'AnimeAttendance\AnimeAttendance.psd1'
Import-Module $moduleManifestPath -Force

Invoke-AnimeAttendance -ConfigPath (Join-Path $PSScriptRoot 'sign.json')
