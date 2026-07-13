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
    File Name   : Sync-Forecasts.ps1
    Author      :
    Prerequisite: PowerShell
    Date        : 2026-07-01

    RELEASES
        v0.1 [2026-07-01] : Initieel skeleton
        v0.2 [2026-07-01] : AFAS connector veldnamen ingevuld nav AFAS_API_Guide.md
        v0.3 [2026-07-06] : Config/mapping/state naar configs\; cleanup: dode code
                            verwijderd, externalIdentifier-parse ontdubbeld, stappen
                            hernummerd
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

function ConvertTo-ConfigBool {
    # Parseert een config.xml-waarde naar [bool]. Herkent true/1/yes/ja/on en
    # false/0/no/nee/off (hoofdletterongevoelig). Leeg, ontbrekend of onbekend
    # -> $Default (zodat een oudere config zonder <flows> beide flows aan laat).
    param(
        [string]$Value,
        [bool]$Default = $true
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return $Default }
    switch ($Value.Trim().ToLower()) {
        { $_ -in 'true','1','yes','ja','on'   } { return $true }
        { $_ -in 'false','0','no','nee','off' } { return $false }
        default                                 { return $Default }
    }
}

function ConvertFrom-ForecastExternalId {
    # Parseert de door Flow 1 gezette Opportunity-externalIdentifier:
    #   afas-Forecast-{forecast}-{volgnummer}-{verkooprelatie}
    # Die codeert alles wat Flow 2 nodig heeft om ZONDER re-fetch van de AFAS
    # Forecast verder te kunnen:
    #   ForecastId = uniek AFAS forecast-id  -> QuId (voorcalc-offertenr)
    #   SqNo       = volgnummer              -> CmForecast @SqNo / KnQuotation FcNo
    #   PrId       = verkooprelatie          -> CmForecast @PrId / KnQuotation DbId
    # Geeft $null bij een onverwacht formaat — de aanroeper slaat het record dan
    # over en houdt het watermerk vast.
    param([string]$ExternalIdentifier)

    if ($ExternalIdentifier -notmatch '^afas-Forecast-(?<fc>\d+)-(?<sqno>\d+)-(?<pr>.+)$') { return $null }

    [pscustomobject]@{
        ForecastId = $Matches.fc
        SqNo       = [int]$Matches.sqno
        PrId       = $Matches.pr
    }
}

function Get-SyncWatermark {
    # Leest één sync-watermerk uit het gezamenlijke state-bestand
    # (configs\LastSyncDates.xml). Ontbrekend bestand/knoop -> Epoch, zodat een
    # eerste run alles ophaalt. Naam is de flow-sleutel, bv. 'Flow1' / 'Flow2'.
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Name
    )
    $Epoch = [datetime]'1970-01-01'
    if (-not (Test-Path $Path)) { return $Epoch }
    $xml  = [xml](Get-Content $Path -Raw)
    $node = $xml.SelectSingleNode("/SyncDates/$Name")
    if ($null -eq $node -or [string]::IsNullOrWhiteSpace($node.InnerText)) { return $Epoch }
    return [datetime]::Parse($node.InnerText, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
}

function Get-SyncOverrideDays {
    # Leest de test-override <OverrideDays> uit het state-bestand. Een geheel
    # getal N betekent: beide flows syncen vanaf N dagen geleden (middernacht
    # lokale tijd). Leeg/ontbrekend/ongeldig -> $null, dan gelden Flow1/Flow2.
    param(
        [Parameter(Mandatory)] [string] $Path
    )
    if (-not (Test-Path $Path)) { return $null }
    $xml  = [xml](Get-Content $Path -Raw)
    $node = $xml.SelectSingleNode('/SyncDates/OverrideDays')
    if ($null -eq $node -or [string]::IsNullOrWhiteSpace($node.InnerText)) { return $null }
    $days = 0
    if (-not [int]::TryParse($node.InnerText.Trim(), [ref]$days)) {
        Write-Log WARNING "OverrideDays bevat geen geldig getal ('$($node.InnerText)') — override genegeerd"
        return $null
    }
    return $days
}

function Set-SyncWatermark {
    # Schrijft één sync-watermerk naar het gezamenlijke state-bestand en laat de
    # andere flow-waarde ongemoeid. Datum wordt round-trip ('o') opgeslagen.
    param(
        [Parameter(Mandatory)] [string]   $Path,
        [Parameter(Mandatory)] [string]   $Name,
        [Parameter(Mandatory)] [datetime] $Date
    )
    $xml = if (Test-Path $Path) { [xml](Get-Content $Path -Raw) } else { [xml]'<SyncDates/>' }
    $node = $xml.DocumentElement.SelectSingleNode($Name)
    if ($null -eq $node) {
        $node = $xml.CreateElement($Name)
        $xml.DocumentElement.AppendChild($node) | Out-Null
    }
    $node.InnerText = $Date.ToString('o')
    $xml.Save($Path)
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

function Get-AfasQuotation {
    # Controleert of een AFAS-quotation (voorcalculatie) al bestaat in AFAS door
    # te filteren op offerte (= QuId = AFAS forecast-id). Bevestigd filterveld:
    # 'offerte' in Salesbuildr_Voorcalculatie (operatortypes=1 = equal).
    # Geeft het eerste gevonden record terug, of $null als het niet bestaat.
    param(
        [string]$Connector,
        [string]$OfferteNr    # QuId = AFAS forecast-id, bijv. "11310"
    )

    $url      = "$($Global:AfasRestUrl)/connectors/$($Connector)" +
                "?skip=0&take=1&filterfieldids=offerte&filtervalues=$([uri]::EscapeDataString($OfferteNr))&operatortypes=1"
    $response = Invoke-RestMethod -Uri $url -Headers $Global:AfasHeaders -Method Get

    if ($response.rows.Count -gt 0) { return $response.rows[0] }
    return $null
}

function Get-AfasArtikelByItemCode {
    # Controleert of een Artikel bestaat in AFAS via de Salesbuildr_Artikelen
    # GetConnector, server-side gefilterd op itemCode (operatortypes=1 = gelijk aan).
    # Veel efficiënter dan de hele catalogus ophalen (AFAS heeft 30.000+ artikels):
    # per mpn één kleine, gefilterde call. Geeft de matchende rij terug, of $null
    # als het artikel niet bestaat.
    param(
        [string]$Connector,
        [string]$ItemCode
    )

    $url      = "$($Global:AfasRestUrl)/connectors/$($Connector)" +
                "?filterfieldids=itemCode&filtervalues=$([uri]::EscapeDataString($ItemCode))&operatortypes=1&skip=0&take=1"
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
    # Veldwaarden:
    #   ItCd = itemcode (= quote-regel mpn)
    #   AuId = altijd $false
    #   Ds   = omschrijving (naam), afgekapt op 100 tekens
    #   Grp  = artikelgroep (verplicht) — de AFAS-id uit mapping-artikelgroepen.xml
    #   BiUn = besteleenheid, voorlopig "St" (stuks)
    #   VaRc = voorlopig "2"
    param(
        [string]$Connector,
        [string]$ItemCode,
        [string]$Omschrijving,
        [string]$Artikelgroep
    )

    # Ds is in AFAS beperkt tot 100 tekens.
    if ($Omschrijving.Length -gt 100) { $Omschrijving = $Omschrijving.Substring(0, 100) }

    $body = @{
        FbItemArticle = @{
            Element = @{
                Fields = @{
                    ItCd = $ItemCode
                    AuId = $false
                    Ds   = $Omschrijving
                    Grp  = $Artikelgroep
                    BiUn = "St"
                    VaRc = "2"
                }
            }
        }
    }

    Write-Log INFO "Artikel aanmaken in AFAS: $ItemCode - $Omschrijving (artikelgroep $Artikelgroep)"
    Invoke-AfasUpdateConnector -Connector $Connector -Body $body
}

function Get-SalesbuildrMainCategoryId {
    # Herleidt een SB-(sub)categorie naar zijn HOOFDcategorie (de wortel: de categorie
    # zonder — of met onbekende — parent), door via parentCategoryId omhoog te lopen.
    # Alleen hoofdcategorieën worden op AFAS gemapt (mapping-artikelgroepen.xml), dus
    # een quote-regel-categorie moet eerst naar zijn hoofdcategorie herleid worden.
    # $ParentMap = category.id -> parentCategoryId (leeg = wortel), opgebouwd door
    # Get-SalesbuildrCategoryParentMap. Geeft $null als de categorie onbekend is.
    param(
        [string]$CategoryId,
        [hashtable]$ParentMap
    )

    if ([string]::IsNullOrWhiteSpace($CategoryId) -or -not $ParentMap.ContainsKey($CategoryId)) {
        return $null
    }

    $current = $CategoryId
    $seen    = @{}
    while (-not $seen.ContainsKey($current)) {
        $seen[$current] = $true
        $parent = $ParentMap[$current]
        # Geen (bekende) parent meer -> $current is de hoofdcategorie.
        if ([string]::IsNullOrWhiteSpace($parent) -or -not $ParentMap.ContainsKey($parent)) {
            return $current
        }
        $current = $parent
    }
    return $current   # cyclusbescherming: hoogst bereikte categorie
}

function Get-AfasArtikelgroep {
    # Vertaalt een Salesbuildr-productcategorie naar een AFAS artikelgroep (Grp). De
    # mapping (mapping-artikelgroepen.xml) is op HOOFDcategorie gemaakt, dus de
    # regel-categorie wordt eerst via de SB-categorieboom naar zijn hoofdcategorie
    # herleid ($CategoryParentMap) en die hoofdcategorie-id in $ArtikelgroepMap opgezocht.
    # Geeft $null als de categorie ontbreekt, niet naar een hoofdcategorie te herleiden
    # is, of (nog) niet gemapt is — de aanroeper slaat het artikel dan over (Flow 2 stap 2b).
    param(
        $Category,                       # SB category-object ({ id, name, ... }) of $null
        [hashtable]$ArtikelgroepMap,     # hoofdcategorie.id -> Grp
        [hashtable]$CategoryParentMap    # category.id -> parentCategoryId
    )

    if ($null -eq $Category -or [string]::IsNullOrWhiteSpace($Category.id)) { return $null }
    $mainCatId = Get-SalesbuildrMainCategoryId -CategoryId $Category.id -ParentMap $CategoryParentMap
    if ($mainCatId -and $ArtikelgroepMap.ContainsKey($mainCatId)) { return $ArtikelgroepMap[$mainCatId] }
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

function New-AfasQuotation {
    # Maakt een AFAS-quotation (KnQuotation, de voorcalculatie) aan in AFAS,
    # inclusief regels — te onderscheiden van de SB-quotation (de Salesbuildr quote).
    # Meerdere regels gaan als één payload mee: KnQuotationLine.Element is een
    # ARRAY van { Fields = ... }-objecten binnen één Objects-entry.
    # Kop (KnQuotation.Element):
    #   @QuId = uniek AFAS forecast-id (Element-attribuut), tevens idempotentiesleutel
    #           (offerte in Salesbuildr_Voorcalculatie).
    #   QuDa  = offertedatum (voorlopig huidige datum).
    #   DbId  = verkooprelatie / debtor code (= AFAS PrId), uit de opp-externalId.
    #   FcNo  = forecast volgnummer (= CmForecast.SqNo), uit de opp-externalId.
    # Regel (KnQuotationLine.Element[].Fields) — drie regeltypes via VaIt:
    #   VaIt="2" ARTIKEL   : ItCd = mpn, UnId = "St", QuUn/Qu/QuSa = aantal,
    #                        Upri = verkoopprijs p/st, AmCo = kostprijs p/st.
    #   VaIt="1" WERKSOORT : ItCd = werksoort-code (Diensten-internalProductId dat in AFAS
    #                        bestaat), UnId = "" (geen eenheid), QuUn/Qu/QuSa = aantal,
    #                        Upri = verkoopprijs, AmCo = "0" (werksoorten hebben ALTIJD kostprijs 0).
    #   VaIt="3" TXT       : Diensten-item dat NIET in AFAS bestaat -> tekstregel. ItCd = "SBO"
    #                        (vaste AFAS text-item-code voor Salesbuildr-tekstregels), Ds = SB-info
    #                        (omschrijving + aantal + prijs + kostprijs, max 255 tekens), en
    #                        UnId/QuUn/Qu/QuSa/Upri/AmCo alle leeg — een tekstregel voert geen
    #                        aantallen of bedragen.
    # Het regeltype komt per regel uit Regel.Kind ('txt') of Regel.Soort ("1"/"2", val terug op "2").
    # Bedragen als string met punt-decimaal (invariant).
    param(
        [string]$Connector,
        [string]$QuId,        # AFAS forecast-id, bijv. "11310"
        [string]$DbId,        # verkooprelatie / debtor code (= AFAS PrId)
        [int]$FcNo,           # forecast volgnummer (CmForecast.SqNo)
        [string]$Ds,          # omschrijving (= SB-quote title), afgekapt op 100 tekens
        [array]$Regels        # array van hashtables: ItemCode, Aantal, Prijs, Kostprijs, [Soort] of { Kind='txt', Tekst, Aantal, Prijs, Kostprijs }
    )

    $inv = [System.Globalization.CultureInfo]::InvariantCulture

    # Ds (omschrijving) is in AFAS beperkt tot 100 tekens.
    if ($Ds -and $Ds.Length -gt 100) { $Ds = $Ds.Substring(0, 100) }

    $lineElements = @($Regels | ForEach-Object {
        if ($_.Kind -eq 'txt') {
            # === TXT-regel (VaIt=3): Diensten-item dat NIET in AFAS bestaat ===
            # Ds bevat de SB-info (omschrijving + aantal + prijs + kostprijs), max 255 tekens.
            # ItCd = "SBO" (vaste AFAS text-item-code); geen aantallen/bedragen op de regel zelf.
            $txtDs = "{0} - aantal {1}, prijs {2}, kostprijs {3}" -f `
                $_.Tekst, `
                ([double]$_.Aantal).ToString($inv), `
                ([double]$_.Prijs).ToString($inv), `
                ([double]$_.Kostprijs).ToString($inv)
            if ($txtDs.Length -gt 255) { $txtDs = $txtDs.Substring(0, 255) }
            @{
                Fields = @{
                    VaIt = "3"
                    ItCd = "SBO"
                    Ds   = $txtDs
                    UnId = ""
                    QuUn = ""
                    Qu   = ""
                    QuSa = ""
                    Upri = ""
                    AmCo = ""
                }
            }
        }
        else {
            $isWerksoort = ($_.Soort -eq '1')
            @{
                Fields = @{
                    VaIt = if ($_.Soort) { $_.Soort } else { "2" }   # 2=artikel, 1=werksoort
                    ItCd = $_.ItemCode
                    UnId = if ($isWerksoort) { "" } else { "St" }    # werksoort: geen eenheid; artikel: stuks
                    QuUn = ([double]$_.Aantal).ToString($inv)
                    Qu   = ([double]$_.Aantal).ToString($inv)
                    QuSa = ([double]$_.Aantal).ToString($inv)
                    Upri = ([double]$_.Prijs).ToString($inv)
                    # Werksoorten hebben ALTIJD kostprijs 0; artikelen dragen hun eigen kostprijs.
                    AmCo = if ($isWerksoort) { "0" } else { ([double]$_.Kostprijs).ToString($inv) }
                }
            }
        }
    })

    $body = @{
        KnQuotation = @{
            Element = @{
                "@QuId" = $QuId
                Fields  = @{
                    QuDa = (Get-Date -Format "yyyy-MM-dd")
                    DbId = $DbId
                    FcNo = $FcNo
                    Ds   = $Ds
                }
                Objects = @(
                    @{
                        KnQuotationLine = @{
                            Element = $lineElements
                        }
                    }
                )
            }
        }
    }

    Write-Log INFO "AFAS-quotation aanmaken: $QuId (Forecast SqNo: $FcNo, $($Regels.Count) regel(s))"
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

function Get-SalesbuildrCategoryParentMap {
    # Haalt alle SB-categorieën op (GET /public-api/category, platte lijst met
    # parentCategoryId) en bouwt een map category.id -> parentCategoryId (leeg voor
    # hoofdcategorieën). Wordt aan het begin van de run opgebouwd en gebruikt om een
    # quote-regel-(sub)categorie naar zijn hoofdcategorie te herleiden
    # (Get-SalesbuildrMainCategoryId), want alleen hoofdcategorieën zijn op AFAS gemapt.
    $categories = @(Invoke-SalesbuildrRequest -Uri "$($Global:SalesbuildrUri)/public-api/category")
    $map = @{}
    foreach ($c in $categories) {
        if (-not [string]::IsNullOrWhiteSpace($c.id)) {
            $map[$c.id] = if ($null -ne $c.parentCategoryId) { [string]$c.parentCategoryId } else { '' }
        }
    }
    return $map
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

function Get-SalesbuildrProductById {
    # Haalt één product op via GET /public-api/product/{id} (levert een
    # ProductResponseDto, incl. customFields). Resultaten worden gecachet omdat
    # meerdere quote-regels naar hetzelfde product kunnen verwijzen. $null als het
    # product niet gevonden wordt.
    param([string]$ProductId)

    if (-not $Global:SbProductCache) { $Global:SbProductCache = @{} }
    if ($Global:SbProductCache.ContainsKey($ProductId)) {
        return $Global:SbProductCache[$ProductId]
    }

    try {
        $Product = Invoke-SalesbuildrRequest `
            -Uri "$($Global:SalesbuildrUri)/public-api/product/$ProductId"
    } catch {
        Write-Log WARNING "Product [$ProductId] kon niet opgehaald worden: $_"
        $Product = $null
    }

    $Global:SbProductCache[$ProductId] = $Product
    return $Product
}

function Get-SalesbuildrProductCustomField {
    # Leest een custom field van het aan de regel gekoppelde product. De quote-regel
    # (QuoteItemResponseDto) heeft ZELF geen customFields; die zitten op het product
    # (IdentifiedEntityResponseDto.customFields). Eerst inline op $Line.product proberen
    # (indien de quote-response ze meelevert), anders het product ophalen (gecachet).
    # $null als er geen gekoppeld product is of het veld ontbreekt/leeg is.
    param($Line, [string]$FieldName)

    if ($null -eq $Line.product -or [string]::IsNullOrWhiteSpace($Line.product.id)) {
        return $null
    }

    # 1) Inline op de regel meegeleverd? (de quote-response levert customFields soms mee)
    $cf = $Line.product.customFields
    if ($cf -and ($cf.PSObject.Properties.Name -contains $FieldName)) {
        $val = $cf.$FieldName
        if (-not [string]::IsNullOrWhiteSpace([string]$val)) { return ([string]$val).Trim() }
    }

    # 2) Fallback: pas hier het product ophalen (gecachet) en customFields lezen —
    #    NIET eerder, zodat een inline-treffer geen extra API-call kost.
    $Product = Get-SalesbuildrProductById -ProductId $Line.product.id
    $cf = $Product.customFields
    if ($cf -and ($cf.PSObject.Properties.Name -contains $FieldName)) {
        $val = $cf.$FieldName
        if (-not [string]::IsNullOrWhiteSpace([string]$val)) { return ([string]$val).Trim() }
    }

    return $null
}

function Get-SalesbuildrProductInternalId {
    # Leest het product-veld 'internalProductId' van het aan de regel gekoppelde product.
    # LET OP: de inline product-referentie op de quote-regel (IdentifiedEntityResponseDto)
    # draagt alléén id/name/externalIdentifier/labels/customFields — NIET internalProductId.
    # Daarom wordt hier altijd het volledige product opgehaald (gecachet via
    # Get-SalesbuildrProductById). $null als er geen gekoppeld product is of het veld leeg is.
    param($Line)

    if ($null -eq $Line.product -or [string]::IsNullOrWhiteSpace($Line.product.id)) {
        return $null
    }

    $Product = Get-SalesbuildrProductById -ProductId $Line.product.id
    $val = $Product.internalProductId
    if (-not [string]::IsNullOrWhiteSpace([string]$val)) { return ([string]$val).Trim() }

    return $null
}

function Resolve-AfasLineItem {
    # Bepaalt per SB-quote-regel de AFAS-itemcode (ItCd) én het regeltype (VaIt):
    #   - mpn aanwezig                          -> ItCd = mpn, VaIt = "2" (artikel)
    #   - geen mpn, hoofdcategorie = 'Diensten' -> Kind = 'diensten', ItCd = internalProductId
    #     (mag leeg zijn); of de regel een werksoort (VaIt=1) of een TXT-regel wordt, hangt af
    #     van of internalProductId in AFAS bestaat — dat wordt LATER (stap 2b/2c) bepaald,
    #     zodat de bestaanscontrole per unieke code kan worden ge-dedupliceerd.
    #   - geen van beide                        -> $null (regel is niet naar AFAS te mappen)
    # Diensten-items worden NOOIT in AFAS aangemaakt: bestaat internalProductId in AFAS dan
    # wordt het een werksoort-regel, anders een TXT-regel (opportunity wordt niet overgeslagen).
    param($Line, $CategoryParentMap, [string]$DienstenMainCategoryId)

    if (-not [string]::IsNullOrWhiteSpace($Line.mpn)) {
        return [pscustomobject]@{ ItemCode = ([string]$Line.mpn).Trim(); VaIt = '2'; Kind = 'artikel'; Name = $Line.name }
    }

    # Geen mpn: alleen regels onder de hoofdcategorie 'Diensten' worden via internalProductId
    # herleid; andere mpn-loze regels zijn niet naar AFAS te mappen.
    $MainCatId = Get-SalesbuildrMainCategoryId -CategoryId $Line.category.id -ParentMap $CategoryParentMap
    if ($MainCatId -and $MainCatId -eq $DienstenMainCategoryId) {
        $InternalId = Get-SalesbuildrProductInternalId -Line $Line
        $ItemCode   = if ($InternalId) { $InternalId } else { '' }
        return [pscustomobject]@{ ItemCode = $ItemCode; VaIt = '1'; Kind = 'diensten'; Name = $Line.name }
    }

    return $null
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

    # Config, mapping en sync-datums staan allemaal in configs\
    If (-Not (Test-Path "$PSScriptRoot\configs")) {
        New-Item -ItemType Directory -Path "$PSScriptRoot\configs" | Out-Null
    }

    $config = (Read-XMLConfig -Path "$PSScriptRoot\configs\config.xml").configuration

    # State: beide flow-watermerken staan in één bestand (Flow1 = Forecasts,
    # Flow2 = Opportunities). Zie Get-/Set-SyncWatermark.
    $SyncStateFile = "$PSScriptRoot\configs\LastSyncDates.xml"

    $LastForecastSync    = Get-SyncWatermark -Path $SyncStateFile -Name 'Flow1'
    $LastOpportunitySync = Get-SyncWatermark -Path $SyncStateFile -Name 'Flow2'

    # Test-override: <OverrideDays>N</OverrideDays> in het state-bestand laat
    # beide flows syncen vanaf N dagen geleden (middernacht lokale tijd).
    # De Flow1/Flow2-watermerken worden aan het eind van de run gewoon
    # bijgewerkt; Set-SyncWatermark laat de OverrideDays-knoop ongemoeid.
    $OverrideDays = Get-SyncOverrideDays -Path $SyncStateFile
    if ($null -ne $OverrideDays) {
        $OverrideDate        = (Get-Date).Date.AddDays(-$OverrideDays)
        $LastForecastSync    = $OverrideDate
        $LastOpportunitySync = $OverrideDate
        Write-Log WARNING "OverrideDays actief ($OverrideDays): beide flows syncen vanaf $($OverrideDate.ToString('o'))"
    }

    # Credentials, omgeving en MODE komen plaintext uit config.xml.
    # afas.token is het <token>…</token> XML; Connect-Afas base64-encodeert
    # die zelf. MODE=TEST schakelt naar resttest.afas.online.
    # SelectSingleNode + InnerText: werkt zowel met CDATA als met ge-escapete tekst.
    $Mode              = $config.mode
    $AfasOmgeving      = $config.afas.omgeving
    $AfasApiToken      = $config.SelectSingleNode('afas/token').InnerText
    $SalesbuildrApiKey = $config.salesbuildr.apikey
    $SalesbuildrUrl    = $config.salesbuildr.url

    # SB-hoofdcategorie 'Diensten': regels onder deze hoofdcategorie hebben geen mpn en
    # worden via het product-veld internalProductId naar AFAS herleid (werksoort als het
    # in AFAS bestaat, anders een TXT-regel). Ontbreekt de config-waarde -> val terug op
    # de bekende id, zodat bestaande configs zonder deze sleutel blijven werken.
    $DienstenMainCatId = $config.salesbuildr.diensten_maincategory_id
    if ([string]::IsNullOrWhiteSpace($DienstenMainCatId)) { $DienstenMainCatId = 'UyOpp42UPGy3LKgSOQGX' }

    # Flow-schakelaars uit config.xml (<flows><flow1>/<flow2>). Ontbrekend -> aan.
    $Flow1Enabled = ConvertTo-ConfigBool -Value $config.flows.flow1 -Default $true
    $Flow2Enabled = ConvertTo-ConfigBool -Value $config.flows.flow2 -Default $true

    foreach ($entry in @{ 'afas.omgeving'      = $AfasOmgeving
                          'afas.token'         = $AfasApiToken
                          'salesbuildr.apikey' = $SalesbuildrApiKey
                          'salesbuildr.url'    = $SalesbuildrUrl }.GetEnumerator()) {
        if ([string]::IsNullOrWhiteSpace($entry.Value)) {
            throw "Vereiste config.xml-waarde ontbreekt of is leeg: $($entry.Key)"
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

    # Mapping SalesBuildr HOOFDcategorie -> AFAS artikelgroep (Grp), uit
    # mapping-artikelgroepen.xml. Alleen hoofdcategorieën worden gemapt: een quote-regel
    # draagt een (sub)categorie, die wordt via de SB-categorieboom eerst naar zijn
    # hoofdcategorie herleid (zie $CategoryParentMap hieronder). Alleen hoofdcategorieën
    # met een ingevulde AFAS-id worden opgenomen; een (nog) niet gemapte hoofdcategorie
    # ontbreekt in de map en laat stap 2b het artikel overslaan. Gebruikt in Flow 2
    # stap 2b bij het aanmaken van ontbrekende artikels.
    $ArtikelgroepMap     = @{}   # SB hoofdcategorie.id -> AFAS artikelgroep-code (Grp)
    $ArtikelgroepNaamMap = @{}   # SB hoofdcategorie.id -> AFAS artikelgroep-omschrijving (naam, alleen voor logging)
    $MappingXml = [xml](Get-Content "$PSScriptRoot\configs\mapping-artikelgroepen.xml" -Raw)
    foreach ($c in $MappingXml.'mapping-artikelgroepen'.categorie) {
        if ($c.'SB-maincat-id' -and -not [string]::IsNullOrWhiteSpace($c.'AFAS-id')) {
            $ArtikelgroepMap[$c.'SB-maincat-id']     = $c.'AFAS-id'
            $ArtikelgroepNaamMap[$c.'SB-maincat-id'] = $c.'AFAS-naam'
        }
    }
    Write-Log INFO "$($ArtikelgroepMap.Count) artikelgroep-mapping(s) (SB-hoofdcategorie -> Grp) geladen uit mapping-artikelgroepen.xml"

    # SB-categorieboom: alle categorieën met hun parent ophalen (GET /public-api/category)
    # zodat een quote-regel-(sub)categorie naar zijn hoofdcategorie herleid kan worden —
    # alleen hoofdcategorieën zijn op AFAS gemapt. Eén keer per run opgehaald.
    $CategoryParentMap = Get-SalesbuildrCategoryParentMap
    Write-Log INFO "$($CategoryParentMap.Count) SB-categorie(ën) opgehaald voor hoofdcategorie-herleiding"


    ####################################################################
    # FLOW 1 — AFAS Forecasts → SalesBuildr Opportunities
    ####################################################################

    if (-not $Flow1Enabled) {
        Write-Log INFO "=== Flow 1 is uitgeschakeld in config.xml (flows/flow1) — overgeslagen ==="
    }
    else {
        Write-Log INFO "=== Flow 1: AFAS Forecasts → SalesBuildr Opportunities ==="
        Write-Log INFO "Delta sinds: $LastForecastSync"

        $AfasForecasts = Invoke-AfasGetConnectorFiltered -Connector $ConnForecastGet -SinceDate $LastForecastSync

        Write-Log INFO "$($AfasForecasts.Count) gewijzigde Forecasts gevonden"

        # Batch-watermark: alleen als élke Forecast succesvol is verwerkt (of legitiem
        # overgeslagen omdat al gesloten) schuift de sync-datum op. Overgeslagen door een
        # ontbrekende organisatie of een fout -> datum blijft staan, zodat de volgende run
        # het opnieuw probeert. Aanname: fouten worden binnen 48u opgelost (zie email-log).
        $Flow1Complete = $true

        foreach ($Forecast in $AfasForecasts) {
            Write-Log INFO "[Flow 1] Forecast $($Forecast.forecast) | '$($Forecast.forecastOmschrijving)' | verkooprelatie $($Forecast.verkooprelatie) | volgnummer $($Forecast.volgnummer)"

            # Bevestigde veldnamen (Salesbuildr_Forecasts GetConnector):
            #   forecast             = uniek AFAS forecast-id -> QuId (voorcalc-offertenr)
            #   volgnummer           = CmForecast SqNo (@SqNo)  ← de updatesleutel
            #   verkooprelatie       = AFAS debiteurcode (= @PrId in CmForecast) — NIET voor companyExtId
            #   organisatie          = AFAS Organisatienummer -> koppeling naar SB Company
            #   forecastOmschrijving = naam
            #
            # De externalIdentifier codeert alles wat Flow 2 nodig heeft om ZONDER
            # re-fetch verder te kunnen (zie ConvertFrom-ForecastExternalId).
            $ExternalId   = "afas-Forecast-$($Forecast.forecast)-$($Forecast.volgnummer)-$($Forecast.verkooprelatie)"
            # De org-sync schrijft companies weg als "afas-Organisatie-{organisatienummer}".
            $CompanyExtId = "afas-Organisatie-$($Forecast.organisatie)"

            # Organisatie (nog) niet gesynchroniseerd naar SalesBuildr -> loggen en overslaan.
            # TODO: deze waarschuwingen ook opnemen in de notificatie-email (zie docs/TODO.md).
            $Company = Get-SalesbuildrCompanyByExtId -ExternalId $CompanyExtId
            if ($null -eq $Company) {
                Write-Log WARNING "[Flow 1] Organisatie $($Forecast.organisatie) niet gevonden in SalesBuildr ($CompanyExtId) — Forecast '$($Forecast.forecastOmschrijving)' overgeslagen"
                $Flow1Complete = $false
                continue
            }

            # Sla over als de Opportunity al gesloten is in SalesBuildr.
            $ExistingOpportunity = Get-SalesbuildrOpportunityByExtId -ExternalId $ExternalId
            if ($null -ne $ExistingOpportunity -and $ExistingOpportunity.statusId -eq "closed") {
                Write-Log INFO "[Flow 1] Opportunity al gesloten in SalesBuildr ($ExternalId) — overgeslagen"
                continue
            }

            # Klant-contactpersoon: opzoeken op e-mailadres ('contactpersoonMail' uit de
            # GetConnector). Contact is optioneel: geen match -> waarschuwen en de
            # Opportunity zónder contact upserten (Forecast wordt NIET overgeslagen).
            $ContactId = $null
            if (-not [string]::IsNullOrWhiteSpace($Forecast.contactpersoonMail)) {
                $Contact = Get-SalesbuildrContactByEmail -Email $Forecast.contactpersoonMail
                if ($null -ne $Contact) {
                    $ContactId = $Contact.id
                    Write-Log INFO "[Flow 1] Contact gevonden op $($Forecast.contactpersoonMail) (id: $ContactId)"
                } else {
                    Write-Log WARNING "[Flow 1] Geen SalesBuildr-contact gevonden op e-mail '$($Forecast.contactpersoonMail)' — Opportunity wordt zonder contact opgeslagen"
                }
            }

            $SalesbuildrOpportunity = @{
                # externalIdentifier wordt meegegeven via de URL, NIET in de body (UpsertOpportunityDto)
                name           = $Forecast.forecastOmschrijving
                companyExtId   = $CompanyExtId
                # AFAS scoringkans is 0–100; SalesBuildr probability is een fractie 0–1
                # ("probability must not be greater than 1"), dus delen door 100.
                probability    = [double]$Forecast.scoringkans / 100
                onetimeRevenue = $Forecast.bedragVerwacht
                # Owner (verantwoordelijke) is VERPLICHT bij de opportunity-upsert
                # ("Either ownerId or ownerExtId is required"). De owner is een SalesBuildr
                # *user*; de GetConnector levert diens interne SalesBuildr user-id direct
                # aan in 'verantwoordelijkeOwnerID', dus koppelen we op ownerId.
                ownerId        = $Forecast.verantwoordelijkeOwnerID
            }
            if ($null -ne $ContactId) {
                $SalesbuildrOpportunity.contactId = $ContactId
            }
            if ($null -ne $Forecast.einddatumVerwacht) {
                $SalesbuildrOpportunity.expectedCloseDate = ([datetime]$Forecast.einddatumVerwacht).ToString("yyyy-MM-dd")
            }

            Write-Log INFO "[Flow 1] Opportunity upsert in SalesBuildr: $ExternalId ('$($Forecast.forecastOmschrijving)')"
            try {
                Invoke-SalesbuildrUpsertOpportunity -ExternalId $ExternalId -Body $SalesbuildrOpportunity | Out-Null
            } catch {
                Write-Log ERROR "[Flow 1] Fout bij upsert Opportunity '$($Forecast.forecastOmschrijving)': $_"
                $Flow1Complete = $false
            }
        }
    }

    ####################################################################
    # FLOW 2 — Gesloten SalesBuildr Opportunities → AFAS Voorcalculatieregels
    ####################################################################

    if (-not $Flow2Enabled) {
        Write-Log INFO "=== Flow 2 is uitgeschakeld in config.xml (flows/flow2) — overgeslagen ==="
    }
    else {
        Write-Log INFO "=== Flow 2: Gesloten Opportunities → AFAS Voorcalculatieregels ==="
        Write-Log INFO "Delta sinds: $LastOpportunitySync"

        $ClosedOpportunities = Get-SalesbuildrClosedOpportunities -SinceDate $LastOpportunitySync

        Write-Log INFO "$($ClosedOpportunities.Count) gesloten Opportunities gevonden"

        # Batch-watermark voor Flow 2 (zie toelichting bij Flow 1).
        $Flow2Complete = $true

        # ── AFAS-schrijfacties (veiligheidsschakelaar) ──
        # $false (standaard): Flow 2 schrijft volledig naar AFAS — artikels (FbItemArticle),
        # AFAS-quotation (KnQuotation) én Forecast-sluiting (CmForecast, G/N). Zet op $true om
        # Flow 2 tijdelijk ON HOLD te zetten (alleen ophalen + categoriseren, geen writes); het
        # watermerk schuift dan bewust NIET op zodat dezelfde Opportunities later opnieuw
        # verwerkt worden.
        $AfasWritesOnHold = $false
        if ($AfasWritesOnHold) {
            Write-Log WARNING "Flow 2: AFAS-schrijfacties staan ON HOLD — geen artikels/quotations/Forecast-updates; alleen ophalen + inspectie. Watermerk wordt niet opgeschoven."
            $Flow2Complete = $false
        }

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
        $WonQuoteLines     = @{}   # OpportunityId → array van quote-regels (alleen Won)
        $WonQuoteTitles    = @{}   # OpportunityId → SB-quote title (→ KnQuotation.Ds)

        foreach ($Opportunity in $ClosedOpportunities) {
            # Bevestigd veldnaam: id (OpportunityResponseDto)
            $OpportunityId = $Opportunity.id
            Write-Log INFO "[Flow 2] Opportunity $OpportunityId | externalId $($Opportunity.externalIdentifier)"

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

            if ($null -ne $Quote) {
                Write-Log INFO "[Flow 2] Quote $($Quote.id) (nr $($Quote.number)) | status '$($Quote.status)' | klant '$($Quote.company.name)'"
            }

            # ── Inspectie: alle beschikbare velden per quote-item dumpen (tijdelijk uit) ──
            # Diagnostische data-dump per quote-regel. Uitgecommentarieerd nu de per-regel
            # data in kaart is; her-inschakelen voor debugging door het blok te ontcommentariëren.
            <#
            if ($null -ne $Quote -and $Quote.items) {
                Write-Log INFO "[$OpportunityId] Quote-items ($($Quote.items.Count)) — data-dump ter inspectie:"
                $ItemIndex = 0
                foreach ($InspectItem in $Quote.items) {
                    $ItemIndex++
                    $Blok = [System.Text.StringBuilder]::new()
                    [void]$Blok.AppendLine("  ┌─ item $ItemIndex/$($Quote.items.Count) " + ('─' * 40))
                    foreach ($Veld in $InspectItem.PSObject.Properties) {
                        $Waarde = $Veld.Value
                        if ($Waarde -is [System.Management.Automation.PSCustomObject]) {
                            [void]$Blok.AppendLine(("  │ {0,-20} :" -f $Veld.Name))
                            foreach ($SubVeld in $Waarde.PSObject.Properties) {
                                [void]$Blok.AppendLine(("  │   {0,-18} : {1}" -f $SubVeld.Name, $SubVeld.Value))
                            }
                        }
                        else {
                            [void]$Blok.AppendLine(("  │ {0,-20} : {1}" -f $Veld.Name, $Waarde))
                        }
                    }
                    [void]$Blok.Append("  └" + ('─' * 48))
                    Write-Log INFO $Blok.ToString()
                }
            }
            #>

            if ($null -ne $Quote -and $Quote.status -eq 'approved') {
                # ── Won ──
                # Bevestigd veldnaam: items (QuoteResponseDto) — NIET 'lines'
                $Lines = $Quote.items
                $WonQuoteLines[$OpportunityId]  = $Lines
                $WonQuoteTitles[$OpportunityId] = $Quote.title
                $WonOpportunities += $Opportunity

                Write-Log INFO "[$OpportunityId] WON — primaire quote 'approved' ($($Lines.Count) regel(s)); artikels + voorcalc + Forecast sluiten (G)"
            } else {
                # ── Lost ──
                $Reden = if ($null -eq $Quote) { "geen primaire quote" } else { "primaire quote status = '$($Quote.status)'" }
                $LostOpportunities += $Opportunity

                Write-Log INFO "[$OpportunityId] LOST — $Reden; alleen Forecast sluiten (N)"
            }
        }

        Write-Log INFO "Categorisatie: $($WonOpportunities.Count) Won (G), $($LostOpportunities.Count) Lost (N)"

        # ── Stap 2b: Regels resolven + ontbrekende Artikels aanmaken (alleen Won) ──

        # Alle quote-regels over alle Won-quotations, plat geslagen.
        $AllWonLines = @($WonQuoteLines.Values | ForEach-Object { $_ })

        # Resolve elke regel naar een AFAS-itemcode (ItCd) + regeltype (VaIt):
        #   mpn aanwezig                 -> ItCd = mpn, VaIt = "2" (artikel) -> aanmaken indien afwezig
        #   geen mpn, hoofdcat Diensten  -> Kind = 'diensten', ItCd = internalProductId (mag leeg);
        #                                   werksoort (bestaat in AFAS) of TXT-regel (bestaat niet) -> zie 2b/2c
        #   geen van beide               -> onmapbare regel -> hele opportunity vasthouden (zie 2c)
        # De resolutie per regel (op quote-item-id) wordt in stap 2c hergebruikt.
        $LineResolution = @{}
        foreach ($Line in $AllWonLines) {
            $LineResolution[$Line.id] = Resolve-AfasLineItem -Line $Line `
                -CategoryParentMap $CategoryParentMap -DienstenMainCategoryId $DienstenMainCatId
        }

        # Itemcodes die niet in AFAS beschikbaar zijn (ontbrekende artikelgroep-mapping of
        # een fout bij aanmaken van een artikel) -> in stap 2c wordt de HELE opportunity
        # overgeslagen (anders wijst de voorcalc-regel naar een niet-bestaand item) en blijft
        # de Forecast open. Zie de skip-logica in stap 2c. Diensten-regels komen hier NOOIT
        # in: ze degraderen naar een TXT-regel i.p.v. de opportunity vast te houden.
        $FailedItemCodes = @()

        # Diensten (Kind='diensten', VaIt=1): worden NOOIT aangemaakt. Per unieke, niet-lege
        # internalProductId controleren of die in AFAS bestaat -> $DienstenExists. Bestaat de
        # code dan wordt het een werksoort-regel, anders (leeg of onbekend) een TXT-regel;
        # de keuze valt in stap 2c. Diensten worden nooit in $FailedItemCodes gezet.
        $DienstenExists = @{}
        $DienstenCodes  = @($LineResolution.Values |
            Where-Object { $_ -and $_.Kind -eq 'diensten' -and -not [string]::IsNullOrWhiteSpace($_.ItemCode) } |
            ForEach-Object { $_.ItemCode } | Sort-Object -Unique)
        foreach ($Code in $DienstenCodes) {
            $Bestaat = $null -ne (Get-AfasArtikelByItemCode -Connector $ConnArtikelenGet -ItemCode $Code)
            $DienstenExists[$Code] = $Bestaat
            Write-Log INFO ("[Flow 2] Dienst [internalProductId {0}] | bestaat in AFAS: {1} -> {2}" -f `
                $Code, $Bestaat, $(if ($Bestaat) { 'werksoort-regel (VaIt=1)' } else { 'TXT-regel' }))
        }

        # Artikelen (VaIt=2): de unieke mpn's; aanmaken indien afwezig.
        $AllItemCodes = @($LineResolution.Values |
            Where-Object { $_ -and $_.Kind -eq 'artikel' } |
            ForEach-Object { $_.ItemCode } | Sort-Object -Unique)

        Write-Log INFO "$($AllItemCodes.Count) unieke artikelcode(s) (mpn) en $($DienstenCodes.Count) diensten-code(s) (internalProductId) gevonden in de gewonnen quotations"

        foreach ($ItemCode in $AllItemCodes) {
            # Bronregel voor de omschrijving (name), de item-ids en de categorie.
            $BronRegel = $AllWonLines | Where-Object { $_.mpn -eq $ItemCode } | Select-Object -First 1

            # SB-(sub)categorie van de regel -> via de categorieboom naar de hoofdcategorie
            # -> gemapte AFAS-artikelgroep (code + naam). Alleen hoofdcategorieën zijn gemapt.
            $SbCatId    = $BronRegel.category.id
            $SbCatNaam  = $BronRegel.category.name
            $MainCatId  = Get-SalesbuildrMainCategoryId -CategoryId $SbCatId -ParentMap $CategoryParentMap
            $Artikelgroep     = Get-AfasArtikelgroep -Category $BronRegel.category -ArtikelgroepMap $ArtikelgroepMap -CategoryParentMap $CategoryParentMap
            # $ArtikelgroepNaam alleen voor de (tijdelijk uitgezette) diagnostische dump hieronder.
            # $ArtikelgroepNaam = if ($MainCatId -and $ArtikelgroepNaamMap.ContainsKey($MainCatId)) { $ArtikelgroepNaamMap[$MainCatId] } else { $null }

            # Bestaanscontrole: per mpn een gefilterde lookup (itemCode = ...), i.p.v. de
            # volledige catalogus van 30.000+ artikels op te halen.
            $BestaatInAfas = $null -ne (Get-AfasArtikelByItemCode -Connector $ConnArtikelenGet -ItemCode $ItemCode)

            # Diagnostische per-artikel dump (tijdelijk uit; ontcommentarieer voor debugging).
            <#
            Write-Log INFO ("[Flow 2] Artikel '{0}' | mpn/ItCd {1} | item-id {2} | product-id {3} | SB-cat '{4}' ({5}) | SB-hoofdcat {6} | AFAS-cat {7} ({8}) | bestaat in AFAS: {9}" -f `
                $BronRegel.name, $ItemCode, $BronRegel.id, $BronRegel.product.id, `
                $SbCatNaam, $SbCatId, `
                $(if ($MainCatId) { $MainCatId } else { '-' }), `
                $(if ($ArtikelgroepNaam) { "'$ArtikelgroepNaam'" } else { '-' }), `
                $(if ($Artikelgroep) { $Artikelgroep } else { 'niet gemapt' }), `
                $BestaatInAfas)
            #>

            if ($BestaatInAfas) {
                Write-Log INFO "Artikel [$ItemCode] bestaat al in AFAS — overgeslagen"
                continue
            }

            # Artikelgroep (Grp) is verplicht bij aanmaken; ontbreekt de mapping -> overslaan.
            if ([string]::IsNullOrWhiteSpace($Artikelgroep)) {
                Write-Log WARNING "Artikel [$ItemCode] overgeslagen: categorie '$SbCatNaam' (id $SbCatId, hoofdcategorie $(if ($MainCatId) { $MainCatId } else { 'onbekend' })) niet gemapt in mapping-artikelgroepen.xml"
                $FailedItemCodes += $ItemCode
                $Flow2Complete = $false
                continue
            }

            if ($AfasWritesOnHold) {
                Write-Log WARNING "[ON HOLD] Artikel [$ItemCode] zou aangemaakt worden (groep $Artikelgroep) — niet aangemaakt"
                continue
            }

            try {
                New-AfasArtikel -Connector $ConnArtikelenUpdate -ItemCode $ItemCode `
                    -Omschrijving $BronRegel.name -Artikelgroep $Artikelgroep
            } catch {
                # Aanmaken mislukt (API-fout e.d.): net als een ontbrekende mapping
                # markeren als 'niet aangemaakt', zodat de HELE opportunity in stap 2c
                # wordt overgeslagen — geen quotation, Forecast blijft open.
                Write-Log ERROR "Fout bij aanmaken Artikel [$ItemCode]: $_"
                $FailedItemCodes += $ItemCode
                $Flow2Complete = $false
            }
        }

        # ── Stap 2c: AFAS-quotation (KnQuotation, voorcalculatie) aanmaken per Won-Opportunity ──

        foreach ($Opportunity in $WonOpportunities) {
            $OpportunityId = $Opportunity.id

            # De externalIdentifier codeert de volledige CmForecast-sleutel (zie
            # ConvertFrom-ForecastExternalId); een re-fetch van de Forecast is niet nodig.
            $ForecastKey = ConvertFrom-ForecastExternalId -ExternalIdentifier $Opportunity.externalIdentifier
            if ($null -eq $ForecastKey) {
                Write-Log ERROR "[$OpportunityId] Onverwacht externalIdentifier-formaat '$($Opportunity.externalIdentifier)' — kan forecast-id/PrId/SqNo niet parsen, overgeslagen"
                $Flow2Complete = $false
                continue
            }

            $Lines = $WonQuoteLines[$OpportunityId]

            # Idempotentie: bestaat de AFAS-quotation al? (filter op offerte = forecast-id).
            # Zo ja: het AANMAKEN overslaan — maar NIET de hele opportunity, want het
            # sluiten van de Forecast (ViOp=G) hieronder moet nog gebeuren. Anders zou een
            # eerdere run die de quotation wél aanmaakte maar de close miste, de forecast
            # nooit meer op G zetten (de close is idempotent: PUT met dezelfde G/OrAF).
            $QuotationExists = $null -ne (Get-AfasQuotation -Connector $ConnVoorcalcGet -OfferteNr $ForecastKey.ForecastId)

            if ($QuotationExists) {
                Write-Log INFO "[$OpportunityId] AFAS-quotation al aanwezig ($($ForecastKey.ForecastId)) — aanmaken overgeslagen, Forecast wordt wel gesloten"
            }
            else {
                # Elke regel moet naar een AFAS-item te mappen zijn (artikel via mpn, of een
                # Diensten-regel via internalProductId) én — voor artikelen — beschikbaar zijn.
                # Zodra één regel onmapbaar is (geen mpn en niet in hoofdcategorie Diensten) of
                # naar een niet-beschikbaar artikel verwijst (niet aangemaakt), slaan we de HELE
                # opportunity over: een onvolledige voorcalculatie of een regel naar een niet-
                # bestaand item mag niet ontstaan. De AFAS-quotation wordt NIET aangemaakt en de
                # Forecast wordt NIET gesloten — die blijft open, watermerk blijft staan zodat de
                # opportunity opnieuw wordt geprobeerd. Diensten-regels veroorzaken NOOIT een skip:
                # ze worden een werksoort (bestaat in AFAS) of degraderen naar een TXT-regel.
                $Probleemregels = @()
                foreach ($Line in $Lines) {
                    $Res = $LineResolution[$Line.id]
                    if ($null -eq $Res) {
                        $Probleemregels += "regel '$($Line.name)' (geen mpn en niet in hoofdcategorie Diensten)"
                    }
                    elseif ($Res.Kind -ne 'diensten' -and $FailedItemCodes -contains $Res.ItemCode) {
                        $Probleemregels += "$($Res.Kind) '$($Res.ItemCode)' (niet beschikbaar in AFAS)"
                    }
                }
                if ($Probleemregels.Count -gt 0) {
                    Write-Log WARNING "[$OpportunityId] Overgeslagen (quotation niet aangemaakt, Forecast blijft open): $($Probleemregels -join '; ')"
                    $Flow2Complete = $false
                    continue
                }

                $Regels = @()
                foreach ($Line in $Lines) {
                    # Resolutie uit stap 2b. Hierboven is al gegarandeerd dat $Res niet $null is.
                    # QuoteItemResponseDto: 'quantity', 'price' = verkoopprijs p/st (Upri),
                    # 'cost' = kostprijs p/st (AmCo).
                    $Res = $LineResolution[$Line.id]

                    if ($Res.Kind -eq 'diensten') {
                        # Diensten-regel: bestaat internalProductId in AFAS -> werksoort-regel
                        # (VaIt=1, ItCd = internalProductId); anders (leeg of onbekend in AFAS)
                        # -> TXT-regel (geen ItCd, de regelnaam gaat mee als tekst).
                        $CodeBestaat = (-not [string]::IsNullOrWhiteSpace($Res.ItemCode)) -and $DienstenExists[$Res.ItemCode]
                        if ($CodeBestaat) {
                            # === Werksoort-regel — payload volgt van gebruiker (baseline hieronder) ===
                            $Regels += @{
                                ItemCode  = $Res.ItemCode
                                Soort     = '1'
                                Aantal    = $Line.quantity
                                Prijs     = $Line.price
                                Kostprijs = $Line.cost
                            }
                        }
                        else {
                            # === TXT-regel — payload volgt van gebruiker ===
                            $Regels += @{
                                Kind      = 'txt'
                                Tekst     = $Line.name
                                Aantal    = $Line.quantity
                                Prijs     = $Line.price
                                Kostprijs = $Line.cost
                            }
                        }
                    }
                    else {
                        # Artikel (mpn, VaIt=2). ItemCode/Soort komen uit de resolutie.
                        $Regels += @{
                            ItemCode  = $Res.ItemCode
                            Soort     = $Res.VaIt
                            Aantal    = $Line.quantity
                            Prijs     = $Line.price
                            Kostprijs = $Line.cost
                        }
                    }
                }

                if ($AfasWritesOnHold) {
                    Write-Log WARNING "[ON HOLD] [$OpportunityId] AFAS-quotation ($($ForecastKey.ForecastId), $($Regels.Count) regel(s)) zou aangemaakt worden — niet aangemaakt"
                }
                else {
                    try {
                        New-AfasQuotation `
                            -Connector $ConnVoorcalcUpdate `
                            -QuId      $ForecastKey.ForecastId `
                            -DbId      $ForecastKey.PrId `
                            -FcNo      $ForecastKey.SqNo `
                            -Ds        $WonQuoteTitles[$OpportunityId] `
                            -Regels    $Regels
                    } catch {
                        Write-Log ERROR "[$OpportunityId] Fout bij aanmaken AFAS-quotation: $_"
                        $Flow2Complete = $false
                        continue
                    }
                }
            }

            # ── Sluiten van de Won-Forecast (ViOp=G) ──
            # OrAF = totaal offertebedrag = Σ price × quantity × (1 - discount) over de quote-regels.
            if ($AfasWritesOnHold) {
                Write-Log WARNING "[ON HOLD] [$OpportunityId] Forecast [SqNo $($ForecastKey.SqNo)] zou als Won (G) gesloten worden (OrAF $(Get-SalesbuildrQuoteTotal -Items $Lines)) — niet gesloten"
                continue
            }

            try {
                Close-AfasForecast -Connector $ConnForecastUpdate `
                    -PrId $ForecastKey.PrId -SqNo $ForecastKey.SqNo `
                    -ViOp "G" -OrAF (Get-SalesbuildrQuoteTotal -Items $Lines)
            } catch {
                Write-Log ERROR "[$OpportunityId] Fout bij sluiten Forecast [SqNo $($ForecastKey.SqNo)] als Won (G) in AFAS: $_"
                $Flow2Complete = $false
                continue
            }
        }

        # ── Stap 2d: Lost-Opportunities — alleen de AFAS Forecast op N sluiten ──
        #
        # Geen artikels/voorcalc: een Lost-forecast wordt enkel afgesloten. De
        # CmForecast-sleutel (verkooprelatie/PrId + volgnummer/SqNo) parsen we uit de
        # externalIdentifier (zelfde formaat als de Won-tak) — geen re-fetch nodig.
        foreach ($Opportunity in $LostOpportunities) {
            $OpportunityId = $Opportunity.id

            $ForecastKey = ConvertFrom-ForecastExternalId -ExternalIdentifier $Opportunity.externalIdentifier
            if ($null -eq $ForecastKey) {
                Write-Log ERROR "[$OpportunityId] Onverwacht externalIdentifier-formaat '$($Opportunity.externalIdentifier)' — kan PrId/SqNo niet parsen, overgeslagen"
                $Flow2Complete = $false
                continue
            }

            if ($AfasWritesOnHold) {
                Write-Log WARNING "[ON HOLD] [$OpportunityId] Forecast [SqNo $($ForecastKey.SqNo)] zou als Lost (N) gesloten worden — niet gesloten"
                continue
            }

            try {
                Close-AfasForecast -Connector $ConnForecastUpdate -PrId $ForecastKey.PrId -SqNo $ForecastKey.SqNo -ViOp "N"
            } catch {
                Write-Log ERROR "[$OpportunityId] Fout bij sluiten Forecast [SqNo $($ForecastKey.SqNo)] als Lost (N) in AFAS: $_"
                $Flow2Complete = $false
            }
        }
    }


    ####################################################################
    # State bijwerken
    ####################################################################

    # Per-flow watermark: alleen opschuiven als de flow aan staat én de batch
    # volledig succesvol is verwerkt. Een uitgeschakelde flow laat zijn datum
    # ongemoeid; bij overgeslagen/gefaalde records blijft de datum ook staan zodat
    # de volgende run die records opnieuw ophaalt en probeert.
    If (-not $Flow1Enabled) {
        Write-Log INFO "Flow 1 uitgeschakeld — state ongewijzigd"
    } ElseIf ($Flow1Complete) {
        Set-SyncWatermark -Path $SyncStateFile -Name 'Flow1' -Date (Get-Date)
        Write-Log INFO "Flow 1 state bijgewerkt"
    } else {
        Write-Log WARNING "Flow 1 state NIET bijgewerkt — niet alle Forecasts verwerkt; wordt opnieuw geprobeerd bij volgende run"
    }

    If (-not $Flow2Enabled) {
        Write-Log INFO "Flow 2 uitgeschakeld — state ongewijzigd"
    } ElseIf ($Flow2Complete) {
        Set-SyncWatermark -Path $SyncStateFile -Name 'Flow2' -Date (Get-Date)
        Write-Log INFO "Flow 2 state bijgewerkt"
    } else {
        Write-Log WARNING "Flow 2 state NIET bijgewerkt — niet alle Opportunities verwerkt; wordt opnieuw geprobeerd bij volgende run"
    }

} catch {
    Write-Log ERROR "Fatale fout: $_"
}

#endregion
