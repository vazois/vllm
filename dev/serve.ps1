#Requires -Version 5.1
<#
.SYNOPSIS
    Serve a vLLM model on CPU with the ExampleConnector KV cache, using
    dev/run.env. Prompts for the model unless -Model is supplied.

.DESCRIPTION
    Runs on a regular Linux distro (Ubuntu / Azure Linux) via PowerShell (pwsh).
    Parses dev/run.env, exports the runtime variables into the current process
    (vllm inherits them), and launches `vllm serve`. The model catalog below is
    easily extendable: add one line to $Models to register a new option. A value
    not present in the catalog is treated as a raw Hugging Face model id with the
    -Dtype default.

.PARAMETER Model
    Friendly key from the catalog (e.g. 'qwen2.5-0.5b') OR a raw HF model id
    (e.g. 'mistralai/Mistral-7B-Instruct-v0.3'). If omitted, an interactive
    menu is shown.

.PARAMETER Dtype
    dtype override for raw/unknown models. Defaults to bfloat16 (Zen CPU-safe).

.PARAMETER NoConnector
    Serve without the KV connector (plain inference).

.PARAMETER EnvFile
    Path to the runtime env file. Defaults to run.env next to this script.

.PARAMETER RepoPath / VenvPath
    Paths to the repo and venv (defaults from VLLM_DEV_* in the env file).

.EXAMPLE
    pwsh ./dev/serve.ps1                       # interactive model picker
    pwsh ./dev/serve.ps1 -Model qwen2.5-0.5b
    pwsh ./dev/serve.ps1 -Model facebook/opt-125m -NoConnector
#>
[CmdletBinding()]
param(
    [string]$Model,
    [string]$Dtype   = 'bfloat16',
    [switch]$NoConnector,
    [string]$EnvFile  = (Join-Path $PSScriptRoot 'run.env'),
    [string]$RepoPath,
    [string]$VenvPath
)

$ErrorActionPreference = 'Stop'

# ============================================================================
# MODEL CATALOG — add a line here to register a new option.
#   Key   = friendly name shown in the menu / passed to -Model
#   Id    = Hugging Face model id passed to `vllm serve`
#   Dtype = dtype for this model
# ============================================================================
$Models = [ordered]@{
    'opt-125m'     = [pscustomobject]@{ Id = 'facebook/opt-125m';          Dtype = 'bfloat16' }
    'qwen2.5-0.5b' = [pscustomobject]@{ Id = 'Qwen/Qwen2.5-0.5B-Instruct'; Dtype = 'bfloat16' }
    'qwen2.5-1.5b' = [pscustomobject]@{ Id = 'Qwen/Qwen2.5-1.5B-Instruct'; Dtype = 'bfloat16' }
}
# ============================================================================

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

function Resolve-Model {
    param([string]$Requested)

    if ($Requested) {
        if ($Models.Contains($Requested)) {
            return [pscustomobject]@{ Id = $Models[$Requested].Id; Dtype = $Models[$Requested].Dtype }
        }
        # Unknown value -> treat as a raw HF id with the -Dtype default.
        return [pscustomobject]@{ Id = $Requested; Dtype = $Dtype }
    }

    Write-Host "`nSelect a model to serve:" -ForegroundColor Cyan
    $keys = @($Models.Keys)
    for ($n = 0; $n -lt $keys.Count; $n++) {
        Write-Host ("  [{0}] {1,-14} {2}" -f ($n + 1), $keys[$n], $Models[$keys[$n]].Id)
    }
    Write-Host "  Or type a raw Hugging Face model id."
    $choice = Read-Host "Choice (number / key / HF id) [1]"
    if ([string]::IsNullOrWhiteSpace($choice)) { $choice = '1' }

    $index = 0
    if ([int]::TryParse($choice, [ref]$index) -and $index -ge 1 -and $index -le $keys.Count) {
        $key = $keys[$index - 1]
        return [pscustomobject]@{ Id = $Models[$key].Id; Dtype = $Models[$key].Dtype }
    }
    if ($Models.Contains($choice)) {
        return [pscustomobject]@{ Id = $Models[$choice].Id; Dtype = $Models[$choice].Dtype }
    }
    return [pscustomobject]@{ Id = $choice; Dtype = $Dtype }
}

Write-Host "Loading runtime environment from $EnvFile" -ForegroundColor Cyan
$vars = Import-DotEnv -Path $EnvFile

# Resolve settings: explicit param > env file (VLLM_DEV_*) > fallback default.
if (-not $RepoPath) { $RepoPath = $env:VLLM_DEV_REPO_PATH }
if (-not $VenvPath) { $VenvPath = $env:VLLM_DEV_VENV_PATH }
if (-not $RepoPath) { $RepoPath = '/root/vllm' }
if (-not $VenvPath) { $VenvPath = '/root/.venv' }

$selected = Resolve-Model -Requested $Model
Write-Host ("Model : {0}  (dtype={1})" -f $selected.Id, $selected.Dtype) -ForegroundColor Green

# Build serve arguments.
$serveArgs = @('serve', $selected.Id, '--dtype', $selected.Dtype)

if (-not $NoConnector) {
    $storage = if ($env:VLLM_KV_STORAGE_PATH) { $env:VLLM_KV_STORAGE_PATH } else { '/tmp/vllm_kv' }
    $kvConfig = @{
        kv_connector              = 'ExampleConnector'
        kv_role                   = 'kv_both'
        kv_connector_extra_config = @{ shared_storage_path = $storage }
    } | ConvertTo-Json -Compress
    $serveArgs += @('--kv-transfer-config', $kvConfig)
    Write-Host ("KV cache: ExampleConnector -> {0}" -f $storage) -ForegroundColor Green
}

$vllmExe = if (Test-Path -LiteralPath "$VenvPath/bin/vllm") { "$VenvPath/bin/vllm" } else { 'vllm' }

Write-Host "Starting vllm serve in $RepoPath ..." -ForegroundColor Cyan
Push-Location -LiteralPath $RepoPath
try {
    & $vllmExe @serveArgs
}
finally {
    Pop-Location
}
