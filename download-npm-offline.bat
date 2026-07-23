@echo off
setlocal

if "%~1"=="" (
  echo Usage: %~nx0 package[@version-or-range] [output-dir] [registry-url]
  echo Example: %~nx0 express@4 offline-npm-repo https://registry.npmjs.org
  exit /b 1
)

set "NPM_OFFLINE_PACKAGE=%~1"
set "NPM_OFFLINE_OUTPUT=%~2"
set "NPM_OFFLINE_REGISTRY=%~3"

if "%NPM_OFFLINE_OUTPUT%"=="" set "NPM_OFFLINE_OUTPUT=offline-npm-repo"
if "%NPM_OFFLINE_REGISTRY%"=="" set "NPM_OFFLINE_REGISTRY=https://registry.npmjs.org"

powershell -NoProfile -ExecutionPolicy Bypass -Command "$raw = Get-Content -Raw -LiteralPath '%~f0'; $marker = '# POWERSHELL_' + 'PAYLOAD'; $payload = ($raw -split [regex]::Escape($marker), 2)[1]; Invoke-Expression $payload"
exit /b %ERRORLEVEL%

# POWERSHELL_PAYLOAD
$ErrorActionPreference = 'Stop'

$packageSpec = $env:NPM_OFFLINE_PACKAGE
$outputDir = [IO.Path]::GetFullPath($env:NPM_OFFLINE_OUTPUT)
$registry = $env:NPM_OFFLINE_REGISTRY.TrimEnd('/')
$userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) npmjs-offline-install'

function Fail($message) {
  Write-Error $message
  exit 1
}

function Test-Command($name) {
  return $null -ne (Get-Command $name -ErrorAction SilentlyContinue)
}

if (-not (Test-Command 'curl.exe')) {
  Fail 'curl.exe was not found. Windows 11 includes curl by default; verify it is available in PATH.'
}

function Split-PackageSpec($spec) {
  $name = $spec
  $range = 'latest'
  $at = $spec.LastIndexOf('@')
  if ($at -gt 0) {
    $name = $spec.Substring(0, $at)
    $range = $spec.Substring($at + 1)
  }
  if ([string]::IsNullOrWhiteSpace($name)) {
    Fail "Invalid package spec: $spec"
  }
  return @{ Name = $name; Range = $range }
}

function Get-EscapedPackageName($name) {
  if ($name.StartsWith('@')) {
    return $name.Replace('/', '%2f')
  }
  return [uri]::EscapeDataString($name)
}

function Invoke-CurlDownload($url, $target) {
  $parent = Split-Path -Parent $target
  if (-not (Test-Path $parent)) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }

  & curl.exe -fL --retry 3 --retry-delay 2 -A $userAgent -H 'Accept: application/json' -o $target $url
  if ($LASTEXITCODE -ne 0) {
    Fail "curl failed for $url"
  }
}

function Get-Metadata($name) {
  $metadataPath = Join-Path $metadataDir ("{0}.json" -f ($name -replace '[/@]', '_'))
  if (-not (Test-Path $metadataPath)) {
    $url = "$registry/$(Get-EscapedPackageName $name)"
    Write-Host "metadata  $name"
    Invoke-CurlDownload $url $metadataPath
  }
  return Get-Content -Raw -LiteralPath $metadataPath | ConvertFrom-Json
}

function Convert-Version($value) {
  $clean = ([string]$value -replace '^[vV]', '') -replace '-.*$', ''
  try {
    return [version]$clean
  } catch {
    return $null
  }
}

function Compare-Version($left, $op, $right) {
  $a = Convert-Version $left
  $b = Convert-Version $right
  if ($null -eq $a -or $null -eq $b) {
    return $false
  }

  $cmp = $a.CompareTo($b)
  switch ($op) {
    '>'  { return $cmp -gt 0 }
    '>=' { return $cmp -ge 0 }
    '<'  { return $cmp -lt 0 }
    '<=' { return $cmp -le 0 }
    '='  { return $cmp -eq 0 }
  }
  return $false
}

function Test-SimpleRange($version, $range) {
  $range = $range.Trim()
  if ($range -eq '' -or $range -eq '*' -or $range -eq 'latest') {
    return $true
  }
  if ($range -match '^[vV]?\d+\.\d+\.\d+(-[\w.-]+)?$') {
    return $version -eq ($range -replace '^[vV]', '')
  }
  if ($range -match '^(\d+)\.(x|\*)$') {
    return $version.StartsWith("$($Matches[1]).")
  }
  if ($range -match '^(\d+)\.(\d+)\.(x|\*)$') {
    return $version.StartsWith("$($Matches[1]).$($Matches[2]).")
  }
  if ($range -match '^(\d+)$') {
    return $version.StartsWith("$($Matches[1]).")
  }
  if ($range -match '^(\^|~)\s*([vV]?\d+\.\d+\.\d+(-[\w.-]+)?)$') {
    $kind = $Matches[1]
    $baseText = $Matches[2] -replace '^[vV]', ''
    $base = Convert-Version $baseText
    if ($null -eq $base) {
      return $false
    }

    if (-not (Compare-Version $version '>=' $baseText)) {
      return $false
    }

    if ($kind -eq '~') {
      $upper = [version]::new($base.Major, $base.Minor + 1, 0)
    } elseif ($base.Major -gt 0) {
      $upper = [version]::new($base.Major + 1, 0, 0)
    } elseif ($base.Minor -gt 0) {
      $upper = [version]::new(0, $base.Minor + 1, 0)
    } else {
      $upper = [version]::new(0, 0, $base.Build + 1)
    }
    return Compare-Version $version '<' $upper.ToString()
  }
  if ($range -match '^(>=|>|<=|<|=)\s*([vV]?\d+\.\d+\.\d+(-[\w.-]+)?)$') {
    return Compare-Version $version $Matches[1] ($Matches[2] -replace '^[vV]', '')
  }

  return $false
}

function Test-Range($version, $range) {
  foreach ($orPart in ([string]$range -split '\|\|')) {
    $parts = $orPart.Trim() -split '\s+' | Where-Object { $_ -ne '' }
    if ($parts.Count -eq 0) {
      return $true
    }

    $ok = $true
    foreach ($part in $parts) {
      if (-not (Test-SimpleRange $version $part)) {
        $ok = $false
        break
      }
    }
    if ($ok) {
      return $true
    }
  }
  return $false
}

function Resolve-Version($metadata, $range) {
  $distTags = $metadata.'dist-tags'
  if ($range -eq 'latest' -and $distTags.latest) {
    return $distTags.latest
  }
  if ($distTags.PSObject.Properties.Name -contains $range) {
    return $distTags.$range
  }
  if ($metadata.versions.PSObject.Properties.Name -contains $range) {
    return $range
  }

  $versions = $metadata.versions.PSObject.Properties.Name |
    Where-Object { Convert-Version $_ } |
    Sort-Object @{ Expression = { Convert-Version $_ }; Descending = $true }

  foreach ($version in $versions) {
    if (Test-Range $version $range) {
      return $version
    }
  }

  Fail "Could not resolve $($metadata.name)@$range"
}

function Add-DependencyMap($queue, $dependencyMap) {
  if ($null -eq $dependencyMap) {
    return
  }
  foreach ($property in $dependencyMap.PSObject.Properties) {
    $queue.Enqueue(@{ Name = $property.Name; Range = [string]$property.Value })
  }
}

New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
$tarballDir = Join-Path $outputDir 'tarballs'
$metadataDir = Join-Path $outputDir 'metadata'
New-Item -ItemType Directory -Force -Path $tarballDir, $metadataDir | Out-Null

$root = Split-PackageSpec $packageSpec
$queue = [System.Collections.Queue]::new()
$queue.Enqueue($root)
$visitedRequests = @{}
$downloadedVersions = @{}
$manifest = [System.Collections.Generic.List[object]]::new()

while ($queue.Count -gt 0) {
  $request = $queue.Dequeue()
  $requestKey = "$($request.Name)@$($request.Range)"
  if ($visitedRequests.ContainsKey($requestKey)) {
    continue
  }
  $visitedRequests[$requestKey] = $true

  $metadata = Get-Metadata $request.Name
  $version = Resolve-Version $metadata $request.Range
  $versionKey = "$($request.Name)@$version"
  if ($downloadedVersions.ContainsKey($versionKey)) {
    continue
  }

  $package = $metadata.versions.$version
  $tarballUrl = $package.dist.tarball
  if ([string]::IsNullOrWhiteSpace($tarballUrl)) {
    Fail "No tarball URL found for $versionKey"
  }

  $fileName = "{0}-{1}.tgz" -f (($request.Name -replace '^@', '') -replace '/', '-'), $version
  $tarballPath = Join-Path $tarballDir $fileName
  Write-Host "tarball   $versionKey"
  Invoke-CurlDownload $tarballUrl $tarballPath

  $downloadedVersions[$versionKey] = $true
  $manifest.Add([pscustomobject]@{
    name = $request.Name
    version = $version
    request = $request.Range
    file = "tarballs/$fileName"
    tarball = $tarballUrl
  }) | Out-Null

  Add-DependencyMap $queue $package.dependencies
  Add-DependencyMap $queue $package.optionalDependencies
}

$manifestPath = Join-Path $outputDir 'package-list.json'
$manifest | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 -LiteralPath $manifestPath

$installScript = Join-Path $outputDir 'install-offline.bat'
$rootTarball = ($manifest | Select-Object -First 1).file -replace '/', '\'
@(
  '@echo off'
  'setlocal'
  'cd /d "%~dp0"'
  'for %%F in ("tarballs\*.tgz") do npm cache add "%%~fF" --no-audit'
  'npm install --offline --no-audit --prefer-offline "' + $rootTarball + '"'
) | Set-Content -Encoding ASCII -LiteralPath $installScript

Write-Host ''
Write-Host "Done. Offline repo written to: $outputDir"
Write-Host "Downloaded packages: $($manifest.Count)"
Write-Host "Install later with: $installScript"
