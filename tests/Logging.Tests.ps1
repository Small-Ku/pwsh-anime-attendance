BeforeAll {
	. "$PSScriptRoot/../src/000-common.ps1"
}

Describe 'Console logging policy' {
	BeforeEach {
		$script:previousGithubActions = $env:GITHUB_ACTIONS
		$script:previousCi = $env:CI
		$script:previousDebugging = $global:debugging
		Remove-Item Env:GITHUB_ACTIONS -ErrorAction SilentlyContinue
		Remove-Item Env:CI -ErrorAction SilentlyContinue
		$global:debugging = $true
		$script:LogSecrets = @()
		$script:LogSecretLabels = @{}
		$script:GitHubMaskedLogSecrets = @{}
		$script:LogIdentityAliases = @{}
		$script:LogIdentityCounts = @{}
		$script:conf = [pscustomobject]@{
			display = [pscustomobject]@{
				console = [pscustomobject]@{ enabled = $true; redact = 'auto' }
			}
		}
		$script:capturedLogs = @()
	}

	AfterEach {
		if ($null -eq $script:previousGithubActions) { Remove-Item Env:GITHUB_ACTIONS -ErrorAction SilentlyContinue } else { $env:GITHUB_ACTIONS = $script:previousGithubActions }
		if ($null -eq $script:previousCi) { Remove-Item Env:CI -ErrorAction SilentlyContinue } else { $env:CI = $script:previousCi }
		$global:debugging = $script:previousDebugging
		$script:conf = $null
	}

	It 'redacts known secrets locally by default' {
		Register-LogSecret -Secret 'local-token'
		Mock Write-Host { param($Object) $script:capturedLogs += [string]$Object }

		Out-Log -Level 'INFO' -Message 'token=local-token'

		$script:capturedLogs | Should -Contain '[INFO] token=***REDACTED:secret***'
	}

	It 'redacts known secrets in GitHub Actions auto mode' {
		$env:GITHUB_ACTIONS = 'true'
		Register-LogSecret -Secret 'actions-token' -Label 'token'
		Mock Write-Host { param($Object) $script:capturedLogs += [string]$Object }
		Register-GitHubLogMasks
		$script:capturedLogs = @()

		Out-Log -Level 'INFO' -Message 'token=actions-token; uid=ordinary-id'

		$script:capturedLogs | Should -Contain '[INFO] token=***REDACTED:token***; uid=ordinary-id'
		($script:capturedLogs -join "`n") | Should -Not -Match 'actions-token'
	}

	It 'redacts in generic CI auto mode without emitting GitHub commands' {
		$env:CI = 'true'
		Register-LogSecret -Secret 'ci-token' -Label 'token'
		Mock Write-Host { param($Object) $script:capturedLogs += [string]$Object }
		Register-GitHubLogMasks

		Out-Log -Level 'INFO' -Message 'token=ci-token'

		$script:capturedLogs | Should -Contain '[INFO] token=***REDACTED:token***'
		Should -Invoke Write-Host -Times 1 -Exactly
	}

	It 'redacts locally when redact is always' {
		$script:conf.display.console.redact = 'always'
		Register-LogSecret -Secret 'always-token' -Label 'token'
		Mock Write-Host { param($Object) $script:capturedLogs += [string]$Object }

		Out-Log -Level 'INFO' -Message 'token=always-token'

		$script:capturedLogs | Should -Contain '[INFO] token=***REDACTED:token***'
	}

	It 'refuses an unredacted logging opt-out even in GitHub Actions' {
		$env:GITHUB_ACTIONS = 'true'
		$script:conf.display.console.redact = 'never'
		Register-LogSecret -Secret 'opt-out-token'
		Mock Write-Host { param($Object) $script:capturedLogs += [string]$Object }
		Register-GitHubLogMasks

		Out-Log -Level 'INFO' -Message 'token=opt-out-token'

		$script:capturedLogs | Should -Contain '[INFO] token=***REDACTED:secret***'
		Should -Invoke Write-Host -Times 2 -Exactly
	}

	It 'redacts short identifiers only in named fields, preserving status codes' {
		Register-LogSecret -Secret '1' -Label 'role_id'
		Mock Write-Host { param($Object) $script:capturedLogs += [string]$Object }

		Out-Log -Level 'ERROR' -Message 'role=1; POST: 1001; HTTP: -1; GET: 0'
		$script:capturedLogs | Should -Contain '[ERROR] role=***REDACTED:role_id***; POST: 1001; HTTP: -1; GET: 0'
	}

	It 'keeps file names, counters and HTTP codes readable despite short identifiers' {
		$env:GITHUB_ACTIONS = 'true'
		Register-LogSecret -Secret '1' -Label 'role_id'
		Register-LogSecret -Secret '0' -Label 'game_id'
		Register-LogSecret -Secret '9' -Label 'server_id'
		Mock Write-Host { param($Object) $script:capturedLogs += [string]$Object }

		Register-GitHubLogMasks
		$script:capturedLogs | Should -BeNullOrEmpty

		Out-Log -Level 'INFO' -Message 'Merging: 001-discord.ps1; Profile #0; confirmed=1 failed=0; POST: -101; GET: 0; role=1; server_id:9'
		$script:capturedLogs | Should -Contain '[INFO] Merging: 001-discord.ps1; Profile #0; confirmed=1 failed=0; POST: -101; GET: 0; role=***REDACTED:role_id***; server_id:***REDACTED:server_id***'
	}

	It 'registers real credentials but never user IDs with the global GitHub masker' {
		$env:GITHUB_ACTIONS = 'true'
		Register-LogSecret -Secret 'auth-secret-value-long' -Label 'cred'
		Register-LogSecret -Secret 'small' -Label 'token'
		Register-LogSecret -Secret '1234567890123' -Label 'ltuid'
		Register-LogSecret -Secret '11' -Label 'role_id'
		Mock Write-Host { param($Object) $script:capturedLogs += [string]$Object }

		Register-GitHubLogMasks
		$script:capturedLogs | Should -HaveCount 1
		$script:capturedLogs | Should -Contain '::add-mask::auth-secret-value-long'
		$script:capturedLogs = @()

		Out-Log -Level 'INFO' -Message 'cred=auth-secret-value-long; token=small; ltuid=1234567890123; role=11; Profile #11'
		$script:capturedLogs | Should -Contain '[INFO] cred=***REDACTED:cred***; token=***REDACTED:token***; ltuid=***REDACTED:ltuid***; role=***REDACTED:role_id***; Profile #11'
	}

	It 'gives an auth credential precedence when its value was previously an identifier' {
		$env:GITHUB_ACTIONS = 'true'
		Register-LogSecret -Secret '9876543210' -Label 'user_id'
		Register-LogSecret -Secret '9876543210' -Label 'cred'
		Mock Write-Host { param($Object) $script:capturedLogs += [string]$Object }

		Register-GitHubLogMasks
		$script:capturedLogs | Should -Contain '::add-mask::9876543210'
		$script:LogSecretLabels['9876543210'] | Should -Be 'cred'
		$script:capturedLogs = @()
		Out-Log -Level 'INFO' -Message 'cred=9876543210'
		$script:capturedLogs | Should -Contain '[INFO] cred=***REDACTED:cred***'
	}

	It 'does not split whitespace-bearing cookie headers into global masks' {
		$env:GITHUB_ACTIONS = 'true'
		Register-LogSecret -Secret 'session=secret-alpha; other=secret-beta' -Label 'cookies'
		Mock Write-Host { param($Object) $script:capturedLogs += [string]$Object }

		Register-GitHubLogMasks
		$script:capturedLogs | Should -BeNullOrEmpty
		Out-Log -Level 'INFO' -Message 'Cookie: session=secret-alpha; other=secret-beta'
		$script:capturedLogs | Should -Contain '[INFO] Cookie: ***REDACTED:cookies***'
	}
	It 'removes unexpected account email addresses from message strings' {
		Mock Write-Host { param($Object) $script:capturedLogs += [string]$Object }

		Out-Log -Level 'INFO' -Message 'Checking account@example.com in for Game; completed 1/2'

		$script:capturedLogs | Should -Contain '[INFO] Checking ***REDACTED:email*** in for Game; completed 1/2'
	}
	It 'hides configured profile names and account handles without global substring masks' {
		$env:GITHUB_ACTIONS = 'true'
		$config = [pscustomobject]@{
			display = [pscustomobject]@{ discord = [pscustomobject]@{ bots = @() } }
			profiles = @(
				[pscustomobject]@{ console_name = 'smallku'; nickname = '小古#109'; account_name = 'Gamer_302'; username = 'taro'; cred = 'real-secret-credential' }
			)
		}
		Mock Write-Host { param($Object) $script:capturedLogs += [string]$Object }
		Register-LogSecretsFromConfig -Config $config

		$script:capturedLogs | Should -Contain '::add-mask::real-secret-credential'
		($script:capturedLogs -join ' ') | Should -Not -Match '::add-mask::smallku'
		($script:capturedLogs -join ' ') | Should -Not -Match '::add-mask::taro'
		$script:capturedLogs = @()

		Out-Log -Level 'INFO' -Message 'Checking smallku and taro in; 小古#109 (Role) Gamer_302; src/011-hoyolab.ps1; Profile #1; GET: 0'
		$script:capturedLogs | Should -Contain '[INFO] Checking ***REDACTED:console_name*** and ***REDACTED:username*** in; ***REDACTED:nickname*** (Role) ***REDACTED:account_name***; src/011-hoyolab.ps1; Profile #1; GET: 0'
	}

	It 'masks identity at the typed source without any registered secrets or runner masks' {
		$env:GITHUB_ACTIONS = 'true'
		$script:LogSecrets = @()
		$script:LogSecretLabels = @{}
		Mock Write-Host { param($Object) $script:capturedLogs += [string]$Object }

		$logName = Format-LogIdentity -Value 'a' -Label 'username'
		Out-Log -Level 'INFO' -Message "Checking $logName in for Synthetic game; count=1; POST: -101"

		$script:capturedLogs | Should -Contain '[INFO] Checking ***REDACTED:username-1*** in for Synthetic game; count=1; POST: -101'
		($script:capturedLogs -join ' ') | Should -Not -Match '::add-mask::'
		$script:LogSecrets | Should -BeNullOrEmpty
	}
	It 'assigns distinct stable anonymous aliases even for duplicate character names' {
		$script:LogIdentityAliases = @{}
		$script:LogIdentityCounts = @{}
		$one = Format-LogIdentity -Value 'ExampleName' -Label 'role' -Key 'account-a/channel-a/role-1'
		$two = Format-LogIdentity -Value 'ExampleName' -Label 'role' -Key 'account-b/channel-b/role-2'
		$oneAgain = Format-LogIdentity -Value 'ExampleName' -Label 'role' -Key 'account-a/channel-a/role-1'
		$one | Should -Be '***REDACTED:role-1***'
		$two | Should -Be '***REDACTED:role-2***'
		$oneAgain | Should -Be $one
		Format-LogIdentity -Value 'ExampleName' -Label 'account' -Key 'account-a' | Should -Be '***REDACTED:account-1***'
		$one | Should -Not -Match 'ExampleName|account-a|role-1/'

		$config = [pscustomobject]@{ profiles = @(); display = [pscustomobject]@{} }
		Register-LogSecretsFromConfig -Config $config
		Format-LogIdentity -Value 'OtherName' -Label 'role' -Key 'other-role' | Should -Be '***REDACTED:role-1***'
	}

	It 'keeps the identity aliases out of GitHub global add-mask registration' {
		$env:GITHUB_ACTIONS = 'true'
		Mock Write-Host { param($Object) $script:capturedLogs += [string]$Object }
		$first = Format-LogIdentity -Value 'first user' -Label 'account' -Key 'account-key'
		$second = Format-LogIdentity -Value 'second user' -Label 'account' -Key 'another-key'
		Register-GitHubLogMasks
		$script:capturedLogs | Should -BeNullOrEmpty
		$first | Should -Be '***REDACTED:account-1***'
		$second | Should -Be '***REDACTED:account-2***'
	}
	It 'does not corrupt an existing anonymous alias or filename that matches a real username' {
		Register-LogSecret -Secret 'role' -Label 'nickname'
		Register-LogSecret -Secret 'src' -Label 'username'
		$alias = Format-LogIdentity -Value 'role' -Label 'role' -Key 'distinct-role'
		Mock Write-Host { param($Object) $script:capturedLogs += [string]$Object }

		Out-Log -Level 'INFO' -Message "Checking $alias in src/001-discord.ps1; Checking src in for Game; GET: 0"

		$script:capturedLogs | Should -Contain '[INFO] Checking ***REDACTED:role-1*** in src/001-discord.ps1; Checking ***REDACTED:username*** in for Game; GET: 0'
	}
	It 'redacts account and character names in structured API responses' {
		$response = [pscustomobject]@{
			data = [pscustomobject]@{
				account_name = 'UserNotInConfig'
				email = 'me@example.com'
				phone = '123-456-7890'
				user = [pscustomobject]@{
					nickname = '角色名#42'
					username = 'SynUser'
					displayName = 'Player Name'
				}
			}
			status = 200
			count = 1
		}
		$rendered = Format-LogObject -InputObject $response

		foreach ($name in @('UserNotInConfig', 'me@example.com', '123-456-7890', '角色名#42', 'SynUser', 'Player Name')) {
			$rendered | Should -Not -Match ([regex]::Escape($name))
		}
		$rendered | Should -Match '"account_name": "\*\*\*REDACTED:account_name\*\*\*"'
		$rendered | Should -Match '"nickname": "\*\*\*REDACTED:nickname\*\*\*"'
		$rendered | Should -Match '"count": 1'
	}

	It 'redacts API-discovered one-character CJK nickname in a whole-token context' {
		Register-LogSecret -Secret '古' -Label 'nickname'
		Mock Write-Host { param($Object) $script:capturedLogs += [string]$Object }

		Out-Log -Level 'INFO' -Message '[官服 - 古] Signed; 失古物 x1'
		$script:capturedLogs | Should -Contain '[INFO] [官服 - ***REDACTED:nickname***] Signed; 失古物 x1'
	}
	It 'redacts sensitive and traceable keys with recognizable labels' {
		$env:GITHUB_ACTIONS = 'true'
		Register-LogSecret -Secret 'known-response-secret'
		$rendered = Format-LogObject -InputObject ([pscustomobject]@{
			token = 'new-server-issued-token'
			uid = '12345'
			id = 'ordinary-id'
			roleId = 'role-123'
			reward = 'Orundum'
			message = 'known-response-secret'
			user = [pscustomobject]@{
				id = 'ordinary-user-id'
				Authorization = 'Bearer new-auth-token'
			}
		})

		$rendered | Should -Match '"token": "\*\*\*REDACTED:token\*\*\*"'
		$rendered | Should -Match '"Authorization": "\*\*\*REDACTED:authorization\*\*\*"'
		$rendered | Should -Match '"uid": "\*\*\*REDACTED:uid\*\*\*"'
		$rendered | Should -Match '"id": "\*\*\*REDACTED:id\*\*\*"'
		$rendered | Should -Match '"roleId": "\*\*\*REDACTED:role_id\*\*\*"'
		$rendered | Should -Match '"reward": "Orundum"'
		$rendered | Should -Match '"message": "\*\*\*REDACTED:secret\*\*\*"'
		$rendered | Should -Not -Match 'new-server-issued-token'
		$rendered | Should -Not -Match 'new-auth-token'
	}

	It 'collects profile and webhook secrets into the registry' {
		$config = [pscustomobject]@{
			display = [pscustomobject]@{
				console = [pscustomobject]@{ enabled = $true; redact = 'always' }
				discord = [pscustomobject]@{ bots = @([pscustomobject]@{ webhook_url = 'https://example.invalid/webhook-secret'; discord_name = 'UniqueBotHandle' }) }
			}
			profiles = @([pscustomobject]@{
				token = 'profile-token'
				cred = 'profile-cred'
				cookies = 'PHPSESSID=cookie-secret'
				device = [pscustomobject]@{ id = 'Bdevice-secret'; seed = 'device-seed-secret' }
			})
		}

		Register-LogSecretsFromConfig -Config $config

		$script:LogSecrets | Should -Contain 'profile-token'
		$script:LogSecrets | Should -Contain 'profile-cred'
		$script:LogSecrets | Should -Contain 'PHPSESSID=cookie-secret'
		$script:LogSecrets | Should -Contain 'Bdevice-secret'
		$script:LogSecretLabels['Bdevice-secret'] | Should -Be 'device.id'
		$script:LogSecrets | Should -Contain 'device-seed-secret'
		$script:LogSecrets | Should -Contain 'https://example.invalid/webhook-secret'
		$script:LogSecrets | Should -Contain 'UniqueBotHandle'
		$script:LogSecretLabels['UniqueBotHandle'] | Should -Be 'discord_name'
		(Protect-LogMessage -Message 'Discord message body for bot UniqueBotHandle') | Should -Be 'Discord message body for bot ***REDACTED:discord_name***'
	}

	It 'normalizes legacy console values and separates pause from output settings' {
		$config = [pscustomobject]@{ display = [pscustomobject]@{ console = 'pause' } }

		Normalize-AnimeAttendanceConfig -Config $config | Out-Null

		$config.display.console.enabled | Should -BeTrue
		$config.display.console.redact | Should -Be 'always'
		$config.runtime.pause | Should -BeTrue

		$config.display.console = $false
		$config.runtime.pause = $false
		Normalize-AnimeAttendanceConfig -Config $config | Out-Null
		$config.display.console.enabled | Should -BeFalse
		$config.display.console.redact | Should -Be 'always'
		$config.runtime.pause | Should -BeFalse
	}

	It 'keeps console disabled independent from redaction policy' {
		$script:conf.display.console.enabled = $false
		Register-LogSecret -Secret 'hidden-token'
		Mock Write-Host { param($Object) $script:capturedLogs += [string]$Object }

		Out-Log -Level 'INFO' -Message 'token=hidden-token'

		$script:capturedLogs | Should -HaveCount 0
	}

	It 'keeps debug filtering independent from redaction policy' {
		$global:debugging = $false
		Register-LogSecret -Secret 'debug-token'
		Mock Write-Host { param($Object) $script:capturedLogs += [string]$Object }

		Out-Log -Level 'DEBUG' -Message 'token=debug-token'

		$script:capturedLogs | Should -HaveCount 0
	}
}
