# Import the active Skport cred from a locally downloaded browser HAR.
# The archive and credential never leave this machine and are never printed.
[CmdletBinding()]
param(
	[Parameter(Mandatory = $true)][string]$HarArchivePath,
	[Parameter(Mandatory = $true)][string]$ConfigPath
)
$ErrorActionPreference = 'Stop'

$archive = (Resolve-Path -LiteralPath $HarArchivePath -ErrorAction Stop).Path
$configFile = (Resolve-Path -LiteralPath $ConfigPath -ErrorAction Stop).Path
$tempDir = $null

try {
	if ($archive.EndsWith('.har', [System.StringComparison]::OrdinalIgnoreCase)) {
		$harFile = $archive
	}
	elseif ($archive.EndsWith('.tar.zst', [System.StringComparison]::OrdinalIgnoreCase)) {
		$zstd = Get-Command 'zstd' -ErrorAction Stop
		$null = Get-Command 'tar' -ErrorAction Stop
		$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ('skport-har-' + [guid]::NewGuid().ToString('N'))
		New-Item -Path $tempDir -ItemType Directory | Out-Null
		$tarFile = Join-Path $tempDir 'archive.tar'
		& $zstd.Source -d -f -q -o $tarFile -- $archive | Out-Null
		if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $tarFile)) {
			throw 'Unable to decompress the HAR archive.'
		}
		if ((Get-Item -LiteralPath $tarFile).Length -gt 268435456) {
			throw 'HAR archive exceeds the supported extraction limit.'
		}
		$entries = @(& tar -tf $tarFile)
		if ($LASTEXITCODE -ne 0 -or $entries.Count -ne 1 -or $entries[0] -notmatch '^[^/\\]+\.har$') {
			throw 'Expected one regular .har file at the archive root.'
		}
		& tar -xf $tarFile -C $tempDir -- $entries[0]
		if ($LASTEXITCODE -ne 0) { throw 'Failed to unpack the HAR.' }
		$harFile = Join-Path $tempDir $entries[0]
	}
	else {
		throw 'Expected a .har or .har.tar.zst file.'
	}
	if ((Get-Item -LiteralPath $harFile).Length -gt 268435456) {
		throw 'HAR exceeds the supported size limit.'
	}
	$fileInfo = Get-Item -LiteralPath $harFile -ErrorAction Stop
	if ($fileInfo.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
		throw 'HAR must be a regular file.'
	}
	$har = Get-Content -LiteralPath $harFile -Raw -Encoding UTF8 | ConvertFrom-Json
	$credentials = @()
	foreach ($entry in @($har.log.entries)) {
		try {
			$uri = [uri]$entry.request.url
			if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'zonai.skport.com' -or
				$uri.AbsolutePath -ne '/web/v1/game/endfield/attendance' -or
				$entry.response.status -ne 200) { continue }
			$response = $entry.response.content.text | ConvertFrom-Json
			$confirmed = $response.code -eq 0 -and (
				$entry.request.method -eq 'POST' -or
				($entry.request.method -eq 'GET' -and $response.data.hasToday -eq $true)
			)
			if (-not $confirmed) { continue }
			$credHeaders = @($entry.request.headers | Where-Object { $_.name -ieq 'cred' })
			if ($credHeaders.Count -ne 1) { continue }
			$cred = [string]$credHeaders[0].value
			if ($cred -cmatch '^[A-Za-z0-9]{32}$') { $credentials += $cred }
		}
		catch { continue }
	}
	$credentials = @($credentials | Select-Object -Unique)
	if ($credentials.Count -ne 1) {
		throw 'Cannot identify one credential from a confirmed Endfield attendance response.'
	}
	$freshCred = [string]$credentials[0]
	$rawConfig = Get-Content -LiteralPath $configFile -Raw -Encoding UTF8
	$config = $rawConfig | ConvertFrom-Json
	$profiles = @($config.profiles | Where-Object { $_.platform -eq 'skport' })
	if ($profiles.Count -ne 1) { throw 'Expected exactly one configured Skport profile.' }
	$profile = $profiles[0]
	$oldCred = [string]$profile.cred
	if ($oldCred -eq $freshCred) {
		Write-Output 'Skport credential is already up to date.'
		return
	}
	$profile.cred = $freshCred

	# Validate new credentials with read-only API calls before writing config.
	$modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'AnimeAttendance\AnimeAttendance.psd1'
	$module = Import-Module $modulePath -PassThru -Force -ErrorAction Stop
	$probe = & $module {
		param($Profile, $Config)
		$script:conf = $Config
		$script:conf.display.console.enabled = $false
		Register-LogSecretsFromConfig -Config $Config
		$provider = Get-SkProviderProfile -Provider 'skport'
		$ctx = @{
			Profile = $Profile; ProviderProfile = $provider
			PlatformConfig = $Config.platforms.skport
			GameConfig = $Config.platforms.skport.games[0]
			Cred = $Profile.cred; Token = $null; TimeOffset = 0
			DId = ''; SkGameRole = $null
		}
		if (-not (Initialize-SkAuthState -Ctx $ctx)) { return $false }
		$user = Get-SkUserData -Ctx $ctx
		$binding = Get-SkBindingData -Ctx $ctx
		if ($user.Kind -ne 'Success' -or $binding.Kind -ne 'Success') { return $false }
		return @(Expand-SkRoles -BindingData $binding.Data -Provider 'skport').Count -gt 0
	} $profile $config
	if (-not $probe) {
		throw 'Skport rejected this HAR credential or returned no roles; config was not changed.'
	}

	$oldQuoted = ConvertTo-Json -InputObject $oldCred -Compress
	$newQuoted = ConvertTo-Json -InputObject $freshCred -Compress
	$pattern = '("cred"\s*:\s*)' + [regex]::Escape($oldQuoted)
	if ([regex]::Matches($rawConfig, $pattern).Count -ne 1) {
		throw 'Cannot safely locate the original Skport cred in config.'
	}
	$replacement = [regex]::Replace(
		$rawConfig, $pattern,
		[System.Text.RegularExpressions.MatchEvaluator] {
			param($Match)
			return $Match.Groups[1].Value + $newQuoted
		}
	)
	$checked = $replacement | ConvertFrom-Json
	if (@($checked.profiles).Count -ne @($config.profiles).Count -or
		@($checked.profiles | Where-Object { $_.platform -eq 'skport' })[0].cred -ne $freshCred) {
		throw 'Resulting config failed validation.'
	}
	$tempConfig = Join-Path (Split-Path -Parent $configFile) ('.skport-cred-' + [guid]::NewGuid().ToString('N') + '.tmp')
	try {
		[System.IO.File]::WriteAllText($tempConfig, $replacement, [System.Text.UTF8Encoding]::new($false))
		Move-Item -LiteralPath $tempConfig -Destination $configFile -Force -ErrorAction Stop
	}
	finally {
		if (Test-Path -LiteralPath $tempConfig) { Remove-Item -LiteralPath $tempConfig -Force }
	}
	Write-Output 'Skport credential updated after successful read-only authentication and binding checks.'
}
finally {
	if ($tempDir -and (Test-Path -LiteralPath $tempDir)) {
		Remove-Item -LiteralPath $tempDir -Force -Recurse -ErrorAction SilentlyContinue
	}
}