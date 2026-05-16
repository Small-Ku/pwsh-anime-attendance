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
	if ($null -ne $conf -and (($conf.display.console -eq 'false') -or (-not $conf.display.console))) { return }

	Write-Host "[$Level] $Message" -ForegroundColor $color
}