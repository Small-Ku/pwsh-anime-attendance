####################
# Attendance outcomes
####################

# PowerShell 5.1 has no discriminated union type. These constructors form the
# validated internal contract; provider wire objects must not escape as outcomes.
function New-AttendanceItemResult {
	param(
		[Parameter(Mandatory = $true)]
		[ValidateSet('Signed', 'AlreadySigned', 'Failed')]
		[string]$Kind,
		[Parameter(Mandatory = $true)]
		[string]$Identity,
		[string]$Detail = '',
		[string]$Reason = ''
	)

	if ([string]::IsNullOrWhiteSpace($Identity)) {
		throw 'An attendance item requires a non-empty identity.'
	}
	if ($Kind -eq 'Failed') {
		if ([string]::IsNullOrWhiteSpace($Reason)) {
			throw 'A failed attendance item must have a reason.'
		}
	}
	elseif (-not [string]::IsNullOrEmpty($Reason)) {
		throw 'A successful attendance item cannot have a failure reason.'
	}

	return [pscustomobject]@{
		PSTypeName = 'AnimeAttendance.ItemResult'
		Kind = $Kind
		Identity = $Identity
		Detail = $Detail
		Reason = $Reason
	}
}

function New-AttendanceProfileFailure {
	param(
		[Parameter(Mandatory = $true)]
		[string]$Platform,
		[Parameter(Mandatory = $true)]
		[string]$Reason,
		[Parameter(Mandatory = $true)]
		[string]$Message
	)
	if ([string]::IsNullOrWhiteSpace($Reason) -or [string]::IsNullOrWhiteSpace($Message)) {
		throw 'A failed attendance profile must have a reason and message.'
	}
	return [pscustomobject]@{
		PSTypeName = 'AnimeAttendance.ProfileResult'
		Kind = 'Failure'
		Platform = $Platform
		Items = @()
		Reason = $Reason
		Message = $Message
	}
}

function Complete-AttendanceProfileResult {
	param(
		[Parameter(Mandatory = $true)]
		[string]$Platform,
		[object[]]$Items
	)

	$itemsArray = if ($null -eq $Items) { @() } else { @($Items) }
	if (@($itemsArray | Where-Object { $null -eq $_ }).Count -gt 0) {
		throw 'Null attendance items cannot be silently omitted.'
	}
	if ($itemsArray.Count -eq 0) {
		return New-AttendanceProfileFailure -Platform $Platform -Reason 'NoActionableItems' -Message 'No configured attendance items could be processed.'
	}

	$passed = 0
	$failed = 0
	foreach ($item in $itemsArray) {
		if (-not $item.PSTypeNames.Contains('AnimeAttendance.ItemResult')) {
			throw 'Only validated attendance items may be aggregated.'
		}
		switch ($item.Kind) {
			'Signed' { $passed++ }
			'AlreadySigned' { $passed++ }
			'Failed' { $failed++ }
			default { throw "Unknown attendance item outcome: $($item.Kind)" }
		}
	}

	$kind = if ($failed -eq 0) { 'Success' } elseif ($passed -eq 0) { 'Failure' } else { 'PartialFailure' }
	return [pscustomobject]@{
		PSTypeName = 'AnimeAttendance.ProfileResult'
		Kind = $kind
		Platform = $Platform
		Items = $itemsArray
		Reason = if ($kind -eq 'Failure') { 'AllItemsFailed' } else { '' }
		Message = ''
	}
}

function Test-AttendanceProfileResult {
	param($Result)
	if ($null -eq $Result -or -not $Result.PSTypeNames.Contains('AnimeAttendance.ProfileResult')) { return $false }
	if ($Result.Kind -notin @('Success', 'PartialFailure', 'Failure')) { return $false }
	if ([string]::IsNullOrWhiteSpace([string]$Result.Platform)) { return $false }
	$items = @($Result.Items)
	foreach ($item in $items) {
		if ($null -eq $item -or -not $item.PSTypeNames.Contains('AnimeAttendance.ItemResult')) { return $false }
		if ([string]::IsNullOrWhiteSpace([string]$item.Identity)) { return $false }
		if ($item.Kind -eq 'Failed') {
			if ([string]::IsNullOrWhiteSpace([string]$item.Reason)) { return $false }
		}
		elseif ($item.Kind -in @('Signed', 'AlreadySigned')) {
			if (-not [string]::IsNullOrEmpty([string]$item.Reason)) { return $false }
		}
		else { return $false }
	}
	if ($items.Count -eq 0) {
		return ($Result.Kind -eq 'Failure' -and -not [string]::IsNullOrWhiteSpace([string]$Result.Reason))
	}

	$passed = @($items | Where-Object { $_.PSTypeNames.Contains('AnimeAttendance.ItemResult') -and $_.Kind -in @('Signed', 'AlreadySigned') }).Count
	$failed = @($items | Where-Object { $_.PSTypeNames.Contains('AnimeAttendance.ItemResult') -and $_.Kind -eq 'Failed' }).Count
	if ($passed + $failed -ne $items.Count) { return $false }
	switch ($Result.Kind) {
		'Success' { $passed -gt 0 -and $failed -eq 0 }
		'PartialFailure' { $passed -gt 0 -and $failed -gt 0 }
		'Failure' { $passed -eq 0 -and $failed -gt 0 }
	}
}

function Test-AttendanceRequiresPing {
	param($Result)
	if (-not (Test-AttendanceProfileResult -Result $Result)) {
		throw 'Cannot derive notification policy from an invalid attendance result.'
	}
	return ($Result.Kind -ne 'Success')
}

function Complete-AttendanceEmbed {
	param($Result, $Embed)
	if (-not (Test-AttendanceProfileResult -Result $Result)) {
		throw 'Cannot render an invalid attendance result.'
	}
	if ($null -eq $Embed) { throw 'An attendance embed is required.' }

	$Embed.color = switch ($Result.Kind) {
		'Success' { '5635840' }
		'PartialFailure' { '16753920' }
		'Failure' { '16711680' }
	}

	if (-not $Embed.title -or $Embed.title -eq 'ERROR') {
		$Embed.title = "$($Result.Platform) attendance: $($Result.Kind)"
	}
	if ($Result.Kind -eq 'Failure' -and @($Embed.fields).Count -eq 0) {
		$msg = if ($Result.Message) { $Result.Message } else { $Result.Reason }
		$Embed.fields += @{ name = 'Error'; value = $msg; inline = $false }
	}
	return $Embed
}