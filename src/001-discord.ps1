####################
# Discord
####################

function Get-DiscordPing {
	param($PingConfig)
	if (-not $PingConfig) { return "" }

	$ping = ""
	if ($PingConfig.user) {
		$ping += "<@" + ($PingConfig.user -join "> <@") + ">"
	}
	if ($PingConfig.user -and $PingConfig.role) {
		$ping += " "
	}
	if ($PingConfig.role) {
		$ping += "<@&" + ($PingConfig.role -join "> <@&") + ">"
	}
	return $ping
}

function Initialize-DiscordEmbed {
	return @{
		'color'       = '16711680' # Default to Red (Error)
		'title'       = "ERROR"
		'description' = "Unknown error. Maybe invalid cookie."
		'fields'      = @()
	}
}

function Send-DiscordNotification {
	param(
		$BotConfig,
		$Embeds,
		$NeedPing,
		$PingString,
		$GlobalConfig
	)

	if (-not $BotConfig.webhook_url) { return }

	$reuse_id = $BotConfig.reuse_msg
	$existing_message = $null
	
	# Fetch existing message if reusing
	if ($reuse_id -and $reuse_id -match '^\d{18,}$') {
		try {
			$uri = "$($BotConfig.webhook_url)/messages/$reuse_id"
			$existing_message = Invoke-RestMethod -Method 'Get' -Uri $uri -ContentType 'application/json;charset=UTF-8'
			Out-Log -Level 'DEBUG' -Message "Fetched existing message with $($existing_message.embeds.Length) embeds"
		}
		catch {
			Out-Log -Level 'WARN' -Message "Failed to fetch existing message for reuse: $_"
			$existing_message = $null
		}
	}

	# Embed Management Strategy: List-based with Footer ID matching
	$AllEmbeds = @()

	# 1. Load Existing Embeds
	if ($existing_message -and $existing_message.embeds -and -not $BotConfig.overwrite) {
		foreach ($ex_embed in $existing_message.embeds) {
			# Create a field map for fast lookups/updates
			$field_map = [ordered]@{}
			if ($ex_embed.fields) {
				$idx = 0
				foreach ($f in $ex_embed.fields) {
					$idx += 1
					$key = if ($f.key) { [string]$f.key } else { "$($f.name)#$idx" }
					$field_map[$key] = $f
				}
			}

			$AllEmbeds += @{
				'title'       = $ex_embed.title
				'color'       = $ex_embed.color
				'description' = $ex_embed.description
				'footer'      = if ($ex_embed.footer) { @{ 'text' = $ex_embed.footer.text } } else { $null }
				'field_map'   = $field_map
				'_matched'    = $false
			}
		}
	}

	# 2. Merge New Embeds
	foreach ($new_e in $Embeds) {
		$target_embed = $null

		# Search for existing match
		# Priority 1: Footer ID
		if ($new_e.footer -and $new_e.footer.text) {
			foreach ($ex in $AllEmbeds) {
				if ($ex.footer -and $ex.footer.text -eq $new_e.footer.text) {
					$target_embed = $ex
					break
				}
			}
		}

		# Priority 2: Description
		if ($new_e.description) {
			foreach ($ex in $AllEmbeds) {
				if ($ex.description -eq $new_e.description) {
					$target_embed = $ex
					break
				}
			}
		}

		# Priority 3: Title (Fallback for legacy or first run)
		if ($null -eq $target_embed) {
			foreach ($ex in $AllEmbeds) {
				if (-not $ex['_matched'] -and $ex.title -eq $new_e.title) {
					$target_embed = $ex
					break
				}
			}
		}

		if ($null -ne $target_embed) {
			# Update existing
			$target_embed['title'] = $new_e.title
			$target_embed['color'] = $new_e.color
			$target_embed['description'] = $new_e.description
			$target_embed['footer'] = $new_e.footer
			$target_embed['_matched'] = $true
		}
		else {
			# Create new
			$target_embed = @{
				'title'       = $new_e.title
				'color'       = $new_e.color
				'description' = $new_e.description
				'footer'      = $new_e.footer
				'field_map'   = [ordered]@{}
				'_matched'    = $true
			}
			$AllEmbeds += $target_embed
		}

		# Process Fields
		$target_field_map = $target_embed['field_map']
		foreach ($new_f in $new_e.fields) {
			# Determine value based on minimal flag
			$val = if ($BotConfig.minimal -and $new_f.minimal) { $new_f.minimal } else { $new_f.value }
			$fieldKey = if ($new_f.key) { [string]$new_f.key } else { [string]$new_f.name }
			
			$clean_field = @{
				'name'   = $new_f.name
				'value'  = $val
				'inline' = $new_f.inline
			}

			# When existing embeds came from Discord payload, custom `key` is absent.
			# Fallback-match by (name + first value line) to keep updates stable.
			if (-not $target_field_map.Contains($fieldKey) -and $new_f.key) {
				$newFirstLine = ""
				if ($val) {
					$newFirstLine = ([string]$val -split "`r?`n")[0]
				}
				foreach ($existingKey in @($target_field_map.Keys)) {
					$existingField = $target_field_map[$existingKey]
					if ($existingField.name -ne $new_f.name) { continue }
					$existingFirstLine = ""
					if ($existingField.value) {
						$existingFirstLine = ([string]$existingField.value -split "`r?`n")[0]
					}
					if ($existingFirstLine -eq $newFirstLine) {
						$fieldKey = $existingKey
						break
					}
				}
			}

			# Update/Add
			$target_field_map[$fieldKey] = $clean_field
		}
	}

	# 3. Flatten back to Array
	$processed_embeds = @()
	foreach ($embed_entry in $AllEmbeds) {
		$fields_array = @($embed_entry['field_map'].Values)
		
		$final_embed = @{
			'title'       = $embed_entry['title']
			'color'       = $embed_entry['color']
			'description' = $embed_entry['description']
			'fields'      = $fields_array
		}
		if ($embed_entry['footer']) { $final_embed['footer'] = $embed_entry['footer'] }
		
		$processed_embeds += $final_embed
	}

	$discord_body = @{
		'content' = ''
		'embeds'  = $processed_embeds
	}
	if ($BotConfig.discord_name) { $discord_body.username = $BotConfig.discord_name }
	if ($BotConfig.avatar_url) { $discord_body.avatar_url = $BotConfig.avatar_url }

	$discord_body_json = $discord_body | ConvertTo-Json -Depth 10

	Out-Log -Level 'DEBUG' -Message "Discord message body for bot $($BotConfig.discord_name):`n$discord_body_json"

	if ($reuse_id -and $reuse_id -match '^\d{18,}$') {
		$uri = "$($BotConfig.webhook_url)/messages/$reuse_id"
		$ret = Invoke-RestMethod -Method 'Patch' -Uri $uri -Body $discord_body_json -ContentType 'application/json;charset=UTF-8'
	}
	else {
		$uri = $BotConfig.webhook_url + '?wait=true'
		$ret = Invoke-RestMethod -Method 'Post' -Uri $uri -Body $discord_body_json -ContentType 'application/json;charset=UTF-8'
		if ($BotConfig.reuse_msg -eq 'true' -or $BotConfig.reuse_msg -eq $true) {
			$BotConfig.reuse_msg = $ret.id
			$GlobalConfig | ConvertTo-Json -Depth 10 | Set-Content .\sign.json -Encoding 'UTF8'
		}
	}

	if ($NeedPing) {
		$ping_body = @{ 'content' = $PingString } | ConvertTo-Json
		Invoke-RestMethod -Method 'Post' -Uri $BotConfig.webhook_url -Body $ping_body -ContentType 'application/json;charset=UTF-8'
	}
}
