param(
  [string]$AndroidSdk = '',
  [string]$JavaHome = '',
  [string]$BuildToolsVersion = '',
  [string]$CompileSdk = ''
)

$ErrorActionPreference = 'Stop'

if (-not $AndroidSdk) {
  if ($env:ANDROID_SDK_ROOT) {
    $AndroidSdk = $env:ANDROID_SDK_ROOT
  } elseif ($env:ANDROID_HOME) {
    $AndroidSdk = $env:ANDROID_HOME
  } else {
    $AndroidSdk = Join-Path $env:LOCALAPPDATA 'Android\Sdk'
  }
}
if (-not (Test-Path -LiteralPath $AndroidSdk)) {
  throw "Android SDK not found: $AndroidSdk"
}

if (-not $CompileSdk) {
  $CompileSdk = Get-ChildItem -LiteralPath (Join-Path $AndroidSdk 'platforms') -Directory |
    Where-Object { $_.Name -match '^android-(\d+)$' } |
    ForEach-Object { [int]$Matches[1] } |
    Sort-Object -Descending |
    Select-Object -First 1
}
if (-not $BuildToolsVersion) {
  $BuildToolsVersion = Get-ChildItem -LiteralPath (Join-Path $AndroidSdk 'build-tools') -Directory |
    Where-Object { $_.Name -match '^\d+(\.\d+){1,3}$' } |
    Sort-Object { [version]$_.Name } -Descending |
    Select-Object -ExpandProperty Name -First 1
}

if (-not $JavaHome) {
  $JavaHome = $env:JAVA_HOME
}
if (-not $JavaHome) {
  $javaCandidates = @()
  $javaCandidates += Get-ChildItem -LiteralPath (Join-Path $env:ProgramFiles 'Java') -Directory -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending |
    Select-Object -ExpandProperty FullName
  $javaCandidates += Get-ChildItem -Path (Join-Path $env:ProgramFiles 'Huawei\DevEco Studio*\jbr') -Directory `
    -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty FullName
  $JavaHome = $javaCandidates |
    Where-Object {
      (Test-Path -LiteralPath (Join-Path $_ 'bin\javac.exe')) -and
      (Test-Path -LiteralPath (Join-Path $_ 'bin\jar.exe'))
    } |
    Select-Object -First 1
}
$toolRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent $toolRoot)
$buildRoot = Join-Path $toolRoot 'build'
$classRoot = Join-Path $buildRoot 'classes'
$dexRoot = Join-Path $buildRoot 'dex'
$sourceRoot = Join-Path $toolRoot 'src'
$androidJar = Join-Path $AndroidSdk "platforms\android-$CompileSdk\android.jar"
$d8 = Join-Path $AndroidSdk "build-tools\$BuildToolsVersion\d8.bat"
$javac = if ($JavaHome) {
  Join-Path $JavaHome 'bin\javac.exe'
} else {
  (Get-Command javac.exe -ErrorAction Stop).Source
}
$jar = if ($JavaHome) {
  Join-Path $JavaHome 'bin\jar.exe'
} else {
  (Get-Command jar.exe -ErrorAction Stop).Source
}
$intermediateJar = Join-Path $buildRoot 'remote-lock-state-classes.jar'
$outputJar = Join-Path $projectRoot 'app\src\main\resources\rawfile\remote-lock-state-v1'

foreach ($requiredPath in @($androidJar, $d8, $javac, $jar)) {
  if (-not (Test-Path -LiteralPath $requiredPath)) {
    throw "Required build tool not found: $requiredPath"
  }
}

if (Test-Path -LiteralPath $buildRoot) {
  Remove-Item -LiteralPath $buildRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $classRoot | Out-Null
New-Item -ItemType Directory -Path $dexRoot | Out-Null

$sources = Get-ChildItem -LiteralPath $sourceRoot -Filter '*.java' -Recurse |
  Select-Object -ExpandProperty FullName
& $javac --release 8 -classpath $androidJar -d $classRoot $sources
if ($LASTEXITCODE -ne 0) {
  throw "javac failed with exit code $LASTEXITCODE"
}

& $jar --create --file $intermediateJar -C $classRoot .
if ($LASTEXITCODE -ne 0) {
  throw "jar failed with exit code $LASTEXITCODE"
}

& $d8 --min-api 23 --output $dexRoot $intermediateJar
if ($LASTEXITCODE -ne 0) {
  throw "d8 failed with exit code $LASTEXITCODE"
}

& $jar --create --file $outputJar -C $dexRoot classes.dex
if ($LASTEXITCODE -ne 0) {
  throw "final jar packaging failed with exit code $LASTEXITCODE"
}

Write-Host "Generated $outputJar"
