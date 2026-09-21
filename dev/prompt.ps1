#Requires -Version 5.1
<#
.SYNOPSIS
    Interactively pick a live model from a running vLLM server and submit prompts.

.DESCRIPTION
    Queries the vLLM OpenAI-compatible server for its active models
    (GET /v1/models), lets you choose one, then loops reading prompts and
    printing completions (POST /v1/completions). Works against any loaded model
    (completions endpoint needs no chat template).

.PARAMETER ServerHost
    Server host. Alias: -Host. Default 'localhost'.

.PARAMETER Port
    Server port. Default 8000.

.PARAMETER Model
    Skip the picker and use this model id directly.

.PARAMETER MaxTokens
    Max tokens to generate per prompt. Default 128.

.PARAMETER Temperature
    Sampling temperature. Default 0.7.

.PARAMETER ApiKey
    Optional bearer token if the server was started with --api-key.

.EXAMPLE
    pwsh ./dev/prompt.ps1
    pwsh ./dev/prompt.ps1 -Host 127.0.0.1 -Port 8001
    pwsh ./dev/prompt.ps1 -Model facebook/opt-125m -MaxTokens 64
#>
[CmdletBinding()]
param(
    [Alias('Host')]
    [string]$ServerHost = 'localhost',
    [int]$Port          = 8000,
    [string]$Model,
    [int]$MaxTokens     = 128,
    [double]$Temperature = 0.7,
    [string]$ApiKey
)

$ErrorActionPreference = 'Stop'

$base    = "http://${ServerHost}:${Port}/v1"
$headers = @{ 'Content-Type' = 'application/json' }
if ($ApiKey) { $headers['Authorization'] = "Bearer $ApiKey" }

function Get-Models {
    try {
        $resp = Invoke-RestMethod -Method Get -Uri "$base/models" -Headers $headers
        return @($resp.data | ForEach-Object { $_.id })
    }
    catch {
        throw "Could not reach vLLM at $base/models. Is the server running? ($($_.Exception.Message))"
    }
}

function Select-Model {
    param([string[]]$Available)

    if ($Model) {
        if ($Available -notcontains $Model) {
            Write-Host "Warning: '$Model' not in the server's active models." -ForegroundColor Yellow
        }
        return $Model
    }

    if ($Available.Count -eq 1) { return $Available[0] }

    Write-Host "`nActive models on ${ServerHost}:${Port}:" -ForegroundColor Cyan
    for ($n = 0; $n -lt $Available.Count; $n++) {
        Write-Host ("  [{0}] {1}" -f ($n + 1), $Available[$n])
    }
    $choice = Read-Host "Choose a model [1]"
    if ([string]::IsNullOrWhiteSpace($choice)) { $choice = '1' }

    $index = 0
    if ([int]::TryParse($choice, [ref]$index) -and $index -ge 1 -and $index -le $Available.Count) {
        return $Available[$index - 1]
    }
    if ($Available -contains $choice) { return $choice }
    throw "Invalid selection: $choice"
}

function Send-Prompt {
    param([string]$ModelId, [string]$PromptText)

    $body = @{
        model       = $ModelId
        prompt      = $PromptText
        max_tokens  = $MaxTokens
        temperature = $Temperature
    } | ConvertTo-Json -Compress

    $resp = Invoke-RestMethod -Method Post -Uri "$base/completions" `
        -Headers $headers -Body $body
    return $resp.choices[0].text
}

# --- main ---
$models   = Get-Models
$modelId  = Select-Model -Available $models
Write-Host "Using model: $modelId" -ForegroundColor Green
Write-Host "Type a prompt and press Enter. Blank line, 'exit' or 'quit' to stop.`n"

while ($true) {
    $prompt = Read-Host 'prompt'
    if ([string]::IsNullOrWhiteSpace($prompt) -or $prompt -in @('exit', 'quit')) {
        Write-Host "Bye." -ForegroundColor Cyan
        break
    }
    try {
        $text = Send-Prompt -ModelId $modelId -PromptText $prompt
        Write-Host $text -ForegroundColor Yellow
        Write-Host ''
    }
    catch {
        Write-Host "Request failed: $($_.Exception.Message)" -ForegroundColor Red
    }
}
