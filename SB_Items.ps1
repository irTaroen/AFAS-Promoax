<#
.SYNOPSIS
    Haalt alle SalesBuildr-producten op en toont de producten ZONDER mpn.

.DESCRIPTION
    Losse inspectie-/rapportagetool (geen sync). Paginerend via de product-
    search-endpoint (/public-api/product, size/from) worden alle producten
    opgehaald; vervolgens worden de producten met een lege/ontbrekende 'mpn'
    gefilterd en als uitgelijnde lijst geprint. Optioneel met -OutCsv naar CSV.

    Config (SalesBuildr url + apikey) komt plaintext uit configs\config.xml,
    zelfde bestand en conventies als Sync-Forecasts.ps1.

.PARAMETER OutCsv
    Pad naar het CSV-bestand met de mpn-loze producten. Default:
    docs\producten-zonder-mpn.csv (naast het script).

.EXAMPLE
    .\SB_Items.ps1
    .\SB_Items.ps1 -OutCsv .\ergens-anders.csv

.NOTES
    File Name   : SB_Items.ps1
    Date        : 2026-07-07
#>

[CmdletBinding()]
param(
    [string]$OutCsv = "$PSScriptRoot\docs\producten-zonder-mpn.csv"
)

$ErrorActionPreference = 'Stop'

#region ── Inline helpers (zelfde conventies als Sync-Forecasts.ps1) ──────────

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

function Connect-Salesbuildr {
    # Uri = https://[tenant].salesbuildr.com  (zonder trailing slash, zonder /public-api)
    param(
        [string]$Uri,
        [string]$ApiKey
    )
    $Global:SalesbuildrUri     = $Uri
    $Global:SalesbuildrHeaders = @{ "api-key" = $ApiKey }
}

function Invoke-SalesbuildrRequest {
    # Centrale wrapper voor SalesBuildr GET-calls; waarschuwt bij bijna-bereikte
    # rate limit (< 50 van 500/10 min). Geeft het geparseerde response-object terug.
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

function Get-SalesbuildrAllProducts {
    # Haalt ALLE producten op via de product-search-endpoint. Geen vaste page-
    # grootte: we vragen eerst het totaal op en halen daarna alles op in zo min
    # mogelijk calls (size = totaal). Mocht de server 'size' toch begrenzen, dan
    # blijft de do/while doorpagineren tot alles binnen is — we schuiven 'from'
    # op met het WERKELIJK aantal teruggegeven records, niet met een vaste stap.
    # Response bevat { results: [...], total: N }.

    $allResults = @()
    $from       = 0

    # Probe: totaal opvragen met één minimale call.
    $probe = Invoke-SalesbuildrRequest `
        -Uri "$($Global:SalesbuildrUri)/public-api/product?size=1&from=0"
    $total = [int]$probe.total
    if ($total -le 0) { return @() }

    do {
        $response = Invoke-SalesbuildrRequest `
            -Uri "$($Global:SalesbuildrUri)/public-api/product?size=$total&from=$from"

        $batch = @($response.results)
        if ($batch.Count -gt 0) { $allResults += $batch }
        $from += $batch.Count

        Write-Log INFO "  … $($allResults.Count) / $total producten opgehaald"
    } while ($allResults.Count -lt $total -and $batch.Count -gt 0)

    return $allResults
}

#endregion

#region ── Main ───────────────────────────────────────────────────────────────

try {
    $configPath = "$PSScriptRoot\configs\config.xml"
    if (-not (Test-Path $configPath)) {
        throw "Config niet gevonden: $configPath"
    }

    $config         = (Read-XMLConfig -Path $configPath).configuration
    $SalesbuildrUrl = $config.salesbuildr.url
    $SalesbuildrKey = $config.salesbuildr.apikey

    foreach ($entry in @{ 'salesbuildr.url'    = $SalesbuildrUrl
                          'salesbuildr.apikey' = $SalesbuildrKey }.GetEnumerator()) {
        if ([string]::IsNullOrWhiteSpace($entry.Value)) {
            throw "Vereiste config.xml-waarde ontbreekt of is leeg: $($entry.Key)"
        }
    }

    Connect-Salesbuildr -Uri $SalesbuildrUrl -ApiKey $SalesbuildrKey

    Write-Log INFO "=== SalesBuildr producten ophalen (/public-api/product) ==="
    $AllProducts = Get-SalesbuildrAllProducts
    Write-Log INFO "$($AllProducts.Count) producten opgehaald in totaal"

    # Producten zonder mpn (leeg, whitespace of ontbrekend).
    $ZonderMpn = @($AllProducts | Where-Object { [string]::IsNullOrWhiteSpace($_.mpn) })

    Write-Log INFO "$($ZonderMpn.Count) product(en) ZONDER mpn gevonden"

    if ($ZonderMpn.Count -eq 0) {
        Write-Log INFO "Geen producten zonder mpn — niets te tonen."
        return
    }

    # ── Uitgelijnde lijst per product ──
    $Index = 0
    foreach ($Product in $ZonderMpn) {
        $Index++
        $Blok = [System.Text.StringBuilder]::new()
        [void]$Blok.AppendLine("  ┌─ product $Index/$($ZonderMpn.Count) " + ('─' * 40))
        [void]$Blok.AppendLine(("  │ {0,-20} : {1}" -f 'id',                 $Product.id))
        [void]$Blok.AppendLine(("  │ {0,-20} : {1}" -f 'name',               $Product.name))
        [void]$Blok.AppendLine(("  │ {0,-20} : {1}" -f 'mpn',                "(leeg)"))
        [void]$Blok.AppendLine(("  │ {0,-20} : {1}" -f 'category',           $Product.category.name))
        [void]$Blok.AppendLine(("  │ {0,-20} : {1}" -f 'categoryId',         $Product.categoryId))
        [void]$Blok.AppendLine(("  │ {0,-20} : {1}" -f 'productType',        $Product.productType))
        [void]$Blok.AppendLine(("  │ {0,-20} : {1}" -f 'unit',               $Product.unit))
        [void]$Blok.AppendLine(("  │ {0,-20} : {1}" -f 'cost',               $Product.cost))
        [void]$Blok.AppendLine(("  │ {0,-20} : {1}" -f 'price',              $Product.price))
        [void]$Blok.AppendLine(("  │ {0,-20} : {1}" -f 'vendor',             $Product.vendor))
        [void]$Blok.AppendLine(("  │ {0,-20} : {1}" -f 'ean',                $Product.ean))
        [void]$Blok.AppendLine(("  │ {0,-20} : {1}" -f 'externalIdentifier', $Product.externalIdentifier))
        [void]$Blok.Append("  └" + ('─' * 48))
        Write-Log INFO $Blok.ToString()
    }

    # CSV wegschrijven (default: docs\producten-zonder-mpn.csv). Doelmap aanmaken
    # als die nog niet bestaat.
    $OutDir = Split-Path -Parent $OutCsv
    if ($OutDir -and -not (Test-Path $OutDir)) {
        New-Item -ItemType Directory -Path $OutDir | Out-Null
    }
    $ZonderMpn |
        Select-Object id, name, mpn, @{n='category';e={$_.category.name}}, categoryId,
                      productType, unit, cost, price, vendor, ean, externalIdentifier |
        Export-Csv -Path $OutCsv -NoTypeInformation -Encoding UTF8
    Write-Log INFO "Weggeschreven naar CSV: $OutCsv"
}
catch {
    Write-Log ERROR "Fatale fout: $_"
}

#endregion
