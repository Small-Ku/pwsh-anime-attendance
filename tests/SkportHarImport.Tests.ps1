Describe 'Skport local HAR importer' -Skip:($null -eq (Get-Command zstd -ErrorAction SilentlyContinue) -or $null -eq (Get-Command tar -ErrorAction SilentlyContinue)) {
	BeforeAll {
		$script:fixtureDir = Join-Path ([System.IO.Path]::GetTempPath()) ('skport-har-pester-' + [guid]::NewGuid().ToString('N'))
		New-Item -ItemType Directory -Path $script:fixtureDir | Out-Null
		$script:testCred = 'A' * 32
		$script:configFile = Join-Path $script:fixtureDir 'sign.json'
		@{ profiles = @(@{ platform = 'skport'; cred = $script:testCred }) } |
			ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $script:configFile -Encoding utf8
		$script:importer = Join-Path $PSScriptRoot '..\tools\Import-SkportCredentialFromHar.ps1'
		function New-SyntheticHarArchive {
			param([int]$Code, [string]$Name)
			$harName = "$Name.har"
			$harPath = Join-Path $script:fixtureDir $harName
			$response = @{ code = $Code; data = @{ ts = '1' } } | ConvertTo-Json -Compress
			$har = @{ log = @{ entries = @(@{
				request = @{
					method = 'POST'
					url = 'https://zonai.skport.com/web/v1/game/endfield/attendance'
					headers = @(@{ name = 'cred'; value = $script:testCred })
				}
				response = @{ status = 200; content = @{ text = $response } }
			}) } }
			$har | ConvertTo-Json -Depth 12 -Compress | Set-Content -LiteralPath $harPath -Encoding utf8
			$tarPath = Join-Path $script:fixtureDir "$Name.tar"
			& tar -cf $tarPath -C $script:fixtureDir $harName
			if ($LASTEXITCODE) { throw 'Failed to create synthetic HAR tar' }
			$archive = Join-Path $script:fixtureDir "$Name.tar.zst"
			& zstd -q -f -o $archive $tarPath
			if ($LASTEXITCODE) { throw 'Failed to create synthetic HAR archive' }
			return $archive
		}
	}
	AfterAll {
		if (Test-Path -LiteralPath $script:fixtureDir) {
			Remove-Item -LiteralPath $script:fixtureDir -Force -Recurse
		}
	}
	It 'accepts only a confirmed browser attendance response without printing the credential' {
		$archive = New-SyntheticHarArchive -Code 0 -Name 'confirmed'
		$output = & $script:importer -HarArchivePath $archive -ConfigPath $script:configFile
		$output | Should -Match 'already up to date'
		($output -join ' ') | Should -Not -Match $script:testCred
		$profile = Get-Content -LiteralPath $script:configFile -Raw | ConvertFrom-Json
		$profile.profiles[0].cred | Should -Be $script:testCred
	}
	It 'reads an uncompressed HAR directly without requiring decompression' {
		$null = New-SyntheticHarArchive -Code 0 -Name 'plain'
		$harPath = Join-Path $script:fixtureDir 'plain.har'
		$output = & $script:importer -HarArchivePath $harPath -ConfigPath $script:configFile
		$output | Should -Match 'already up to date'
		($output -join ' ') | Should -Not -Match $script:testCred
	}
	It 'rejects an unconfirmed browser response without changing config' {
		$archive = New-SyntheticHarArchive -Code 1 -Name 'rejected'
		{ & $script:importer -HarArchivePath $archive -ConfigPath $script:configFile } | Should -Throw
		$profile = Get-Content -LiteralPath $script:configFile -Raw | ConvertFrom-Json
		$profile.profiles[0].cred | Should -Be $script:testCred
	}
}