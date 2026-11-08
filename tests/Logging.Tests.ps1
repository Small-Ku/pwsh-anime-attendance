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
		$script:GitHubMaskedLogSecrets = @{}
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

	It 'redacts short identifiers only as whole values, preserving status codes' {
		Register-LogSecret -Secret '1' -Label 'role_id'
		Mock Write-Host { param($Object) $script:capturedLogs += [string]$Object }

		Out-Log -Level 'ERROR' -Message 'role=1; POST: 1001; HTTP: -1; GET: 0'
		$script:capturedLogs | Should -Contain '[ERROR] role=***REDACTED:role_id***; POST: 1001; HTTP: -1; GET: 0'
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
				discord = [pscustomobject]@{ bots = @([pscustomobject]@{ webhook_url = 'https://example.invalid/webhook-secret' }) }
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
