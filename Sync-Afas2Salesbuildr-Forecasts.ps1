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

#endregion

#region ── AFAS ──────────────────────────────────────────────────────────────

function Connect-Afas {
    param(
        [string]$Omgeving,
        [string]$ApiToken
    )
    $Global:AfasRestUrl = "https://$($Omgeving).rest.afas.online/profitrestservices"
    $encoded           = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($ApiToken))
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
    # Operator 5 = greater than; veld 'gewijzigd' bevestigd in Salesbuildr_Forecasts connector.
    param(
        [string]$Connector,
        [datetime]$SinceDate
    )

    $result   = @()
    $skip     = 0
    $take     = 100
    $sinceStr = $SinceDate.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

    do {
        $url      = "$($Global:AfasRestUrl)/connectors/$($Connector)?skip=$skip&take=$take" +
                    "&filterfieldids=gewijzigd&filtervalues=$([uri]::EscapeDataString($sinceStr))&operatortypes=5"
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
        [string]$ExternalId    # QuId-formaat, bijv. "SB-13"
    )

    $url      = "$($Global:AfasRestUrl)/connectors/$($Connector)" +
                "?skip=0&take=1&filterfieldids=offerte&filtervalues=$([uri]::EscapeDataString($ExternalId))&operatortypes=1"
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
    param(
        [string]$Connector,
        [string]$ItemCode,
        [string]$Omschrijving
    )

    $body = @{
        FbItemArticle = @{
            Element = @{
                Fields = @{
                    ItCd    = $ItemCode
                    Ds      = $Omschrijving
                    Ds_1043 = $Omschrijving
                    VaTp    = "0"
                    BiSt    = $false
                    CoLa    = "NL"
                    Bl      = $false
                }
            }
        }
    }

    Write-Log INFO "Artikel aanmaken in AFAS: $ItemCode - $Omschrijving"
    Invoke-AfasUpdateConnector -Connector $Connector -Body $body
}

function Close-AfasForecast {
    # Sluit een Forecast als Gewonnen (ViOp=G) via PUT op CmForecast.
    # Primaire sleutel is samengesteld: PrId (verkooprelatie) + SqNo (volgnummer).
    param(
        [string]$Connector,
        [string]$PrId,    # verkooprelatie / debtor code (CmForecast.PrId)
        [int]$SqNo        # volgnummer / sequence number (CmForecast.SqNo)
    )

    $body = @{
        CmForecast = @{
            Element = @{
                Fields = @{
                    PrId = $PrId
                    SqNo = $SqNo
                    ViOp = "G"
                    DaSc = (Get-Date -Format "yyyy-MM-dd")
                }
            }
        }
    }

    Write-Log INFO "Forecast sluiten in AFAS: $PrId / SqNo $SqNo"
    Invoke-AfasUpdateConnector -Connector $Connector -Body $body -Method 'Put'
}

function New-AfasVoorcalculatie {
    # Maakt een KnQuotation (voorcalculatie) aan in AFAS, inclusief regels.
    # QuId = predictable ID voor idempotentie, bijv. "SB-13" (max 21 chars).
    # FcNo koppelt de quotatie terug aan de originating Forecast (CmForecast.SqNo).
    # KnQuotationLine velden: ItCd (itemcode), Qu (aantal), UP (eenheidsprijs).
    param(
        [string]$Connector,
        [string]$QuId,        # offerte-nummer, bijv. "SB-13"
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

    $remaining = $response.Headers['X-RateLimit-Remaining']
    if ($null -ne $remaining -and [int]$remaining -lt 50) {
        Write-Log WARNING "SalesBuildr rate limit bijna bereikt: $remaining / 500 requests resterend in huidig venster"
    }

    return $response.Content | ConvertFrom-Json
}

function Get-SalesbuildrClosedOpportunities {
    # Haalt alle Opportunities met statusId 'closed' op via paginering (size/from).
    # Filtert client-side op updatedAt > $SinceDate (bevestigd veldnaam: updatedAt).
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

    # Client-side datumfilter op bevestigd veld 'updatedAt' (OpportunityResponseDto)
    return $allResults | Where-Object { $_.updatedAt -gt $SinceDate }
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

function Get-SalesbuildrPrimaryQuote {
    # Haalt de primaire Quote op voor een Opportunity.
    # OpportunityResponseDto bevat GEEN quoteId — quotes worden opgevraagd via
    # GET /public-api/quote?filters=opportunityId:{id} en gefilterd op primary:true.
    # Bevestigde veldnamen (QuoteResponseDto):
    #   - items     : array van QuoteItemResponseDto (NIET 'lines')
    #   - primary   : boolean, true voor de primaire quote
    #   - status    : string (quote-status, bijv. 'approved')
    # Bevestigde veldnamen per item (QuoteItemResponseDto):
    #   - name      : productnaam
    #   - quantity  : aantal
    #   - price     : eenheidsprijs (NIET 'unitPrice')
    #   - product   : { id, name, externalIdentifier } — extern ID voor AFAS-koppeling
    #   - unit      : eenheid
    #   - mpn       : fabrikantcode
    param([string]$OpportunityId)

    $size = 100
    $from = 0
    $allQuotes = @()

    do {
        $response  = Invoke-SalesbuildrRequest `
            -Uri "$($Global:SalesbuildrUri)/public-api/quote?filters=opportunityId%3A$OpportunityId&size=$size&from=$from"
        $allQuotes += $response.results
        $from      += $size
    } while ($allQuotes.Count -lt $response.total)

    $primary = $allQuotes | Where-Object { $_.primary -eq $true } | Select-Object -First 1

    if ($null -eq $primary) {
        # Fallback: geen primaire quote, gebruik de meest recente goedgekeurde
        $primary = $allQuotes | Where-Object { $_.status -eq 'approved' } |
            Sort-Object -Property approvedAt -Descending | Select-Object -First 1
    }

    return $primary
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
    $OpportunityStateFile  = "$PSScriptRoot\work\LastClosedOpportunitySyncDate.xml"

    $Epoch = Get-Date -Date "1-1-1970"

    $LastForecastSync    = If (Test-Path $ForecastStateFile)    { Import-Clixml $ForecastStateFile }    Else { $Epoch }
    $LastOpportunitySync = If (Test-Path $OpportunityStateFile) { Import-Clixml $OpportunityStateFile } Else { $Epoch }

    # Credentials uit config via DPAPI (zelfde structuur als Sync-Afas2Salesbuildr.ps1)
    # Zodra Configuration.psm1 beschikbaar is, vervangen door:
    #   $AfasApiToken      = (Get-PSCredential -SecuredCredential $config.afas.api.secured_credential).GetNetworkCredential().Password
    #   $SalesbuildrApiKey = (Get-PSCredential -SecuredCredential $config.salesbuildr.api.secured_credential).GetNetworkCredential().Password
    $AfasApiToken = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR(
            ($config.afas.api.secured_credential.password |
                Where-Object { $_ } | Select-Object -First 1) |
                ConvertTo-SecureString
        )
    )
    $SalesbuildrApiKey = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR(
            ($config.salesbuildr.api.secured_credential.password |
                Where-Object { $_ } | Select-Object -First 1) |
                ConvertTo-SecureString
        )
    )

    Connect-Afas        -Omgeving $config.afas.omgeving -ApiToken $AfasApiToken
    Connect-Salesbuildr -Uri $config.salesbuildr.api.url -ApiKey $SalesbuildrApiKey

    # AFAS connector namen uit config
    $ConnForecastGet    = $config.afas.connectors.forecasts_get        # Salesbuildr_Forecasts
    $ConnForecastUpdate = $config.afas.connectors.forecasts_update     # CmForecast
    $ConnArtikelenGet   = $config.afas.connectors.artikelen_get        # Salesbuildr_Artikelen
    $ConnArtikelenUpdate = $config.afas.connectors.artikelen_update    # FbItemArticle
    $ConnVoorcalcGet    = $config.afas.connectors.voorcalculatie_get   # Salesbuildr_Voorcalculatie
    $ConnVoorcalcUpdate = $config.afas.connectors.voorcalculatie_update # KnQuotation


    ####################################################################
    # FLOW 1 — AFAS Forecasts → SalesBuildr Opportunities
    ####################################################################

    Write-Log INFO "=== Flow 1: AFAS Forecasts → SalesBuildr Opportunities ==="
    Write-Log INFO "Delta sinds: $LastForecastSync"

    $AfasForecasts = Invoke-AfasGetConnectorFiltered `
        -Connector $ConnForecastGet `
        -SinceDate $LastForecastSync

    Write-Log INFO "$($AfasForecasts.Count) gewijzigde Forecasts gevonden"

    foreach ($Forecast in $AfasForecasts) {

        # Bevestigde veldnamen (Salesbuildr_Forecasts GetConnector):
        # 'forecast' = integer SqNo (primary key), 'forecastOmschrijving' = naam,
        # 'verkooprelatie' = AFAS debiteurcode (= PrId in CmForecast)
        $ForecastSqNo = $Forecast.forecast
        $ExternalId   = "afas-Forecast-$ForecastSqNo"

        # Sla over als de Opportunity al gesloten is in SalesBuildr
        $ExistingOpportunity = Get-SalesbuildrOpportunityByExtId -ExternalId $ExternalId
        If ($null -ne $ExistingOpportunity -and $ExistingOpportunity.statusId -eq "closed") {
            Write-Log INFO "[$($Forecast.forecastOmschrijving)] Overgeslagen: al gesloten in SalesBuildr"
            continue
        }

        $SalesbuildrOpportunity = @{
            # externalIdentifier wordt meegegeven via de URL, NIET in de body (UpsertOpportunityDto)
            name           = $Forecast.forecastOmschrijving
            companyExtId   = $Forecast.verkooprelatie
            probability    = $Forecast.scoringkans
            onetimeRevenue = $Forecast.bedragVerwacht
        }
        if ($null -ne $Forecast.einddatumVerwacht) {
            $SalesbuildrOpportunity.expectedCloseDate = ([datetime]$Forecast.einddatumVerwacht).ToString("yyyy-MM-dd")
        }

        Write-Log INFO "Opportunity upsert in SalesBuildr: $($Forecast.forecastOmschrijving)"
        try {
            Invoke-SalesbuildrUpsertOpportunity -ExternalId $ExternalId -Body $SalesbuildrOpportunity
        } catch {
            Write-Log ERROR "[$($Forecast.forecastOmschrijving)] Fout bij upsert Opportunity: $_"
        }
    }


    ####################################################################
    # FLOW 2 — Gesloten SalesBuildr Opportunities → AFAS Voorcalculatieregels
    ####################################################################

    Write-Log INFO "=== Flow 2: Gesloten Opportunities → AFAS Voorcalculatieregels ==="
    Write-Log INFO "Delta sinds: $LastOpportunitySync"

    $ClosedOpportunities = Get-SalesbuildrClosedOpportunities -SinceDate $LastOpportunitySync

    Write-Log INFO "$($ClosedOpportunities.Count) gesloten Opportunities gevonden"

    # ── Stap 2a: Verzamel alle quotation-items en maak ontbrekende Artikels aan ──

    $AllQuotationLines = @{}   # OpportunityId → array van quote-regels

    foreach ($Opportunity in $ClosedOpportunities) {
        # Bevestigd veldnaam: id (OpportunityResponseDto)
        $OpportunityId = $Opportunity.id

        # Haal de primaire quote op via de quote-endpoint gefilterd op opportunityId.
        # OpportunityResponseDto heeft geen quoteId-veld — dit is de enige manier.
        try {
            $Quote = Get-SalesbuildrPrimaryQuote -OpportunityId $OpportunityId
        } catch {
            Write-Log ERROR "[$OpportunityId] Fout bij ophalen primaire quote: $_"
            continue
        }

        if ($null -eq $Quote) {
            Write-Log WARNING "[$OpportunityId] Geen primaire of goedgekeurde quote gevonden — opportunity overgeslagen"
            continue
        }

        # Bevestigd veldnaam: items (QuoteResponseDto) — NIET 'lines'
        $Lines = $Quote.items
        $AllQuotationLines[$OpportunityId] = $Lines
    }

    # Unieke product external identifiers over alle opportunities heen.
    # QuoteItemResponseDto heeft geen 'itemCode' veld — identifier zit op product.externalIdentifier.
    # TODO: implementeer de custom itemcode-logica zodra die bekend is.
    #       Voorlopig wordt product.externalIdentifier als identifier gebruikt.
    $AllItemCodes = $AllQuotationLines.Values | ForEach-Object { $_ } |
        ForEach-Object { $_.product.externalIdentifier } |
        Where-Object { $_ } | Sort-Object -Unique

    Write-Log INFO "$($AllItemCodes.Count) unieke artikelcodes gevonden in quotations"

    # Bevestigd veldnaam in Salesbuildr_Artikelen: 'itemCode' (maps to FbItemArticle.ItCd)
    $BestaandeArtikels  = Invoke-AfasGetConnector -Connector $ConnArtikelenGet
    $BestaandeItemCodes = $BestaandeArtikels | ForEach-Object { $_.itemCode }

    foreach ($ItemCode in $AllItemCodes) {
        $ArtikelBestaat = $BestaandeItemCodes -contains $ItemCode

        If (-Not $ArtikelBestaat) {
            # Bevestigd veldnaam: name (QuoteItemResponseDto) — NIET 'description'
            $Omschrijving = ($AllQuotationLines.Values | ForEach-Object { $_ } |
                Where-Object { $_.product.externalIdentifier -eq $ItemCode } |
                Select-Object -First 1).name

            try {
                New-AfasArtikel -Connector $ConnArtikelenUpdate -ItemCode $ItemCode -Omschrijving $Omschrijving
            } catch {
                Write-Log ERROR "Fout bij aanmaken Artikel [$ItemCode]: $_"
            }
        }
    }

    # ── Stap 2b: Voorcalculatieregels aanmaken per Opportunity ──

    foreach ($Opportunity in $ClosedOpportunities) {
        $OpportunityId = $Opportunity.id
        # externalIdentifier = "afas-Forecast-{SqNo}" — ingesteld bij upsert in Flow 1
        $ForecastSqNo  = [int]($Opportunity.externalIdentifier -replace "^afas-Forecast-", "")
        # companyExtId = AFAS verkooprelatie (= PrId in CmForecast, composite primary key)
        $DbId          = $Opportunity.companyExtId
        $QuId          = "SB-$ForecastSqNo"   # predictable QuId, past in 21-char limiet

        # Idempotentie: controleer of Voorcalculatie al bestaat in AFAS (filter op offerte = QuId)
        $BestaandeVoorcalc = Get-AfasRecordByExternalId -Connector $ConnVoorcalcGet -ExternalId $QuId
        If ($null -ne $BestaandeVoorcalc) {
            Write-Log INFO "[$OpportunityId] Voorcalculatie al aanwezig in AFAS ($QuId) — alleen Forecast sluiten"
            try { Close-AfasForecast -Connector $ConnForecastUpdate -PrId $DbId -SqNo $ForecastSqNo } catch { Write-Log ERROR "Fout bij sluiten Forecast: $_" }
            continue
        }

        $Lines = $AllQuotationLines[$OpportunityId]

        $Regels = @()
        foreach ($Line in $Lines) {
            $Regels += @{
                # SalesBuildr-zijdige veldnamen bevestigd via QuoteItemResponseDto:
                # 'product.externalIdentifier' = AFAS itemcode, 'name', 'quantity', 'price'
                ItemCode     = $Line.product.externalIdentifier
                Omschrijving = $Line.name
                Aantal       = $Line.quantity
                Prijs        = $Line.price
            }
        }

        $VoorcalculatieGelukt = $false
        try {
            New-AfasVoorcalculatie `
                -Connector    $ConnVoorcalcUpdate `
                -QuId         $QuId `
                -DbId         $DbId `
                -Omschrijving $Opportunity.name `
                -FcNo         $ForecastSqNo `
                -Regels       $Regels
            $VoorcalculatieGelukt = $true
        } catch {
            Write-Log ERROR "[$OpportunityId] Fout bij aanmaken Voorcalculatie: $_"
        }

        # Sluit de Forecast in AFAS — alleen als de Voorcalculatie succesvol is aangemaakt
        if ($VoorcalculatieGelukt) {
            try {
                Close-AfasForecast -Connector $ConnForecastUpdate -PrId $DbId -SqNo $ForecastSqNo
            } catch {
                Write-Log ERROR "[$OpportunityId] Fout bij sluiten Forecast [SqNo $ForecastSqNo] in AFAS: $_"
            }
        }
    }


    ####################################################################
    # State bijwerken
    ####################################################################

    If (!$Error) {
        Get-Date | Export-Clixml -Path $ForecastStateFile    -Force
        Get-Date | Export-Clixml -Path $OpportunityStateFile -Force
        Write-Log INFO "State bijgewerkt"
    } else {
        Write-Log ERROR "State NIET bijgewerkt vanwege fouten tijdens de run"
    }

} catch {
    Write-Log ERROR "Fatale fout: $_"
}

#endregion
