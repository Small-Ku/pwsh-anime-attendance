####################
# Utilities
####################

function New-WebSession {
	# From https://stackoverflow.com/questions/69519695
	param(
		[hashtable]$Cookies,
		[Uri]$For
	)

	$newSession = [Microsoft.PowerShell.Commands.WebRequestSession]::new()

	foreach ($entry in $Cookies.GetEnumerator()) {
		$cookie = [System.Net.Cookie]::new($entry.Name, $entry.Value)
		if ($For) {
			$newSession.Cookies.Add([uri]::new($For, '/'), $cookie)
		}
		else {
			$newSession.Cookies.Add($cookie)
		}
	}

	return $newSession
}

function Format-Text {
	# Temporary hack for Windows PowerShell that not handle REST requests with UTF-8
	param(
		[String]$Text
	)

	if ($null -eq $Text) { return "" }

	if ($PSVersionTable.PSVersion.Major -le 5) {
		$bytes = [System.Text.Encoding]::GetEncoding('ISO-8859-1').GetBytes($Text)
		return [System.Text.Encoding]::UTF8.GetString($bytes)
	}

	return $Text
}


if ($null -eq $script:LogSecrets) { $script:LogSecrets = @() }
if ($null -eq $script:LogSecretLabels) { $script:LogSecretLabels = @{} }
if ($null -eq $script:GitHubMaskedLogSecrets) { $script:GitHubMaskedLogSecrets = @{} }

function Get-AnimeAttendanceProperty {
	param(
		$Object,
		[Parameter(Mandatory = $true)]
		[string]$Name
	)

	if ($null -eq $Object) { return $null }
	if ($Object -is [System.Collections.IDictionary]) {
		if ($Object.Contains($Name)) { return $Object[$Name] }
		return $null
	}
	$property = $Object.PSObject.Properties[$Name]
	if ($property) { return $property.Value }
	return $null
}

function Test-AnimeAttendanceProperty {
	param(
		$Object,
		[Parameter(Mandatory = $true)]
		[string]$Name
	)

	if ($null -eq $Object) { return $false }
	if ($Object -is [System.Collections.IDictionary]) { return $Object.Contains($Name) }
	return $null -ne $Object.PSObject.Properties[$Name]
}

function Set-AnimeAttendanceProperty {
	param(
		$Object,
		[Parameter(Mandatory = $true)]
		[string]$Name,
		$Value
	)

	if ($Object -is [System.Collections.IDictionary]) {
		$Object[$Name] = $Value
	}
	else {
		$Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value -Force
	}
}

function ConvertTo-AnimeAttendanceBoolean {
	param(
		$Value,
		[bool]$Default = $false
	)

	if ($null -eq $Value) { return $Default }
	if ($Value -is [bool]) { return [bool]$Value }
	switch (([string]$Value).Trim().ToLowerInvariant()) {
		'true' { return $true }
		'false' { return $false }
		'1' { return $true }
		'0' { return $false }
		default { return $Default }
	}
}

function Get-AnimeAttendanceConsoleSettings {
	param($Config)

	if ($null -eq $Config) { $Config = $script:conf }
	$display = Get-AnimeAttendanceProperty -Object $Config -Name 'display'
	$console = Get-AnimeAttendanceProperty -Object $display -Name 'console'
	$enabled = $true
	$redact = 'always'

	if ($console -is [bool]) {
		$enabled = [bool]$console
	}
	elseif ($console -is [string]) {
		switch ($console.Trim().ToLowerInvariant()) {
			'false' { $enabled = $false }
			'pause' { $enabled = $true }
			'true' { $enabled = $true }
			default { $enabled = $true }
		}
	}
	elseif ($null -ne $console) {
		if (Test-AnimeAttendanceProperty -Object $console -Name 'enabled') {
			$enabled = ConvertTo-AnimeAttendanceBoolean -Value (Get-AnimeAttendanceProperty -Object $console -Name 'enabled') -Default $true
		}
		if (Test-AnimeAttendanceProperty -Object $console -Name 'redact') {
			$redact = ([string](Get-AnimeAttendanceProperty -Object $console -Name 'redact')).Trim().ToLowerInvariant()
		}
	}
	$redact = 'always'
	return [pscustomobject]@{ Enabled = $enabled; Redact = $redact }
}

function Normalize-AnimeAttendanceConfig {
	param(
		[Parameter(Mandatory = $true)]
		$Config
	)

	$display = Get-AnimeAttendanceProperty -Object $Config -Name 'display'
	if ($null -eq $display) {
		$display = [pscustomobject]@{}
		Set-AnimeAttendanceProperty -Object $Config -Name 'display' -Value $display
	}

	$rawConsole = Get-AnimeAttendanceProperty -Object $display -Name 'console'
	$settings = Get-AnimeAttendanceConsoleSettings -Config $Config
	$pauseFromLegacyConsole = $rawConsole -is [string] -and $rawConsole.Trim().ToLowerInvariant() -eq 'pause'
	$normalizedConsole = [pscustomobject]@{ enabled = $settings.Enabled; redact = $settings.Redact }
	Set-AnimeAttendanceProperty -Object $display -Name 'console' -Value $normalizedConsole

	$runtime = Get-AnimeAttendanceProperty -Object $Config -Name 'runtime'
	if ($null -eq $runtime) {
		$runtime = [pscustomobject]@{}
		Set-AnimeAttendanceProperty -Object $Config -Name 'runtime' -Value $runtime
	}
	$pause = ConvertTo-AnimeAttendanceBoolean -Value (Get-AnimeAttendanceProperty -Object $runtime -Name 'pause') -Default $false
	if ($pauseFromLegacyConsole) { $pause = $true }
	Set-AnimeAttendanceProperty -Object $runtime -Name 'pause' -Value $pause

	return $Config
}

function Test-AnimeAttendanceCi {
	return (
		[string]::Equals([string]$env:GITHUB_ACTIONS, 'true', [System.StringComparison]::OrdinalIgnoreCase) -or
		[string]::Equals([string]$env:CI, 'true', [System.StringComparison]::OrdinalIgnoreCase)
	)
}

function Test-AnimeAttendanceGitHubActions {
	return [string]::Equals([string]$env:GITHUB_ACTIONS, 'true', [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-LogRedactionEnabled {
	# Console output must never reveal known credentials, even locally.
	return $true
}

function Register-LogSecret {
	param(
		$Secret,
		[string]$Label = 'secret'
	)

	if ($null -eq $Secret) { return }
	$secretText = [string]$Secret
	if ([string]::IsNullOrWhiteSpace($secretText)) { return }
	if (-not (@($script:LogSecrets) -contains $secretText)) {
		$script:LogSecrets += $secretText
	}
	if ($null -eq $script:LogSecretLabels) { $script:LogSecretLabels = @{} }
	if (-not $script:LogSecretLabels.ContainsKey($secretText)) {
		$script:LogSecretLabels[$secretText] = if ([string]::IsNullOrWhiteSpace($Label)) { 'secret' } else { $Label }
	}
}

function Register-LogSecretsFromConfig {
	param($Config)

	$script:LogSecrets = @()
	$script:LogSecretLabels = @{}
	$script:GitHubMaskedLogSecrets = @{}
	if ($null -eq $Config) { return }

	foreach ($profile in @((Get-AnimeAttendanceProperty -Object $Config -Name 'profiles'))) {
		foreach ($name in @('ltoken', 'ltoken_v2', 'ltmid_v2', 'ltuid', 'ltuid_v2', 'cred', 'token', 'cookies')) {
			Register-LogSecret -Secret (Get-AnimeAttendanceProperty -Object $profile -Name $name) -Label $name
		}
		$device = Get-AnimeAttendanceProperty -Object $profile -Name 'device'
		foreach ($name in @('id', 'did', 'device_id', 'seed', 'device_seed')) {
			$label = switch ($name) {
				'id' { 'device.id' }
				'did' { 'device.did' }
				'device_id' { 'device.id' }
				'seed' { 'device.seed' }
				'device_seed' { 'device.seed' }
			}
			Register-LogSecret -Secret (Get-AnimeAttendanceProperty -Object $device -Name $name) -Label $label
		}
	}

	$display = Get-AnimeAttendanceProperty -Object $Config -Name 'display'
	$discord = Get-AnimeAttendanceProperty -Object $display -Name 'discord'
	foreach ($bot in @((Get-AnimeAttendanceProperty -Object $discord -Name 'bots'))) {
		Register-LogSecret -Secret (Get-AnimeAttendanceProperty -Object $bot -Name 'webhook_url') -Label 'webhook_url'
	}
	Register-GitHubLogMasks
}

function Get-LogRedactionMarker {
	param([string]$Label = 'secret')

	if ([string]::IsNullOrWhiteSpace($Label)) { $Label = 'secret' }
	$safeLabel = $Label.Trim() -replace '[^A-Za-z0-9_.-]', '_'
	return "***REDACTED:$safeLabel***"
}

function Protect-GitHubCommandValue {
	param([string]$Value)

	if ($null -eq $Value) { return '' }
	return $Value.Replace('%', '%25').Replace("`r", '%0D').Replace("`n", '%0A')
}

function Register-GitHubLogMask {
	param([string]$Secret)

	if (-not (Test-AnimeAttendanceGitHubActions) -or -not (Test-LogRedactionEnabled)) { return }
	if ([string]::IsNullOrWhiteSpace($Secret)) { return }
	if ($null -eq $script:GitHubMaskedLogSecrets) { $script:GitHubMaskedLogSecrets = @{} }
	if ($script:GitHubMaskedLogSecrets.ContainsKey($Secret)) { return }
	$script:GitHubMaskedLogSecrets[$Secret] = $true
	$escaped = Protect-GitHubCommandValue -Value $Secret
	Write-Host "::add-mask::$escaped"
}

function Register-GitHubLogMasks {
	if (-not (Test-AnimeAttendanceGitHubActions) -or -not (Test-LogRedactionEnabled)) { return }
	foreach ($secret in @($script:LogSecrets)) {
		Register-GitHubLogMask -Secret ([string]$secret)
	}
}

function Protect-LogMessage {
	param([AllowEmptyString()][string]$Message)

	if (-not (Test-LogRedactionEnabled)) { return $Message }
	$protected = if ($null -eq $Message) { '' } else { [string]$Message }
	$secrets = @($script:LogSecrets | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object Length -Descending)
	foreach ($secret in $secrets) {
		$label = if ($script:LogSecretLabels.ContainsKey([string]$secret)) { $script:LogSecretLabels[[string]$secret] } else { 'secret' }
		$secretText = [string]$secret
		$marker = Get-LogRedactionMarker -Label $label
		if ($secretText.Length -lt 6) {
			# Short role IDs may otherwise corrupt status codes such as 1001.
			$pattern = '(?<![A-Za-z0-9-])' + [regex]::Escape($secretText) + '(?![A-Za-z0-9])'
			$protected = [regex]::Replace($protected, $pattern, $marker)
		}
		else {
			$protected = $protected.Replace($secretText, $marker)
		}
	}
	return $protected
}

function Get-LogSensitiveKeyLabel {
	param([string]$Name)

	$normalized = ([string]$Name).ToLowerInvariant() -replace '[^a-z0-9]', ''
	switch ($normalized) {
		'token' { return 'token' }
		'accesstoken' { return 'access_token' }
		'refreshtoken' { return 'refresh_token' }
		'authorization' { return 'authorization' }
		'cookie' { return 'cookie' }
		'cookies' { return 'cookies' }
		'setcookie' { return 'set-cookie' }
		'cred' { return 'cred' }
		'ltoken' { return 'ltoken' }
		'ltokenv2' { return 'ltoken_v2' }
		'ltmidv2' { return 'ltmid_v2' }
		'ltuid' { return 'ltuid' }
		'ltuidv2' { return 'ltuid_v2' }
		'webhookurl' { return 'webhook_url' }
		'did' { return 'dId' }
		'deviceid' { return 'device.id' }
		'deviceseed' { return 'device.seed' }
		'seed' { return 'seed' }
		'id' { return 'id' }
		'uid' { return 'uid' }
		'accountid' { return 'account_id' }
		'userid' { return 'user_id' }
		'playerid' { return 'player_id' }
		'roleid' { return 'role_id' }
		'serverid' { return 'server_id' }
		'gameid' { return 'game_id' }
		'channelmasterid' { return 'channelMasterId' }
		'identity' { return 'identity' }
		'password' { return 'password' }
		'passphrase' { return 'passphrase' }
		'apikey' { return 'api_key' }
		'clientsecret' { return 'client_secret' }
		'secret' { return 'secret' }
		default { return $null }
	}
}

function Test-LogSensitiveKey {
	param([string]$Name)

	return $null -ne (Get-LogSensitiveKeyLabel -Name $Name)
}

function ConvertTo-RedactedLogValue {
	param($Value)

	if ($null -eq $Value) { return $null }
	if ($Value -is [string]) { return (Protect-LogMessage -Message $Value) }
	if ($Value -is [char] -or $Value -is [System.ValueType]) { return $Value }

	if ($Value -is [System.Collections.IDictionary]) {
		$result = [ordered]@{}
		foreach ($key in $Value.Keys) {
			$name = [string]$key
			$label = Get-LogSensitiveKeyLabel -Name $name
			if ($label) {
				$result[$name] = Get-LogRedactionMarker -Label $label
			}
			else {
				$result[$name] = ConvertTo-RedactedLogValue -Value $Value[$key]
			}
		}
		return $result
	}

	if ($Value -is [System.Collections.IEnumerable]) {
		$items = @()
		foreach ($item in $Value) {
			$items += ,(ConvertTo-RedactedLogValue -Value $item)
		}
		return ,$items
	}

	$properties = @($Value.PSObject.Properties | Where-Object { $_.MemberType -in @('NoteProperty', 'Property', 'AliasProperty', 'ScriptProperty') })
	if ($properties.Count -gt 0) {
		$result = [ordered]@{}
		foreach ($property in $properties) {
			$label = Get-LogSensitiveKeyLabel -Name $property.Name
			if ($label) {
				$result[$property.Name] = Get-LogRedactionMarker -Label $label
			}
			else {
				$result[$property.Name] = ConvertTo-RedactedLogValue -Value $property.Value
			}
		}
		return $result
	}

	return $Value
}

function Format-LogObject {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
		$InputObject,
		[int]$Depth = 10
	)

	begin { $values = @() }
	process { $values += ,$InputObject }
	end {
		$value = if ($values.Count -eq 1) { $values[0] } else { $values }
		if (Test-LogRedactionEnabled) {
			$value = ConvertTo-RedactedLogValue -Value $value
		}
		return (($value | ConvertTo-Json -Depth $Depth) -join [Environment]::NewLine)
	}
}

function Out-Log {
	param(
		[Parameter(Mandatory = $true)]
		[ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')]
		[String]$Level,
		[Parameter(Mandatory = $true)]
		[String]$Message
	)

	$color = switch ($Level) {
		'INFO' { 'Cyan' }
		'WARN' { 'Yellow' }
		'ERROR' { 'Red' }
		'DEBUG' { 'Gray' }
	}

	if ($Level -eq 'DEBUG' -and -not $global:debugging) { return }
	$consoleSettings = Get-AnimeAttendanceConsoleSettings
	if (-not $consoleSettings.Enabled) { return }
	$Message = Protect-LogMessage -Message $Message

	Write-Host "[$Level] $Message" -ForegroundColor $color
}

function Save-AnimeAttendanceConfig {
	param(
		[Parameter(Mandatory = $true)]
		$Config,
		[Parameter(Mandatory = $true)]
		[string]$Path
	)

	$resolvedPath = [System.IO.Path]::GetFullPath($Path)
	$directory = [System.IO.Path]::GetDirectoryName($resolvedPath)
	$fileName = [System.IO.Path]::GetFileName($resolvedPath)
	$tempPath = Join-Path $directory ".${fileName}.$([guid]::NewGuid().ToString('N')).tmp"

	try {
		$json = $Config | ConvertTo-Json -Depth 20
		$json | Set-Content -LiteralPath $tempPath -Encoding 'UTF8'
		Move-Item -LiteralPath $tempPath -Destination $resolvedPath -Force
	}
	finally {
		if (Test-Path -LiteralPath $tempPath) {
			Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
		}
	}
}
