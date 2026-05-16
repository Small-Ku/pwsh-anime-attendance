function Register-AnimeAttendanceSchedule {
	<#
	.SYNOPSIS
		Register AnimeAttendance scheduled tasks (daily + startup).
	#>
	param(
		[string]$TaskName = 'AnimeAttendance',
		[string]$ScriptPath = (Join-Path $PSScriptRoot '..\sign.ps1')
	)

	$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
	if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
		Write-Error "This script requires administrator privileges to register a scheduled task. Please run PowerShell as an administrator."
		return
	}

	$resolvedScriptPath = [System.IO.Path]::GetFullPath($ScriptPath)
	$workingDirectory = Split-Path -Path $resolvedScriptPath -Parent
	$moduleManifestPath = Join-Path $workingDirectory 'AnimeAttendance\AnimeAttendance.psd1'
	$configPath = Join-Path $workingDirectory 'sign.json'

	$powerShellExe = if (Get-Command 'pwsh.exe' -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }
	$command = "Import-Module '$moduleManifestPath' -Force; Invoke-AnimeAttendance -ConfigPath '$configPath'"

	$actions = New-ScheduledTaskAction `
		-Execute $powerShellExe `
		-Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command ""$command""" `
		-WorkingDirectory $workingDirectory

	$utc16 = [DateTime]::UtcNow.Date.AddHours(16) # 00:00 UTC+8
	$localTime = $utc16.ToLocalTime()
	$atTime = $localTime.ToString('HH:mm')

	$triggers = @(
		(New-ScheduledTaskTrigger -Daily -At $atTime),
		(New-ScheduledTaskTrigger -AtStartup)
	)

	$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -RunLevel Limited

	$settings = New-ScheduledTaskSettingsSet `
		-RunOnlyIfNetworkAvailable `
		-WakeToRun `
		-AllowStartIfOnBatteries `
		-DontStopIfGoingOnBatteries

	$task = New-ScheduledTask -Action $actions -Trigger $triggers -Principal $principal -Settings $settings
	Register-ScheduledTask $TaskName -InputObject $task -Force
}
##MOD_EXEC## Export-ModuleMember -Function Register-AnimeAttendanceSchedule
