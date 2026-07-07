<#
.SYNOPSIS
    Haalt de SalesBuildr-categorieboom op en exporteert de hiërarchie (hoofd- vs
    subcategorie) + cost center id naar een CSV in docs\.

.DESCRIPTION
    Zelfstandig hulpscript. Roept GET /public-api/category/tree aan. Die geeft een
    GENESTE array terug: de items op het buitenste niveau zijn de HOOFDcategorieën
    (parentCategoryId = null), en alles in een 'children'-array valt onder de
    categorie die het bevat. Het script plat die boom recursief (willekeurige diepte)
    en schrijft per categorie weg:
      - Id / Name          : de categorie zelf
      - Level              : 0 = hoofdcategorie, 1 = eronder, enz.
      - IsMainCategory     : True voor een hoofdcategorie (Level 0)
      - ParentId / ParentName        : de DIRECTE bovenliggende categorie
      - MainCategoryId / MainCategoryName : de HOOFDcategorie (root-voorouder) —
                             zo zie je bij elke (sub)categorie meteen onder welke
                             hoofdcategorie hij valt
      - CostCenterId       : category.costCenterId
      - CostCenterName     : (leeg, zie hieronder)

    LET OP: de SalesBuildr public API kent GEEN cost-center-endpoint en de
    CategoryResponseDto bevat alleen 'costCenterId' (een string), geen naam.
    De kolom CostCenterName wordt daarom leeg gelaten. (Bevestigd tegen openapi.json.)

.PARAMETER OutFile
    Pad naar de CSV. Standaard docs\SB-Categorieen-CostCenters.csv naast dit script.

.PARAMETER Delimiter
    CSV-scheidingsteken. Standaard ';' (opent netjes in Excel-NL).

.NOTES
    File Name : SB_Artieklen.ps1
    Date      : 2026-07-07
    Config    : configs\config.xml (zelfde plaintext config als Sync-Forecasts.ps1)
#>

[CmdletBinding()]
param(
    [string]$OutFile   = '',
    [string]$Delimiter = ';'
)

$ErrorActionPreference = 'Stop'

#region ── Inline helpers (gelijk aan Sync-Forecasts.ps1) ─────────────────────

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
    # Centrale wrapper voor SalesBuildr GET-calls die JSON teruggeven.
    param(
        [string]$Uri,
        [string]$Method = 'Get'
    )
    $response  = Invoke-WebRequest -Uri $Uri -Headers $Global:SalesbuildrHeaders -Method $Method
    $remaining = @($response.Headers['X-RateLimit-Remaining'])[0]
    if ($null -ne $remaining -and [int]$remaining -lt 50) {
        Write-Log WARNING "SalesBuildr rate limit bijna bereikt: $remaining / 500 requests resterend in huidig venster"
    }
    return $response.Content | ConvertFrom-Json
}

function Get-SalesbuildrCategoryTree {
    # GET /public-api/category/tree — geneste array: buitenste niveau = hoofdcategorieën,
    # elk met een optionele 'children'-array van subcategorieën (willekeurige diepte).
    return Invoke-SalesbuildrRequest -Uri "$($Global:SalesbuildrUri)/public-api/category/tree"
}

function Expand-CategoryTree {
    # Plat de categorieboom recursief tot losse rijen en propageert bij elke knoop:
    #   - de DIRECTE ouder (ParentId/ParentName)
    #   - de HOOFDcategorie = de root-voorouder (MainCategoryId/MainCategoryName)
    # Level 0 = hoofdcategorie (root); die is zijn eigen hoofdcategorie.
    param(
        $Nodes,
        [string]$ParentId   = $null,
        [string]$ParentName = $null,
        [string]$MainId     = $null,
        [string]$MainName   = $null,
        [int]$Level         = 0
    )

    foreach ($node in $Nodes) {
        # Een root-knoop (Level 0) is zelf de hoofdcategorie; dieper erven we die door.
        $thisMainId   = if ($Level -eq 0) { $node.id }   else { $MainId }
        $thisMainName = if ($Level -eq 0) { $node.name } else { $MainName }

        [pscustomobject]@{
            Id               = $node.id
            Name             = $node.name
            Level            = $Level
            IsMainCategory   = ($Level -eq 0)
            ParentId         = $ParentId
            ParentName       = $ParentName
            MainCategoryId   = $thisMainId
            MainCategoryName = $thisMainName
            CostCenterId     = $node.costCenterId
            CostCenterName   = ''   # niet beschikbaar via de SB public API
        }

        if ($node.children) {
            Expand-CategoryTree -Nodes $node.children `
                -ParentId $node.id -ParentName $node.name `
                -MainId   $thisMainId -MainName $thisMainName `
                -Level    ($Level + 1)
        }
    }
}

#endregion

#region ── Hoofd-logica ───────────────────────────────────────────────────────

try {
    $config = (Read-XMLConfig -Path "$PSScriptRoot\configs\config.xml").configuration

    $SalesbuildrApiKey = $config.salesbuildr.apikey
    $SalesbuildrUrl    = $config.salesbuildr.url

    foreach ($entry in @{ 'salesbuildr.apikey' = $SalesbuildrApiKey
                          'salesbuildr.url'    = $SalesbuildrUrl }.GetEnumerator()) {
        if ([string]::IsNullOrWhiteSpace($entry.Value)) {
            throw "Vereiste config.xml-waarde ontbreekt of is leeg: $($entry.Key)"
        }
    }

    Connect-Salesbuildr -Uri $SalesbuildrUrl -ApiKey $SalesbuildrApiKey

    if ([string]::IsNullOrWhiteSpace($OutFile)) {
        $OutFile = "$PSScriptRoot\docs\SB-Categorieen-CostCenters.csv"
    }
    $OutDir = Split-Path -Parent $OutFile
    if ($OutDir -and -not (Test-Path $OutDir)) {
        New-Item -ItemType Directory -Path $OutDir | Out-Null
    }

    Write-Log INFO "=== SalesBuildr-categorieboom ophalen (/public-api/category/tree) ==="

    $Tree = @(Get-SalesbuildrCategoryTree)
    Write-Log INFO "$($Tree.Count) hoofdcategorie(ën) op het bovenste niveau"

    # Boom platslaan tot losse rijen met hiërarchie-info.
    $Rows = @(Expand-CategoryTree -Nodes $Tree)

    $HoofdAantal = @($Rows | Where-Object { $_.IsMainCategory }).Count
    $SubAantal   = $Rows.Count - $HoofdAantal
    Write-Log INFO "$($Rows.Count) categorie(ën) totaal: $HoofdAantal hoofd, $SubAantal sub"

    # SalesBuildr levert geen cost-center-naam; die kolom blijft leeg (zie header).
    $zonderCostCenter = @($Rows | Where-Object { [string]::IsNullOrWhiteSpace($_.CostCenterId) }).Count
    if ($zonderCostCenter -gt 0) {
        Write-Log WARNING "$zonderCostCenter categorie(ën) hebben geen costCenterId"
    }
    Write-Log WARNING "CostCenterName blijft leeg — de SalesBuildr public API kent geen cost-center-endpoint/naam"

    # Sorteer op hoofdcategorie, dan diepte, dan naam: leest als een uitgeklapte boom.
    $Rows |
        Sort-Object MainCategoryName, Level, Name |
        Export-Csv -Path $OutFile -Delimiter $Delimiter -NoTypeInformation -Encoding UTF8

    Write-Log INFO "=== Klaar: $($Rows.Count) rij(en) weggeschreven naar $OutFile ==="

} catch {
    Write-Log ERROR "Fatale fout: $_"
}

#endregion
