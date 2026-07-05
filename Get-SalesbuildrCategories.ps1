<#
.SYNOPSIS
    Haalt alle SalesBuildr product-categorieën op (GET /public-api/category) en
    print id + name van elke categorie.

.DESCRIPTION
    Haalt alle categorieën op (kale array, geen paginering) en print id + name
    als tabel in de terminal.

.NOTES
    File Name   : Get-SalesbuildrCategories.ps1
    Author      :
    Prerequisite: PowerShell
    Date        : 2026-07-05
#>

[CmdletBinding()]param()

$ErrorActionPreference = 'Stop'

#region ── Inline helpers (identiek aan Sync-Forecasts.ps1) ────────────────────

function Read-XMLConfig {
    param([string]$Path)
    [xml](Get-Content -Path $Path -Encoding UTF8)
}

function Write-Log {
    param(
        [ValidateSet('INFO','WARNING','ERROR')]
        [string]$Level = 'INFO',
        [string]$Message
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$timestamp] [$Level] $Message"
    switch ($Level) {
        'WARNING' { Write-Host $line -ForegroundColor Yellow }
        'ERROR'   { Write-Host $line -ForegroundColor Red }
        default   { Write-Host $line }
    }
}

function Import-DotEnv {
    # Leest een .env-bestand in als hashtable (KEY -> value). Zie Sync-Forecasts.ps1.
    param([string]$Path)

    $vars = @{}
    if (-not (Test-Path $Path)) { return $vars }

    foreach ($line in Get-Content -Path $Path -Encoding UTF8) {
        $trimmed = $line.Trim()
        if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }

        $idx = $trimmed.IndexOf('=')
        if ($idx -lt 1) { continue }

        $key = $trimmed.Substring(0, $idx).Trim()
        $val = $trimmed.Substring($idx + 1).Trim()

        if ($val.Length -ge 2 -and
            (($val[0] -eq '"'  -and $val[-1] -eq '"') -or
             ($val[0] -eq "'"  -and $val[-1] -eq "'"))) {
            $val = $val.Substring(1, $val.Length - 2)
        }

        $vars[$key] = $val
    }

    return $vars
}

#endregion

#region ── SalesBuildr ─────────────────────────────────────────────────────────

function Connect-Salesbuildr {
    # Uri = https://verkoop.promax.nl  (zonder trailing slash, zonder /public-api)
    param(
        [string]$Uri,
        [string]$ApiKey
    )
    $Global:SalesbuildrUri     = $Uri
    $Global:SalesbuildrHeaders = @{ "api-key" = $ApiKey }
}

function Invoke-SalesbuildrRequest {
    # Centrale wrapper voor alle SalesBuildr GET-calls; waarschuwt bij lage rate limit.
    param(
        [string]$Uri,
        [string]$Method = 'Get',
        [string]$Body   = $null
    )

    $params = @{
        Uri     = $Uri
        Headers = $Global:SalesbuildrHeaders
        Method  = $Method
    }
    if ($Body) {
        $params.Body        = $Body
        $params.ContentType = 'application/json'
    }

    $response = Invoke-WebRequest @params

    $remaining = @($response.Headers['X-RateLimit-Remaining'])[0]
    if ($null -ne $remaining -and [int]$remaining -lt 50) {
        Write-Log WARNING "SalesBuildr rate limit bijna bereikt: $remaining / 500 requests resterend in huidig venster"
    }

    return $response.Content | ConvertFrom-Json
}

function Get-SalesbuildrAllCategories {
    # /public-api/category geeft een KALE array terug (geen {results,total}) en kent
    # GEEN paginering — één call haalt alles op.
    $response = Invoke-SalesbuildrRequest -Uri "$($Global:SalesbuildrUri)/public-api/category"

    # LET OP: NIET `if ($response.results)` gebruiken als defensieve check. Bij een kale
    # array triggert `.results` member-enumeratie en levert dat één $null per element op
    # (categorieën hebben geen 'results'-veld); zo'n array is 'truthy' en zou 65 nulls
    # teruggeven i.p.v. de echte objecten. Detecteer daarom expliciet de array-vorm.
    if ($response -is [System.Collections.IEnumerable] -and $response -isnot [string]) {
        $all = $response                       # kale array (het verwachte geval)
    } elseif ($response.PSObject.Properties.Name -contains 'results') {
        $all = $response.results               # {results:[…]} wrapper (defensief)
    } else {
        $all = $response                       # enkel object
    }
    return @($all)
}

#endregion

try {
    $Error.Clear()

    $config = (Read-XMLConfig -Path "$PSScriptRoot\config.xml").configuration

    # Credentials uit .env (plaintext, lokale dev — niet committen). URL uit config.xml.
    $dotenv            = Import-DotEnv -Path "$PSScriptRoot\.env"
    $SalesbuildrApiKey = $dotenv['Salesbuilder_API_Key']
    $SalesbuildrUrl    = $config.salesbuildr.api.url

    if ([string]::IsNullOrWhiteSpace($SalesbuildrApiKey)) {
        throw "Vereiste .env-variabele ontbreekt of is leeg: Salesbuilder_API_Key"
    }

    Connect-Salesbuildr -Uri $SalesbuildrUrl -ApiKey $SalesbuildrApiKey

    Write-Log INFO "Categorieën ophalen via $SalesbuildrUrl/public-api/category ..."
    $categories = Get-SalesbuildrAllCategories
    Write-Log INFO "$(@($categories).Count) categorieën opgehaald"

    # Diagnose: toon het eerste ruwe object zodat we de echte veldnamen zien.
    Write-Host "── RAW eerste categorie ──────────────────────────────"
    @($categories)[0] | ConvertTo-Json -Depth 5 | Write-Host
    Write-Host "──────────────────────────────────────────────────────"

    # Print id + name voor ALLE categorieën
    foreach ($cat in (@($categories) | Sort-Object name)) {
        Write-Host ("{0}`t{1}" -f $cat.id, $cat.name)
    }

} catch {
    Write-Log ERROR "$($_.Exception.Message)"
    Write-Log ERROR "$($_.ScriptStackTrace)"
    exit 1
}
