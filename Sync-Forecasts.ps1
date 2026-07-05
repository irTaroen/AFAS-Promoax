<#
.SYNOPSIS
    Synchroniseert AFAS Profit Forecasts naar SalesBuildr als Opportunities,
    en verwerkt gesloten Opportunities terug naar AFAS als Voorcalculatieregels.

.DESCRIPTION
    Flow 1: Gewijzigde Forecasts in AFAS → Upsert als Opportunity in SalesBuildr
            (gesloten Opportunities worden overgeslagen)

    Flow 2: Gesloten Opportunities in SalesBuildr → Voorcalculatieregel aanmaken in AFAS
            - Quotation-regels worden als Voorcalculatieregel-regels toegevoegd
            - Ontbrekende Artikels worden eerst aangemaakt in AFAS
            - Idempotentie via external ID check in AFAS

.NOTES
    File Name   : Sync-Afas2Salesbuildr-Forecasts.ps1
    Author      :
    Prerequisite: PowerShell
    Date        : 2026-07-01

    RELEASES
        v0.1 [2026-07-01] : Initieel skeleton
        v0.2 [2026-07-01] : AFAS connector veldnamen ingevuld nav AFAS_API_Guide.md
#>

[CmdletBinding()]param()

$ErrorActionPreference = 'Stop'

#region ── Inline helpers ────────────────────────────────────────────────────

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
    # Leest een .env-bestand in als hashtable (KEY -> value).
    # Splitst op het eerste '='; trimt spaties rond sleutel en waarde
    # (het .env-bestand gebruikt bijv. 'AFAS_Omgeving = 53307'); negeert
    # lege regels en #-commentaar; strippt omringende quotes.
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

#region ── AFAS ──────────────────────────────────────────────────────────────

function Connect-Afas {
    # Mode 'TEST' gebruikt de AFAS test-omgeving (resttest.afas.online),
    # anders de productie-omgeving (rest.afas.online).
    param(
        [string]$Omgeving,
        [string]$ApiToken,
        [string]$Mode = 'PROD'
    )
    $subdomain          = if ($Mode -eq 'TEST') { 'resttest' } else { 'rest' }
    $Global:AfasRestUrl = "https://$($Omgeving).$subdomain.afas.online/profitrestservices"
    $encoded            = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($ApiToken))
    $Global:AfasHeaders = @{ Authorization = "AfasToken $encoded" }
}

function Invoke-AfasGetConnector {
    param([string]$Connector)

    $result = @()
    $skip   = 0
    $take   = 100
    do {
        $url      = "$($Global:AfasRestUrl)/connectors/$($Connector)?skip=$skip&take=$take"
        $response = Invoke-RestMethod -Uri $url -Headers $Global:AfasHeaders -Method Get
        $result  += $response.rows
        $skip    += $take
    } while ($response.rows.Count -eq $take)

    return $result
}

function Invoke-AfasGetConnectorFiltered {
    # Haalt AFAS-records op gefilterd op gewijzigd > $SinceDate via server-side filter.
    # Operator 4 = groter dan (>); veld 'gewijzigd' bevestigd in Salesbuildr_Forecasts.
    # (AFAS operatortypes: 1==, 2>=, 3<=, 4>, 5<, 6 contains, 7!=. LET OP: 5 is
    #  KLEINER dan, niet groter — daarom faalde de delta eerst met operator 5.)
    # LET OP datumformaat: AFAS accepteert 'yyyy-MM-ddTHH:mm(:ss)' in LOKALE tijd.
    # Een trailing 'Z' (UTC-aanduiding) veroorzaakt een serverfout ("0Z" -> Integer),
    # en een datum zónder tijdcomponent faalt eveneens. Dus GEEN ToUniversalTime en GEEN 'Z'.
    param(
        [string]$Connector,
        [datetime]$SinceDate
    )

    $result   = @()
    $skip     = 0
    $take     = 100
    $sinceStr = $SinceDate.ToString("yyyy-MM-ddTHH:mm:ss")

    do {
        $url      = "$($Global:AfasRestUrl)/connectors/$($Connector)?skip=$skip&take=$take" +
                    "&filterfieldids=gewijzigd&filtervalues=$([uri]::EscapeDataString($sinceStr))&operatortypes=4"
        $response = Invoke-RestMethod -Uri $url -Headers $Global:AfasHeaders -Method Get
        $result  += $response.rows
        $skip    += $take
    } while ($response.rows.Count -eq $take)

    return $result
}

function Get-AfasRecordByExternalId {
    # Controleert of een Voorcalculatie al bestaat in AFAS door te filteren op offerte (QuId).
    # Bevestigd filterveld: 'offerte' in Salesbuildr_Voorcalculatie (operatortypes=1 = equal).
    # Geeft het eerste gevonden record terug, of $null als het niet bestaat.
    param(
        [string]$Connector,
        [string]$ExternalId    # QuId = AFAS forecast-id, bijv. "11310"
    )

    $url      = "$($Global:AfasRestUrl)/connectors/$($Connector)" +
                "?skip=0&take=1&filterfieldids=offerte&filtervalues=$([uri]::EscapeDataString($ExternalId))&operatortypes=1"
    $response = Invoke-RestMethod -Uri $url -Headers $Global:AfasHeaders -Method Get

    if ($response.rows.Count -gt 0) { return $response.rows[0] }
    return $null
}

function Get-AfasForecastBySqNo {
    # Haalt één Forecast-record op via het volgnummer (forecast/SqNo).
    # Nodig in Flow 2 om de verkooprelatie (= PrId/DbId) te achterhalen; die zit
    # NIET op de SalesBuildr Opportunity (companyExtId = organisatienummer).
    # operatortypes=1 = equal. Geeft $null als de Forecast niet bestaat.
    param(
        [string]$Connector,
        [int]$SqNo
    )

    $url      = "$($Global:AfasRestUrl)/connectors/$($Connector)" +
                "?filterfieldids=forecast&filtervalues=$SqNo&operatortypes=1&skip=0&take=1&orderbyfieldids=forecast"
    $response = Invoke-RestMethod -Uri $url -Headers $Global:AfasHeaders -Method Get

    if ($response.rows.Count -gt 0) { return $response.rows[0] }
    return $null
}

function Invoke-AfasUpdateConnector {
    # POST (insert) of PUT (update) naar een AFAS UpdateConnector
    param(
        [string]$Connector,
        [hashtable]$Body,
        [string]$Method = 'Post'
    )

    $url  = "$($Global:AfasRestUrl)/connectors/$($Connector)"
    $json = $Body | ConvertTo-Json -Depth 10
    return Invoke-RestMethod -Uri $url -Headers $Global:AfasHeaders -Method $Method `
        -Body $json -ContentType "application/json"
}

function New-AfasArtikel {
    # Maakt een minimaal Artikel aan in AFAS via UpdateConnector FbItemArticle.
    # VaTp "0" = standaard artikel, BiSt false = geen voorraad bijhouden.
    # Grp = artikelgroep (verplicht: elk artikel hoort bij een groep) — bepaald
    # uit de Salesbuildr-categorie via de mapping in config.xml.
    param(
        [string]$Connector,
        [string]$ItemCode,
        [string]$Omschrijving,
        [string]$Artikelgroep
    )

    $body = @{
        FbItemArticle = @{
            Element = @{
                Fields = @{
                    ItCd    = $ItemCode
                    Ds      = $Omschrijving
                    Ds_1043 = $Omschrijving
                    Grp     = $Artikelgroep
                    VaTp    = "0"
                    BiSt    = $false
                    CoLa    = "NL"
                    Bl      = $false
                }
            }
        }
    }

    Write-Log INFO "Artikel aanmaken in AFAS: $ItemCode - $Omschrijving (artikelgroep $Artikelgroep)"
    Invoke-AfasUpdateConnector -Connector $Connector -Body $body
}

function Get-AfasArtikelgroep {
    # Vertaalt een Salesbuildr-productcategorie naar een AFAS artikelgroep (Grp) in
    # twee stappen, want de cost center staat NIET op de quote-regel/category-inline:
    #   1) category.id  -> costCenterId   (via CategoryCostCenterMap, uit /public-api/category)
    #   2) costCenterId -> Grp            (via ArtikelgroepMap, uit config.xml)
    # Geeft $null als de categorie ontbreekt, geen cost center heeft, of die cost
    # center niet in de config-mapping staat — de aanroeper slaat het artikel dan
    # over met een WARNING (zie Flow 2 stap 2a).
    param(
        $Category,                             # SB category-object ({ id, name, ... }) of $null
        [hashtable]$CategoryCostCenterMap,     # category.id  -> costCenterId
        [hashtable]$ArtikelgroepMap            # costCenterId -> Grp
    )

    if ($null -eq $Category -or [string]::IsNullOrWhiteSpace($Category.id)) { return $null }
    if (-not $CategoryCostCenterMap.ContainsKey($Category.id))              { return $null }

    $costCenterId = $CategoryCostCenterMap[$Category.id]
    if ([string]::IsNullOrWhiteSpace($costCenterId))                        { return $null }
    if ($ArtikelgroepMap.ContainsKey($costCenterId)) { return $ArtikelgroepMap[$costCenterId] }
    return $null
}

function Close-AfasForecast {
    # Sluit een Forecast via PUT op CmForecast, met de verkoopstatus (ViOp):
    #   G = Gewonnen (Won)  — opportunity closed én primaire quote 'approved'
    #   N = Verloren (Lost) — opportunity closed maar geen/niet-goedgekeurde quote
    #
    # De samengestelde primaire sleutel PrId (verkooprelatie) + SqNo (volgnummer)
    # identificeert het bestaande record en gaat daarom als @-attributen op het
    # Element-niveau staan (@PrId/@SqNo), NIET in Fields.
    #
    # Vaste velden:
    #   ViRe = "00" (altijd), DaSc = sluitdatum (voorlopig huidige datum).
    #   OrAF = totale offertebedrag — ALLEEN bij Won (G); bij Lost (N) weggelaten.
    param(
        [string]$Connector,
        [string]$PrId,                        # verkooprelatie / debtor code (CmForecast.@PrId)
        [int]$SqNo,                           # volgnummer / sequence number (CmForecast.@SqNo)
        [ValidateSet("G","N")][string]$ViOp,  # verkoopstatus: G = Gewonnen, N = Verloren
        [decimal]$OrAF = 0                     # totale offertebedrag (alleen relevant bij G)
    )

    $fields = @{
        ViOp = $ViOp
        ViRe = "00"
        DaSc = (Get-Date -Format "yyyy-MM-dd")
    }
    if ($ViOp -eq "G") { $fields.OrAF = $OrAF }

    $body = @{
        CmForecast = @{
            Element = @{
                "@PrId" = $PrId
                "@SqNo" = $SqNo
                Fields  = $fields
            }
        }
    }

    Write-Log INFO "Forecast sluiten in AFAS: $PrId / SqNo $SqNo (ViOp=$ViOp$(if ($ViOp -eq 'G') { ", OrAF=$OrAF" }))"
    Invoke-AfasUpdateConnector -Connector $Connector -Body $body -Method 'Put'
}

function New-AfasVoorcalculatie {
    # Maakt een KnQuotation (voorcalculatie) aan in AFAS, inclusief regels.
    # QuId = het unieke AFAS forecast-id (bijv. "11310"), tevens idempotentiesleutel
    #        (offerte in Salesbuildr_Voorcalculatie); prefix evt. later (max 21 chars).
    # FcNo koppelt de quotatie terug aan de originating Forecast (CmForecast.SqNo = volgnummer).
    # KnQuotationLine velden: ItCd (itemcode), Qu (aantal), UP (eenheidsprijs).
    param(
        [string]$Connector,
        [string]$QuId,        # offerte-nummer = AFAS forecast-id, bijv. "11310"
        [string]$DbId,        # verkooprelatie / debtor code (= AFAS PrId)
        [string]$Omschrijving,
        [int]$FcNo,           # forecast volgnummer (CmForecast.SqNo)
        [array]$Regels        # array van hashtables met ItemCode, Aantal, Prijs
    )

    $lines = $Regels | ForEach-Object {
        @{
            Fields = @{
                ItCd = $_.ItemCode
                Qu   = $_.Aantal
                UP   = $_.Prijs
            }
        }
    }

    $body = @{
        KnQuotation = @{
            Element = @{
                Fields = @{
                    QuId  = $QuId
                    DbId  = $DbId
                    QuDa  = (Get-Date -Format "yyyy-MM-dd")
                    Ds    = $Omschrijving
                    CuId  = "EUR"
                    FcNo  = $FcNo
                }
                Objects = @{
                    KnQuotationLine = @{
                        Element = $lines
                    }
                }
            }
        }
    }

    Write-Log INFO "Voorcalculatie aanmaken in AFAS: $QuId (Forecast SqNo: $FcNo)"
    Invoke-AfasUpdateConnector -Connector $Connector -Body $body
}

#endregion

#region ── SalesBuildr ────────────────────────────────────────────────────────

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
    # Centrale wrapper voor alle SalesBuildr GET-calls.
    # Logt een waarschuwing als de rate limit bijna bereikt is (< 50 van 500/10 min).
    # Geeft het geparseerde response-object terug.
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

    # In PowerShell 7 geeft $response.Headers[...] een string[] terug (niet één string),
    # dus pak het eerste element voordat we naar int casten.
    $remaining = @($response.Headers['X-RateLimit-Remaining'])[0]
    if ($null -ne $remaining -and [int]$remaining -lt 50) {
        Write-Log WARNING "SalesBuildr rate limit bijna bereikt: $remaining / 500 requests resterend in huidig venster"
    }

    return $response.Content | ConvertFrom-Json
}

function Get-SalesbuildrClosedOpportunities {
    # Haalt alle Opportunities met statusId 'closed' op via paginering (size/from)
    # en filtert client-side op sluitingsdatum closedAt > $SinceDate.
    #
    # LET OP — geen server-side datumfilter mogelijk: de SalesBuildr search-API
    # kent alleen gelijkheidsfilters ('veld:waarde', meerdere waarden met '|'),
    # geen >/< operatoren. Vandaar het server-side statusId:closed-filter + een
    # client-side datumfilter. 'closedAt' is de sluitingsdatum (niet 'updatedAt',
    # dat bij élke wijziging verspringt); records zonder closedAt worden overgeslagen.
    # Paginering: bevestigd via OpenAPI — parameters zijn 'size' en 'from'.
    param([datetime]$SinceDate)

    $allResults = @()
    $size       = 100
    $from       = 0

    do {
        $response = Invoke-SalesbuildrRequest `
            -Uri "$($Global:SalesbuildrUri)/public-api/opportunity?filters=statusId%3Aclosed&size=$size&from=$from"

        $allResults += $response.results
        $from       += $size
    } while ($allResults.Count -lt $response.total)

    # Client-side datumfilter op de sluitingsdatum 'closedAt' (OpportunityResponseDto).
    # Cast naar [datetime] zodat de vergelijking niet afhangt van het string-formaat.
    return $allResults | Where-Object { $_.closedAt -and ([datetime]$_.closedAt) -gt $SinceDate }
}

function Get-SalesbuildrCompanyByExtId {
    # Controleert of een Company bestaat in SalesBuildr via external ID.
    # De org-sync (Sync-Afas2Salesbuildr.ps1) schrijft companies weg als
    # externalIdentifier = "afas-Organisatie-{AFAS Organisatienummer}".
    # Geeft $null terug bij 404 (company nog niet gesynchroniseerd).
    param([string]$ExternalId)

    try {
        return Invoke-SalesbuildrRequest `
            -Uri "$($Global:SalesbuildrUri)/public-api/company/ext/$ExternalId"
    } catch {
        if ($_.Exception.Response.StatusCode -eq 404) { return $null }
        throw
    }
}

function Get-SalesbuildrOpportunityByExtId {
    # Haalt een Opportunity op via external ID (voor de 'skip if Closed' check in Flow 1).
    # Geeft $null terug bij 404 (opportunity bestaat nog niet).
    param([string]$ExternalId)

    try {
        return Invoke-SalesbuildrRequest `
            -Uri "$($Global:SalesbuildrUri)/public-api/opportunity/ext/$ExternalId"
    } catch {
        if ($_.Exception.Response.StatusCode -eq 404) { return $null }
        throw
    }
}

function Get-SalesbuildrContactByEmail {
    # Zoekt een Contact in SalesBuildr op e-mailadres.
    # De /public-api/contact search-endpoint accepteert een vrije-tekst 'query'
    # parameter; die kan ook op andere velden matchen, dus filteren we het
    # resultaat client-side op een exacte (case-insensitieve) match van 'email'.
    # Geeft de ContactResponseDto terug, of $null als er geen exacte match is.
    #
    # LET OP: dit werkt alleen voor de KLANT-contactpersoon (contactId/contactExtId
    # op de Opportunity). De verantwoordelijke (owner) is een SalesBuildr *user*,
    # geen Contact — die is NIET via deze endpoint op te zoeken.
    param([string]$Email)

    if ([string]::IsNullOrWhiteSpace($Email)) { return $null }

    $encoded  = [uri]::EscapeDataString($Email)
    $response = Invoke-SalesbuildrRequest `
        -Uri "$($Global:SalesbuildrUri)/public-api/contact?query=$encoded&size=100"

    # De search-endpoint kan zowel een kale array als een {results:[]} object geven.
    $contacts = if ($response.results) { $response.results } else { $response }

    return $contacts | Where-Object { $_.email -and $_.email.ToLower() -eq $Email.ToLower() } |
        Select-Object -First 1
}

function Get-SalesbuildrAllCategories {
    # Haalt alle product-categorieën op en cachet ze in $Global:SalesbuildrCategoriesCache.
    # Nodig omdat de cost center (costCenterId) NIET op de quote-regel of het inline
    # category-object staat, maar op de volledige Category-resource (CategoryResponseDto).
    # LET OP: /public-api/category geeft een KALE array terug (geen {results,total})
    # en kent GEEN paginering — één call haalt alles op.
    if ($null -ne $Global:SalesbuildrCategoriesCache) { return $Global:SalesbuildrCategoriesCache }

    $response = Invoke-SalesbuildrRequest -Uri "$($Global:SalesbuildrUri)/public-api/category"
    $all = if ($response.results) { $response.results } else { $response }   # defensief

    Write-Log INFO "$(@($all).Count) categorieën opgehaald en gecachet voor cost-center-koppeling"
    $Global:SalesbuildrCategoriesCache = @($all)
    return $Global:SalesbuildrCategoriesCache
}

function Get-SalesbuildrPrimaryQuote {
    # Haalt de PRIMAIRE Quote (primary:true) op voor een Opportunity, of $null.
    # De aanroeper bepaalt Won/Lost op basis van $quote.status -eq 'approved'.
    # OpportunityResponseDto bevat GEEN quoteId, dus filteren we de quote-endpoint
    # server-side op de opportunity. LET OP: de filter-sleutel is 'opportunity.id'
    # (niet 'opportunityId' — die geeft altijd total=0). Formaat van de filters-param:
    #   filters=opportunity.id:{id}   (dubbele punt URL-encoded als %3A)
    # Bevestigde veldnamen (QuoteResponseDto):
    #   - opportunity : { id, name, ... } — koppeling naar de Opportunity
    #   - items       : array van QuoteItemResponseDto (NIET 'lines')
    #   - primary     : boolean, true voor de primaire quote van díe opportunity
    #   - status      : string (quote-status, bijv. 'approved')
    # Bevestigde veldnamen per item (QuoteItemResponseDto):
    #   - name      : productnaam
    #   - quantity  : aantal
    #   - price     : eenheidsprijs (NIET 'unitPrice')
    #   - product   : { id, name, externalIdentifier } — extern ID voor AFAS-koppeling
    #   - unit      : eenheid
    #   - mpn       : fabrikantcode
    param([string]$OpportunityId)

    $response = Invoke-SalesbuildrRequest `
        -Uri "$($Global:SalesbuildrUri)/public-api/quote?filters=opportunity.id%3A$OpportunityId&size=100"
    $quotes = $response.results

    # GEEN fallback naar een willekeurige goedgekeurde quote: de Won/Lost-bepaling
    # hangt strikt af van de status van de PRIMAIRE quote (primary:true). Een
    # goedgekeurde niet-primaire quote zou een Lost-opportunity ten onrechte als
    # Won classificeren, dus we geven uitsluitend de primary:true quote terug (of $null).
    return $quotes | Where-Object { $_.primary -eq $true } | Select-Object -First 1
}

function Get-SalesbuildrQuoteTotal {
    # Berekent het totale offertebedrag (CmForecast.OrAF): som over de regels van
    # price * quantity * (1 - discount). De QuoteResponseDto heeft GEEN kant-en-klaar
    # totaalveld, daarom sommeren we zelf. Bevestigde velden per QuoteItemResponseDto:
    #   price    = bruto eenheidsprijs (vóór regelkorting)
    #   quantity = aantal
    #   discount = regelkorting als DECIMALE FRACTIE (0.12 = 12%, 0.5 = 50%);
    #              waarden rond 0 (bijv. -1e-6) zijn afrondingsruis en tellen als geen korting.
    # LET OP: negeert setup-kosten (setupPrice) en een eventuele quote-brede korting
    # (quote.discount is in de praktijk altijd leeg); alleen regelkortingen tellen mee.
    param([array]$Items)

    $total = [decimal]0
    foreach ($item in $Items) {
        $price    = if ($null -ne $item.price)    { [decimal]$item.price }    else { [decimal]0 }
        $quantity = if ($null -ne $item.quantity) { [decimal]$item.quantity } else { [decimal]0 }
        $discount = if ($null -ne $item.discount) { [decimal]$item.discount } else { [decimal]0 }
        $total   += $price * $quantity * (1 - $discount)
    }
    return $total
}

function Invoke-SalesbuildrUpsertOpportunity {
    # Upsert een Opportunity via external ID.
    # Endpoint: PUT /public-api/opportunity/ext/{externalIdentifier}  (bevestigd via API guide)
    param(
        [string]$ExternalId,
        [hashtable]$Body
    )

    $json = $Body | ConvertTo-Json -Depth 5
    return Invoke-SalesbuildrRequest `
        -Uri    "$($Global:SalesbuildrUri)/public-api/opportunity/ext/$ExternalId" `
        -Method 'Put' `
        -Body   $json
}

#endregion

#region ── Hoofd-logica ───────────────────────────────────────────────────────

try {
    $Error.Clear()

    $config = (Read-XMLConfig -Path "$PSScriptRoot\config.xml").configuration

    If (-Not (Test-Path "$PSScriptRoot\work")) {
        New-Item -ItemType Directory -Path "$PSScriptRoot\work" | Out-Null
    }

    # State files
    $ForecastStateFile     = "$PSScriptRoot\work\LastForecastSyncDate.xml"
    $OpportunityStateFile  = "$PSScriptRoot\work\LastSyncDate_Opportunities.xml"

    $Epoch = Get-Date -Date "1-1-1970"

    $LastForecastSync    = If (Test-Path $ForecastStateFile)    { Import-Clixml $ForecastStateFile }    Else { $Epoch }
    $LastOpportunitySync = If (Test-Path $OpportunityStateFile) { Import-Clixml $OpportunityStateFile } Else { $Epoch }

    # Credentials & omgeving uit .env (plaintext, lokale dev — niet committen).
    # De .env levert AFAS-omgeving + token, Salesbuildr API-key en tenant.
    # Connector-namen en de Salesbuildr-URL blijven uit config.xml komen.
    $dotenv = Import-DotEnv -Path "$PSScriptRoot\.env"

    # De decoded token (het <token>…</token> XML) is nodig; Connect-Afas
    # base64-encodeert die zelf. MODE=TEST schakelt naar resttest.afas.online.
    $Mode              = $dotenv['MODE']
    $AfasOmgeving      = $dotenv['AFAS_omgeving']
    $AfasApiToken      = $dotenv['AFAS_token_decoded']
    $SalesbuildrApiKey = $dotenv['Salesbuilder_API_Key']
    $SalesbuildrUrl    = $config.salesbuildr.api.url

    foreach ($k in @('AFAS_omgeving','AFAS_token_decoded','Salesbuilder_API_Key')) {
        if ([string]::IsNullOrWhiteSpace($dotenv[$k])) {
            throw "Vereiste .env-variabele ontbreekt of is leeg: $k"
        }
    }

    Connect-Afas        -Omgeving $AfasOmgeving -ApiToken $AfasApiToken -Mode $Mode
    Connect-Salesbuildr -Uri $SalesbuildrUrl -ApiKey $SalesbuildrApiKey

    # AFAS connector namen uit config
    $ConnForecastGet    = $config.afas.connectors.forecasts_get        # Salesbuildr_Forecasts
    $ConnForecastUpdate = $config.afas.connectors.forecasts_update     # CmForecast
    $ConnArtikelenGet   = $config.afas.connectors.artikelen_get        # Salesbuildr_Artikelen
    $ConnArtikelenUpdate = $config.afas.connectors.artikelen_update    # FbItemArticle
    $ConnVoorcalcGet    = $config.afas.connectors.voorcalculatie_get   # Salesbuildr_Voorcalculatie
    $ConnVoorcalcUpdate = $config.afas.connectors.voorcalculatie_update # KnQuotation

    # Mapping Salesbuildr cost center (costCenterId) -> AFAS artikelgroep (Grp), uit
    # config.xml. Gebruikt in Flow 2 stap 2a bij het aanmaken van ontbrekende artikels.
    $ArtikelgroepMap = @{}
    foreach ($c in $config.afas.artikelgroepmapping.costcenter) {
        if ($c -and -not [string]::IsNullOrWhiteSpace($c.id)) { $ArtikelgroepMap[$c.id] = $c.grp }
    }
    Write-Log INFO "$($ArtikelgroepMap.Count) artikelgroep-mapping(s) (cost center -> Grp) geladen uit config"


    ####################################################################
    # FLOW 1 — AFAS Forecasts → SalesBuildr Opportunities
    ####################################################################

    # Write-Log INFO "=== Flow 1: AFAS Forecasts → SalesBuildr Opportunities ==="
    # Write-Log INFO "Delta sinds: $LastForecastSync"

    # $AfasForecasts = Invoke-AfasGetConnectorFiltered `
    #     -Connector $ConnForecastGet `
    #     -SinceDate $LastForecastSync

    # Write-Log INFO "$($AfasForecasts.Count) gewijzigde Forecasts gevonden"

    # # Batch-watermark: alleen als élke Forecast succesvol is verwerkt (of legitiem
    # # overgeslagen omdat al gesloten) schuift de sync-datum op. Overgeslagen door een
    # # ontbrekende organisatie of een fout -> datum blijft staan, zodat de volgende run
    # # het opnieuw probeert. Aanname: fouten worden binnen 48u opgelost (zie email-log).
    # $Flow1Complete = $true

    # foreach ($Forecast in $AfasForecasts) {

    #     # Print de opgehaalde Forecast in de terminal
    #     $Forecast | Format-List | Out-String | Write-Host

    #     # Bevestigde veldnamen (Salesbuildr_Forecasts GetConnector):
    #     # 'forecast'       = uniek AFAS forecast-id -> gebruikt als QuId (voorcalc-offertenr)
    #     # 'volgnummer'     = CmForecast SqNo (@SqNo)  ← de updatesleutel
    #     # 'verkooprelatie' = AFAS debiteurcode (= PrId/@PrId in CmForecast) — NIET voor companyExtId
    #     # 'organisatie'    = AFAS Organisatienummer -> koppeling naar SB Company
    #     # 'forecastOmschrijving' = naam
    #     #
    #     # De externalIdentifier codeert alles wat Flow 2 nodig heeft om ZONDER re-fetch
    #     # verder te kunnen: forecast-id (QuId) + volgnummer (@SqNo) + verkooprelatie (@PrId).
    #     # Formaat: afas-Forecast-{forecast}-{volgnummer}-{verkooprelatie}.
    #     $ExternalId = "afas-Forecast-$($Forecast.forecast)-$($Forecast.volgnummer)-$($Forecast.verkooprelatie)"

    #     # Company-koppeling: de org-sync schrijft companies weg als
    #     # "afas-Organisatie-{organisatienummer}". Dit is dezelfde sleutel.
    #     $CompanyExtId = "afas-Organisatie-$($Forecast.organisatie)"

    #     # Print de CompanyExtId
    #     Write-Log INFO "[$($Forecast.forecastOmschrijving)] CompanyExtId: $CompanyExtId"


    #     # Controleer of de Company bestaat in SalesBuildr. Zo niet, dan is de
    #     # organisatie (nog) niet gesynchroniseerd -> loggen en overslaan.
    #     # TODO: deze waarschuwingen ook opnemen in de notificatie-email (zie Roadmap).
    #     $Company = Get-SalesbuildrCompanyByExtId -ExternalId $CompanyExtId
    #     If ($null -eq $Company) {
    #         Write-Log WARNING "[$($Forecast.forecastOmschrijving)] Organisatie $($Forecast.organisatie) niet gevonden in SalesBuildr ($CompanyExtId) — Forecast overgeslagen"
    #         $Flow1Complete = $false
    #         continue
    #     }
    #     Write-Log INFO "[$($Forecast.forecastOmschrijving)] Company bestaat al in SalesBuildr ($CompanyExtId)"

    #     # Sla over als de Opportunity al gesloten is in SalesBuildr
    #     $ExistingOpportunity = Get-SalesbuildrOpportunityByExtId -ExternalId $ExternalId
    #     If ($null -ne $ExistingOpportunity -and $ExistingOpportunity.statusId -eq "closed") {
    #         Write-Log INFO "[$($Forecast.forecastOmschrijving)] Opportunity al gesloten in SalesBuildr ($ExternalId) — overgeslagen"
    #         continue
    #     }

    #     # Klant-contactpersoon: opzoeken in SalesBuildr op e-mailadres.
    #     # 'contactpersoonMail' is de veldnaam uit de Salesbuildr_Forecasts GetConnector.
    #     # Contact is optioneel: geen match -> waarschuwen en Opportunity zónder
    #     # contact upserten (Forecast wordt NIET overgeslagen).
    #     $ContactId = $null
    #     $ContactEmail = $Forecast.contactpersoonMail
    #     if (-not [string]::IsNullOrWhiteSpace($ContactEmail)) {
    #         $Contact = Get-SalesbuildrContactByEmail -Email $ContactEmail
    #         if ($null -ne $Contact) {
    #             $ContactId = $Contact.id
    #             Write-Log INFO "[$($Forecast.forecastOmschrijving)] Contact gevonden op $ContactEmail (id: $ContactId)"
    #         } else {
    #             Write-Log WARNING "[$($Forecast.forecastOmschrijving)] Geen SalesBuildr-contact gevonden op e-mail '$ContactEmail' — Opportunity wordt zonder contact opgeslagen"
    #         }
    #     }

    #     $SalesbuildrOpportunity = @{
    #         # externalIdentifier wordt meegegeven via de URL, NIET in de body (UpsertOpportunityDto)
    #         name           = $Forecast.forecastOmschrijving
    #         companyExtId   = $CompanyExtId
    #         probability    = $Forecast.scoringkans
    #         onetimeRevenue = $Forecast.bedragVerwacht
    #         # Owner (verantwoordelijke) is VERPLICHT bij de opportunity-upsert
    #         # ("Either ownerId or ownerExtId is required"). De owner is een SalesBuildr
    #         # *user*; de GetConnector levert diens interne SalesBuildr user-id direct
    #         # aan in 'verantwoordelijkeOwnerID', dus koppelen we op ownerId.
    #         ownerId        = $Forecast.verantwoordelijkeOwnerID
    #     }
    #     if ($null -ne $ContactId) {
    #         $SalesbuildrOpportunity.contactId = $ContactId
    #     }
    #     if ($null -ne $Forecast.einddatumVerwacht) {
    #         $SalesbuildrOpportunity.expectedCloseDate = ([datetime]$Forecast.einddatumVerwacht).ToString("yyyy-MM-dd")
    #     }

    #     Write-Log INFO "Opportunity upsert in SalesBuildr: $($Forecast.forecastOmschrijving)"

    #     # Payload printen i.p.v. versturen (dry-run). Zelfde serialisatie als de echte call.
    #     Write-Log INFO "PUT /public-api/opportunity/ext/$ExternalId"
    #     Write-Host ($SalesbuildrOpportunity | ConvertTo-Json -Depth 5)

    #     try {
    #         Invoke-SalesbuildrUpsertOpportunity -ExternalId $ExternalId -Body $SalesbuildrOpportunity
    #     } catch {
    #         Write-Log ERROR "[$($Forecast.forecastOmschrijving)] Fout bij upsert Opportunity: $_"
    #         $Flow1Complete = $false
    #     }
    # }
    


    ####################################################################
    # FLOW 2 — Gesloten SalesBuildr Opportunities → AFAS Voorcalculatieregels
    ####################################################################

    Write-Log INFO "=== Flow 2: Gesloten Opportunities → AFAS Voorcalculatieregels ==="
    Write-Log INFO "Delta sinds: $LastOpportunitySync"

    $ClosedOpportunities = Get-SalesbuildrClosedOpportunities -SinceDate $LastOpportunitySync

    Write-Log INFO "$($ClosedOpportunities.Count) gesloten Opportunities gevonden"

    # Print de opgehaalde Opportunities in de terminal (debug / dry-run inspectie)
    foreach ($Opportunity in $ClosedOpportunities) {
        $Opportunity | Format-List | Out-String | Write-Host
    }

    # Batch-watermark voor Flow 2 (zie toelichting bij Flow 1).
    $Flow2Complete = $true

    # ── Stap 2a: Categoriseer elke gesloten Opportunity als Won of Lost ──
    #
    # De verkoopstatus van de originating AFAS Forecast (CmForecast.ViOp) én de vraag
    # of we artikels + voorcalculatie moeten aanmaken, hangen volledig af van deze
    # tweedeling. Bepalend is UITSLUITEND de PRIMAIRE quote (primary:true):
    #
    #   Won  (ViOp=G): opportunity closed  +  primaire quote status == 'approved'
    #                  → artikels aanmaken, voorcalculatie aanmaken, Forecast sluiten (G)
    #   Lost (ViOp=N): opportunity closed  +  geen primaire quote, of status != 'approved'
    #                  → GEEN artikels/voorcalc; alleen de Forecast sluiten (N)
    #
    # Een ontbrekende quote is dus GEEN fout meer (was voorheen een skip die het
    # watermerk vasthield): het is een geldige Lost-uitkomst die het watermerk laat
    # opschuiven zodra de Forecast succesvol op N is gezet.

    $WonOpportunities  = @()   # opps met een goedgekeurde primaire quote (ViOp=G)
    $LostOpportunities = @()   # opps zonder goedgekeurde primaire quote (ViOp=N)
    $AllQuotationLines = @{}   # OpportunityId → array van quote-regels (alleen Won)

    foreach ($Opportunity in $ClosedOpportunities) {
        # Bevestigd veldnaam: id (OpportunityResponseDto)
        $OpportunityId = $Opportunity.id

        # Haal de primaire quote op via de quote-endpoint gefilterd op opportunity.id.
        # OpportunityResponseDto heeft geen quoteId-veld — dit is de enige manier.
        try {
            $Quote = Get-SalesbuildrPrimaryQuote -OpportunityId $OpportunityId
        } catch {
            # Netwerk-/API-fout: échte fout, houd het watermerk vast en probeer opnieuw.
            Write-Log ERROR "[$OpportunityId] Fout bij ophalen primaire quote: $_"
            $Flow2Complete = $false
            continue
        }

        if ($null -ne $Quote -and $Quote.status -eq 'approved') {
            # ── Won ──
            # Bevestigd veldnaam: items (QuoteResponseDto) — NIET 'lines'
            $Lines = $Quote.items
            $AllQuotationLines[$OpportunityId] = $Lines
            $WonOpportunities += $Opportunity

            Write-Log INFO "[$OpportunityId] WON — primaire quote 'approved' ($($Lines.Count) regel(s)); artikels + voorcalc + Forecast sluiten (G)"
            $Quote | Format-List | Out-String | Write-Host
            $Lines | Format-List | Out-String | Write-Host
        } else {
            # ── Lost ──
            $Reden = if ($null -eq $Quote) { "geen primaire quote" } else { "primaire quote status = '$($Quote.status)'" }
            $LostOpportunities += $Opportunity

            Write-Log INFO "[$OpportunityId] LOST — $Reden; alleen Forecast sluiten (N)"
        }
    }

    Write-Log INFO "Categorisatie: $($WonOpportunities.Count) Won (G), $($LostOpportunities.Count) Lost (N)"

    # # Unieke artikelcodes over alle opportunities heen. De AFAS itemcode (ItCd) is
    # # ALTIJD de 'mpn' van de quote-regel — het 'product'-veld kan leeg zijn (vrije
    # # regel), dus daar mag niet op vertrouwd worden. Regels zonder mpn worden
    # # overgeslagen (geen artikelcode -> niet aan te maken/te koppelen).
    # $AllItemCodes = $AllQuotationLines.Values | ForEach-Object { $_ } |
    #     ForEach-Object { $_.mpn } |
    #     Where-Object { $_ } | Sort-Object -Unique

    # Write-Log INFO "$($AllItemCodes.Count) unieke artikelcodes (mpn) gevonden in quotations"

    # # Bevestigd veldnaam in Salesbuildr_Artikelen: 'itemCode' (maps to FbItemArticle.ItCd)
    # $BestaandeArtikels  = Invoke-AfasGetConnector -Connector $ConnArtikelenGet
    # $BestaandeItemCodes = $BestaandeArtikels | ForEach-Object { $_.itemCode }

    # # category.id -> costCenterId, uit de (gecachte) SB-categorieën. Nodig om per
    # # artikel de AFAS-artikelgroep (Grp) te bepalen (zie Get-AfasArtikelgroep).
    # $CategoryCostCenterMap = @{}
    # foreach ($cat in Get-SalesbuildrAllCategories) {
    #     if ($cat.id) { $CategoryCostCenterMap[$cat.id] = $cat.costCenterId }
    # }

    # # mpn's waarvoor geen artikelgroep bepaald kon worden -> in stap 2b wordt de
    # # hele opportunity overgeslagen (anders wijst de voorcalc-regel naar een
    # # niet-bestaand artikel). Zie de skip-logica in stap 2b.
    # $FailedItemCodes = @()

    # foreach ($ItemCode in $AllItemCodes) {
    #     $ArtikelBestaat = $BestaandeItemCodes -contains $ItemCode

    #     If (-Not $ArtikelBestaat) {
    #         # Bronregel voor de omschrijving (name) én de categorie (voor de artikelgroep).
    #         $BronRegel = $AllQuotationLines.Values | ForEach-Object { $_ } |
    #             Where-Object { $_.mpn -eq $ItemCode } | Select-Object -First 1

    #         # Artikelgroep (Grp) bepalen: category.id -> costCenterId -> Grp.
    #         $Artikelgroep = Get-AfasArtikelgroep -Category $BronRegel.category `
    #             -CategoryCostCenterMap $CategoryCostCenterMap -ArtikelgroepMap $ArtikelgroepMap
    #         If ([string]::IsNullOrWhiteSpace($Artikelgroep)) {
    #             Write-Log WARNING "Artikel [$ItemCode] overgeslagen: cost center voor categorie '$($BronRegel.category.name)' (id $($BronRegel.category.id)) niet in artikelgroep-mapping"
    #             $FailedItemCodes += $ItemCode
    #             $Flow2Complete = $false
    #             continue
    #         }

    #         try {
    #             New-AfasArtikel -Connector $ConnArtikelenUpdate -ItemCode $ItemCode `
    #                 -Omschrijving $BronRegel.name -Artikelgroep $Artikelgroep
    #         } catch {
    #             Write-Log ERROR "Fout bij aanmaken Artikel [$ItemCode]: $_"
    #             $Flow2Complete = $false
    #         }
    #     }
    # }

    # # ── Stap 2b: Voorcalculatieregels aanmaken per Won-Opportunity (alleen Won) ──

    # foreach ($Opportunity in $WonOpportunities) {
    #     $OpportunityId = $Opportunity.id
    #     # De externalIdentifier codeert alles wat we nodig hebben (Flow 1):
    #     #   afas-Forecast-{forecast}-{volgnummer}-{verkooprelatie}
    #     # We parsen die rechtstreeks; een re-fetch van de Forecast is niet meer nodig.
    #     if ($Opportunity.externalIdentifier -notmatch '^afas-Forecast-(?<fc>\d+)-(?<sqno>\d+)-(?<pr>.+)$') {
    #         Write-Log ERROR "[$OpportunityId] Onverwacht externalIdentifier-formaat '$($Opportunity.externalIdentifier)' — kan forecast-id/PrId/SqNo niet parsen, overgeslagen"
    #         $Flow2Complete = $false
    #         continue
    #     }
    #     $QuId = $Matches.fc          # QuId = uniek AFAS forecast-id (bijv. 11310); prefix evt. later
    #     $SqNo = [int]$Matches.sqno   # CmForecast @SqNo (volgnummer)
    #     $DbId = $Matches.pr          # CmForecast @PrId (verkooprelatie)

    #     # Idempotentie: controleer of Voorcalculatie al bestaat in AFAS (filter op offerte = QuId)
    #     $BestaandeVoorcalc = Get-AfasRecordByExternalId -Connector $ConnVoorcalcGet -ExternalId $QuId
    #     If ($null -ne $BestaandeVoorcalc) {
    #         Write-Log INFO "[$OpportunityId] Voorcalculatie al aanwezig in AFAS ($QuId) — alleen Forecast sluiten"
    #         try { Close-AfasForecast -Connector $ConnForecastUpdate -PrId $DbId -SqNo $SqNo -ViOp "G" -OrAF (Get-SalesbuildrQuoteTotal -Items $AllQuotationLines[$OpportunityId]) } catch { Write-Log ERROR "Fout bij sluiten Forecast: $_"; $Flow2Complete = $false }
    #         continue
    #     }

    #     $Lines = $AllQuotationLines[$OpportunityId]

    #     # Kon één van de artikels niet aangemaakt worden (cost center niet gemapt),
    #     # dan slaan we de HELE opportunity over: een voorcalc met een ontbrekende
    #     # regel zou naar een niet-bestaand artikel wijzen. Watermerk blijft staan,
    #     # zodat de opportunity opnieuw wordt geprobeerd na het aanvullen van de mapping.
    #     $OntbrekendeCodes = @($Lines | Where-Object { $FailedItemCodes -contains $_.mpn } |
    #         ForEach-Object { $_.mpn } | Sort-Object -Unique)
    #     If ($OntbrekendeCodes.Count -gt 0) {
    #         Write-Log WARNING "[$OpportunityId] Overgeslagen: artikel(en) $($OntbrekendeCodes -join ', ') niet aangemaakt (cost center niet gemapt)"
    #         $Flow2Complete = $false
    #         continue
    #     }

    #     $Regels = @()
    #     foreach ($Line in $Lines) {
    #         # De AFAS itemcode (ItCd) is ALTIJD de mpn. Regels zonder mpn hebben
    #         # geen artikelkoppeling en worden overgeslagen.
    #         If ([string]::IsNullOrWhiteSpace($Line.mpn)) {
    #             Write-Log WARNING "[$OpportunityId] Quote-regel '$($Line.name)' zonder mpn — overgeslagen (geen artikelcode)"
    #             continue
    #         }
    #         $Regels += @{
    #             # SalesBuildr-zijdige veldnamen bevestigd via QuoteItemResponseDto:
    #             # 'mpn' = AFAS itemcode (ItCd), 'name', 'quantity', 'price'
    #             ItemCode     = $Line.mpn
    #             Omschrijving = $Line.name
    #             Aantal       = $Line.quantity
    #             Prijs        = $Line.price
    #         }
    #     }

    #     $VoorcalculatieGelukt = $false
    #     try {
    #         New-AfasVoorcalculatie `
    #             -Connector    $ConnVoorcalcUpdate `
    #             -QuId         $QuId `
    #             -DbId         $DbId `
    #             -Omschrijving $Opportunity.name `
    #             -FcNo         $SqNo `
    #             -Regels       $Regels
    #         $VoorcalculatieGelukt = $true
    #     } catch {
    #         Write-Log ERROR "[$OpportunityId] Fout bij aanmaken Voorcalculatie: $_"
    #         $Flow2Complete = $false
    #     }

    #     # Sluit de Forecast in AFAS — alleen als de Voorcalculatie succesvol is aangemaakt
    #     if ($VoorcalculatieGelukt) {
    #         try {
    #             Close-AfasForecast -Connector $ConnForecastUpdate -PrId $DbId -SqNo $SqNo -ViOp "G" -OrAF (Get-SalesbuildrQuoteTotal -Items $AllQuotationLines[$OpportunityId])
    #         } catch {
    #             Write-Log ERROR "[$OpportunityId] Fout bij sluiten Forecast [SqNo $SqNo] in AFAS: $_"
    #             $Flow2Complete = $false
    #         }
    #     }
    # }

    # # ── Stap 2c: Lost-Opportunities — alleen de AFAS Forecast op N sluiten ──
    # #
    # # Geen artikels/voorcalc: een Lost-forecast wordt enkel afgesloten. De
    # # CmForecast-sleutel (verkooprelatie/PrId + volgnummer/SqNo) parsen we uit de
    # # externalIdentifier (zelfde formaat als de Won-tak) — geen re-fetch nodig.
    # foreach ($Opportunity in $LostOpportunities) {
    #     $OpportunityId = $Opportunity.id
    #     if ($Opportunity.externalIdentifier -notmatch '^afas-Forecast-(?<fc>\d+)-(?<sqno>\d+)-(?<pr>.+)$') {
    #         Write-Log ERROR "[$OpportunityId] Onverwacht externalIdentifier-formaat '$($Opportunity.externalIdentifier)' — kan PrId/SqNo niet parsen, overgeslagen"
    #         $Flow2Complete = $false
    #         continue
    #     }
    #     $SqNo = [int]$Matches.sqno   # CmForecast @SqNo (volgnummer)
    #     $DbId = $Matches.pr          # CmForecast @PrId (verkooprelatie)

    #     try {
    #         Close-AfasForecast -Connector $ConnForecastUpdate -PrId $DbId -SqNo $SqNo -ViOp "N"
    #     } catch {
    #         Write-Log ERROR "[$OpportunityId] Fout bij sluiten Forecast [SqNo $SqNo] als Lost (N) in AFAS: $_"
    #         $Flow2Complete = $false
    #     }
    # }


    ####################################################################
    # State bijwerken
    ####################################################################

    # Per-flow watermark: alleen opschuiven als de betreffende batch volledig
    # succesvol is verwerkt. Bij overgeslagen/gefaalde records blijft de datum
    # staan zodat de volgende run die records opnieuw ophaalt en probeert.
#     If ($Flow1Complete) {
#         Get-Date | Export-Clixml -Path $ForecastStateFile -Force
#         Write-Log INFO "Flow 1 state bijgewerkt"
#     } else {
#         Write-Log WARNING "Flow 1 state NIET bijgewerkt — niet alle Forecasts verwerkt; wordt opnieuw geprobeerd bij volgende run"
#     }

#     If ($Flow2Complete) {
#         Get-Date | Export-Clixml -Path $OpportunityStateFile -Force
#         Write-Log INFO "Flow 2 state bijgewerkt"
#     } else {
#         Write-Log WARNING "Flow 2 state NIET bijgewerkt — niet alle Opportunities verwerkt; wordt opnieuw geprobeerd bij volgende run"
#     }

} catch {
    Write-Log ERROR "Fatale fout: $_"
}

#endregion
