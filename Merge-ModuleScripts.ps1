param (
    [switch]$Install,
    [switch]$Publish,
    [switch]$Clear,
    [switch]$IncrementVersion,
    [string]$Repository = "",
    [string]$NuGetApiKey = "NoKey"
)

$ErrorActionPreference = "Stop"

# Module name
$moduleName = "AnimeAttendance"
$outputPath = Join-Path $PSScriptRoot $moduleName
$psm1Path = Join-Path $outputPath "$moduleName.psm1"
$psd1Path = Join-Path $PSScriptRoot "$moduleName.psd1"

if ($Clear) {
    if (Test-Path $outputPath) {
        Remove-Item $outputPath -Recurse -Force
        Write-Host "🗑️ Cleared!" -ForegroundColor Green
    }
    exit
}

# Create output directory
if (!(Test-Path $outputPath)) {
    New-Item -ItemType Directory -Path $outputPath | Out-Null
}

$functionsToExport = @()
$aliasesToExport = @()
$psm1Content = @("# Module $moduleName - Generated on $(Get-Date)")

# Scan src and merge
$srcPath = Join-Path $PSScriptRoot "src"
$srcFiles = Get-ChildItem -Path $srcPath -Filter *.ps1 -ErrorAction SilentlyContinue | Sort-Object Name

if (!$srcFiles) {
    Write-Host "⚠️ No .ps1 files found in src!" -ForegroundColor Yellow
    exit
}

foreach ($file in $srcFiles) {
    Write-Host "📄 Merging: $($file.Name)" -ForegroundColor Gray
    $content = Get-Content $file.FullName -Raw -Encoding utf8

    # --- Extract Exports first ---
    $fileExports = @()
    $matches = [regex]::Matches($content, '##MOD_EXEC##\s+Export-ModuleMember\s+-Function\s+([-_A-Za-z0-9,\s]+)')
    foreach ($m in $matches) {
        $fns = $m.Groups[1].Value -split ',' | ForEach-Object { $_.Trim() }
        $fileExports += $fns
        $functionsToExport += $fns
    }

    $aliasMatches = [regex]::Matches($content, '##MOD_EXEC##\s+Export-ModuleMember\s+-Alias\s+([-_A-Za-z0-9,\s]+)')
    foreach ($m in $aliasMatches) {
        $als = $m.Groups[1].Value -split ',' | ForEach-Object { $_.Trim() }
        $aliasesToExport += $als
    }

    # Remove ##MOD_EXEC## markers
    $cleanContent = $content -replace '##MOD_EXEC##\s+', ''
    $psm1Content += $cleanContent
}

# Write .psm1 as UTF-16 LE for maximum Windows PowerShell parser compatibility
$psm1Content | Out-File $psm1Path -Encoding unicode
Write-Host "✅ Generated $psm1Path" -ForegroundColor Green

# Copy non-ps1 resources
Get-ChildItem -Path $srcPath | Where-Object { $_.Extension -ne ".ps1" } | ForEach-Object {
    Write-Host "📦 Copying: $($_.Name)" -ForegroundColor Gray
    Copy-Item $_.FullName -Destination $outputPath -Force
}

# Manifest (.psd1) handling
if (!(Test-Path $psd1Path)) {
    $author = Read-Host "Author of module"
    $description = Read-Host "Description of module"
    New-ModuleManifest -Path $psd1Path -RootModule "$moduleName.psm1" -Author $author -ModuleVersion "1.0.0" -Description $description
}

# Version auto-update
if ($IncrementVersion) {
    if (Test-Path $psd1Path) {
        try {
            $manifest = Import-PowerShellDataFile -Path $psd1Path
            $oldVersion = [version]$manifest.ModuleVersion
            $newVersion = "{0}.{1}.{2}" -f $oldVersion.Major, $oldVersion.Minor, ($oldVersion.Build + 1)
            (Get-Content $psd1Path) -replace "ModuleVersion = '\d+\.\d+\.\d+'", "ModuleVersion = '$newVersion'" | Out-File $psd1Path -Encoding unicode
            Write-Host "🔢 Version updated to $newVersion" -ForegroundColor Cyan
        } catch {
            Write-Host "⚠️ Cannot update version: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

# Update FunctionsToExport
$uniqueFunctions = $functionsToExport | Where-Object { $_ -ne "" } | Select-Object -Unique | Sort-Object
$uniqueAliases = $aliasesToExport | Where-Object { $_ -ne "" } | Select-Object -Unique | Sort-Object

$functionsString = '@("' + ($uniqueFunctions -join '","') + '")'
$aliasesString = '@("' + ($uniqueAliases -join '","') + '")'

$psd1Content = Get-Content $psd1Path -Raw -Encoding UTF8
$updatedPsd1 = $psd1Content -replace "FunctionsToExport = @\([^)]*\)", "FunctionsToExport = $functionsString"
$updatedPsd1 = $updatedPsd1 -replace "AliasesToExport = @\([^)]*\)", "AliasesToExport = $aliasesString"
$updatedPsd1 | Out-File (Join-Path $outputPath "$moduleName.psd1") -Encoding unicode
Write-Host "📋 FunctionsToExport: $($uniqueFunctions -join ', ')" -ForegroundColor Gray

# Local install
if ($Install) {
    $myDocs = [Environment]::GetFolderPath("MyDocuments")
    $allPaths = $env:PSModulePath -split ';'
    $psHomePath = $PSHOME.TrimEnd('\')

    # Build list of target paths for both PowerShell editions
    $targetPaths = @()

    # PowerShell Core (pwsh) path
    $pwshPath = Join-Path $myDocs "PowerShell\Modules"
    if ($allPaths -contains $pwshPath -or (Test-Path $pwshPath)) {
        $targetPaths += $pwshPath
    }

    # Windows PowerShell path
    $winPwshPath = Join-Path $myDocs "WindowsPowerShell\Modules"
    if ($allPaths -contains $winPwshPath -or (Test-Path $winPwshPath)) {
        $targetPaths += $winPwshPath
    }

    # Fallback: use current PSModulePath resolution if neither found
    if ($targetPaths.Count -eq 0) {
        $targetRoot = $allPaths | Where-Object { $_ -like "*\Documents*" -and $_ -notlike "$psHomePath*" } | Select-Object -First 1
        if ([string]::IsNullOrWhiteSpace($targetRoot)) {
            $targetRoot = $allPaths | Where-Object { $_ -notlike "$psHomePath*" } | Select-Object -First 1
        }
        if ([string]::IsNullOrWhiteSpace($targetRoot)) {
            $targetRoot = $pwshPath
        }
        $targetPaths = @($targetRoot)
    }

    $targetPaths = $targetPaths | Select-Object -Unique

    foreach ($targetRoot in $targetPaths) {
        $targetInstallPath = Join-Path $targetRoot $moduleName

        Write-Host "🚚 Deploying $moduleName to $targetRoot..." -ForegroundColor Cyan

        if (Test-Path $targetInstallPath) {
            Remove-Item $targetInstallPath -Recurse -Force
        }

        if (!(Test-Path $targetRoot)) {
            New-Item -ItemType Directory -Path $targetRoot | Out-Null
        }

        Copy-Item -Path $outputPath -Destination $targetRoot -Recurse -Force

        Write-Host "✅ Deployed to $targetRoot!" -ForegroundColor Green
    }

    Write-Host "✅ All deployments complete! Use 'Import-Module $moduleName -Force'" -ForegroundColor Green
}

# Publish to NuGet
if ($Publish) {
    if ([string]::IsNullOrWhiteSpace($Repository)) {
        Write-Host "⚠️ Repository parameter missing" -ForegroundColor Red
        exit
    }
    Publish-Module -Path $outputPath -Repository $Repository -NuGetApiKey $NuGetApiKey
    Write-Host "🚀 Published to $Repository!" -ForegroundColor Green
}

Write-Host "`n🎉 Done! Output: $outputPath" -ForegroundColor Magenta
