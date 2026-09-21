#Requires -Version 5.1
<#
.SYNOPSIS
    Build/install vLLM for CPU (editable) using dev/build.env.

.DESCRIPTION
    Runs on a regular Linux distro (Ubuntu / Azure Linux) via PowerShell (pwsh).
    Parses dev/build.env, exports the build variables into the current process
    (child processes inherit them), points uv at the venv, and runs the editable
    install. Because the install is editable + precompiled-wheel based, Python
    edits take effect on restart with no local kernel compile.

.PARAMETER EnvFile
    Path to the build env file. Defaults to build.env next to this script.

.PARAMETER RepoPath
    Path to the vLLM checkout (default from VLLM_DEV_REPO_PATH in the env file).

.PARAMETER VenvPath
    Path to the uv/venv (default from VLLM_DEV_VENV_PATH in the env file).

.PARAMETER Uv
    Path to the uv binary (default from VLLM_DEV_UV; falls back to 'uv' on PATH).

.EXAMPLE
    pwsh ./dev/build.ps1
    pwsh ./dev/build.ps1 -RepoPath /home/me/vllm -VenvPath /home/me/.venv
#>
[CmdletBinding()]
param(
    [string]$EnvFile  = (Join-Path $PSScriptRoot 'build.env'),
    [string]$RepoPath,
    [string]$VenvPath,
    [string]$Uv
)

$ErrorActionPreference = 'Stop'

# Parse a dotenv-style file and set each KEY=VALUE into the process environment
# so child processes (uv, and the build it spawns) inherit them.
function Import-DotEnv {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Env file not found: $Path" }
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($line in Get-Content -LiteralPath $Path) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $i = $t.IndexOf('=')
        if ($i -lt 1) { continue }
        $key = $t.Substring(0, $i).Trim()
        $val = $t.Substring($i + 1).Trim()
        Set-Item -LiteralPath "Env:$key" -Value $val
        $names.Add($key)
    }
    return $names
}

Write-Host "Loading build environment from $EnvFile" -ForegroundColor Cyan
$vars = Import-DotEnv -Path $EnvFile
$vars | ForEach-Object { Write-Host ("  {0}={1}" -f $_, (Get-Item "Env:$_").Value) }

# Resolve settings: explicit param > env file (VLLM_DEV_*) > fallback default.
if (-not $RepoPath) { $RepoPath = $env:VLLM_DEV_REPO_PATH }
if (-not $VenvPath) { $VenvPath = $env:VLLM_DEV_VENV_PATH }
if (-not $Uv)       { $Uv       = $env:VLLM_DEV_UV }
if (-not $RepoPath) { $RepoPath = '/root/vllm' }
if (-not $VenvPath) { $VenvPath = '/root/.venv' }
if (-not $Uv)       { $Uv       = 'uv' }

# uv targets the venv named by VIRTUAL_ENV.
$env:VIRTUAL_ENV = $VenvPath
$uvExe = if (Test-Path -LiteralPath $Uv) { $Uv } else { 'uv' }

Write-Host "Building vLLM (editable) in $RepoPath -> venv $VenvPath" -ForegroundColor Cyan
Push-Location -LiteralPath $RepoPath
try {
    & $uvExe pip install --editable .
}
finally {
    Pop-Location
}

if ($LASTEXITCODE -ne 0) { throw "Build failed (exit code $LASTEXITCODE)" }
Write-Host "Build complete." -ForegroundColor Green
