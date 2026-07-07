<#
.SYNOPSIS
    TEST-script: haalt de PDF op van goedgekeurde SalesBuildr quotes en zet die
    om naar Base64.

.DESCRIPTION
    Zelfstandig testscript (geen onderdeel van de sync-flow). Vindt de goedgekeurde
    quotes op DEZELFDE manier als Sync-Forecasts.ps1 Flow 2, zodat het exact dezelfde
    quotes oppakt als de echte sync. Stappen:
      1. Haalt gesloten Opportunities op (statusId:closed) en filtert client-side op
         closedAt > watermerk (met <OverrideDays>-override, zie hieronder).
      2. Bepaalt per opportunity de primaire quote (primary:true) en houdt alleen de
         'approved' quotes over.
      3. Download per quote de PDF (GET /public-api/quote/{id}/pdf) als RAW bytes.
      4. Zet die bytes om naar Base64 en logt de lengte.
      5. Optioneel: schrijft de .pdf en .b64.txt weg naar -OutDir voor inspectie.

    LET OP het venster: er wordt gevensterd op de OPPORTUNITY-sluitdatum (closedAt),
    NIET op de quote-goedkeuringsdatum (approvedAt). Een quote wordt vaak eerder
    goedgekeurd dan de opportunity sluit; venstert je op approvedAt dan mis je quotes
    waarvan de opportunity nú pas sluit. Flow 2 venstert ook op closedAt.

    LET OP: de PDF-endpoint geeft de PDF als binaire download (GEEN JSON/Base64).
    Daarom Invoke-WebRequest met -OutFile / .Content (byte[]); ToBase64String doet
    de encoding client-side. Invoke-RestMethod zou de binary als tekst decoderen
    en corrumperen — dus NIET gebruiken voor de PDF-call.

.PARAMETER Max
    Beperk het aantal quotes dat verwerkt wordt (0 = alle). Handig om even te testen.

.PARAMETER OutDir
    Map om de opgehaalde .pdf + .b64.txt in weg te schrijven. Leeg = niets wegschrijven.

.NOTES
    File Name   : SB_PDF.ps1
    Date        : 2026-07-07
    Config      : configs\config.xml (zelfde plaintext config als Sync-Forecasts.ps1)
#>

[CmdletBinding()]
param(
    [int]$Max = 0,
    [string]$OutDir = ''
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

function ConvertFrom-ForecastExternalId {
    # Parseert de door Flow 1 gezette Opportunity-externalIdentifier:
    #   afas-Forecast-{forecast}-{volgnummer}-{verkooprelatie}
    # Levert de AFAS-sleutels die de upload straks nodig heeft:
    #   ForecastId = uniek AFAS forecast-id  -> QuId (AFAS quotation-id)
    #   SqNo       = volgnummer
    #   PrId       = verkooprelatie          -> debiteurcode
    # Geeft $null bij een onverwacht formaat.
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
    # eerste run alles ophaalt. Naam is de flow-sleutel, hier 'SBPdf'.
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
    # getal N betekent: sync vanaf N dagen geleden (middernacht lokale tijd).
    # Leeg/ontbrekend/ongeldig -> $null, dan geldt het eigen watermerk.
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
    # andere knopen (Flow1/Flow2/OverrideDays) ongemoeid. Round-trip ('o') formaat.
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

function Get-SalesbuildrClosedOpportunities {
    # Haalt alle Opportunities met statusId 'closed' op via paginering (size/from)
    # en filtert client-side op sluitingsdatum closedAt > $SinceDate. Identiek aan
    # de discovery in Sync-Forecasts.ps1 Flow 2, zodat dit testscript exact DEZELFDE
    # opportunities/quotes vindt als de echte sync.
    #
    # LET OP — geen server-side datumfilter mogelijk: de SalesBuildr search-API kent
    # alleen gelijkheidsfilters ('veld:waarde'), geen >/< operatoren. Vandaar het
    # server-side statusId:closed-filter + een client-side datumfilter op 'closedAt'
    # (de sluitingsdatum, NIET 'updatedAt'; records zonder closedAt worden overgeslagen).
    #
    # Waarom niet filteren op de quote (statusId:approved + approvedAt)? De quote-
    # goedkeuringsdatum ligt vaak vóór het sluiten van de opportunity, dus een venster
    # op approvedAt mist quotes waarvan de opportunity nú pas sluit. Flow 2 vensterd
    # op closedAt van de opportunity — dit script doet dat ook, voor pariteit.
    param([datetime]$SinceDate)

    $allResults = @()
    $size       = 100
    $from       = 0

    do {
        $response = Invoke-SalesbuildrRequest `
            -Uri "$($Global:SalesbuildrUri)/public-api/opportunity?filters=statusId%3Aclosed&size=$size&from=$from"
        $allResults += $response.results
        $from       += $size
    } while ($allResults.Count -lt $response.total -and $response.results.Count -gt 0)

    return $allResults | Where-Object { $_.closedAt -and ([datetime]$_.closedAt) -gt $SinceDate }
}

function Get-SalesbuildrPrimaryQuote {
    # Haalt de PRIMAIRE Quote (primary:true) op voor een Opportunity, of $null.
    # Identiek aan Sync-Forecasts.ps1: filter-sleutel is 'opportunity.id' (NIET
    # 'opportunityId' — die geeft total=0), dubbele punt URL-encoded als %3A.
    # De aanroeper bepaalt 'approved' op basis van $quote.status.
    param([string]$OpportunityId)

    $response = Invoke-SalesbuildrRequest `
        -Uri "$($Global:SalesbuildrUri)/public-api/quote?filters=opportunity.id%3A$OpportunityId&size=100"
    $quotes = $response.results

    return $quotes | Where-Object { $_.primary -eq $true } | Select-Object -First 1
}

function Get-SalesbuildrQuotePdfBase64 {
    # Download de PDF van één quote als RAW bytes en geeft die als Base64-string terug.
    # GEEN Invoke-RestMethod: die decodeert binaire content als tekst en corrumpeert
    # de PDF. Invoke-WebRequest.Content is een byte[]; ToBase64String encodeert die.
    # Geeft $null bij 404 (geen PDF voor dat id).
    param([string]$QuoteId)

    try {
        $response = Invoke-WebRequest `
            -Uri "$($Global:SalesbuildrUri)/public-api/quote/$QuoteId/pdf" `
            -Headers $Global:SalesbuildrHeaders -Method Get
    } catch {
        if ($_.Exception.Response.StatusCode -eq 404) { return $null }
        throw
    }

    # PowerShell 7: .Content is byte[]. Windows PowerShell 5.1 kan een string geven —
    # val dan terug op RawContentStream.
    $bytes = $response.Content
    if ($bytes -isnot [byte[]]) {
        $stream = $response.RawContentStream
        $stream.Position = 0
        $ms = New-Object System.IO.MemoryStream
        $stream.CopyTo($ms)
        $bytes = $ms.ToArray()
    }

    return [pscustomobject]@{
        Bytes  = $bytes
        Base64 = [System.Convert]::ToBase64String($bytes)
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

    if ($OutDir -and -not (Test-Path $OutDir)) {
        New-Item -ItemType Directory -Path $OutDir | Out-Null
        Write-Log INFO "Uitvoermap aangemaakt: $OutDir"
    }

    # Delta-window: eigen watermerk-knoop 'SBPdf' in het gezamenlijke state-bestand
    # (configs\LastSyncDates.xml). Bewust een aparte knoop, zodat dit testscript de
    # productie-watermerken Flow1/Flow2 niet verstoort. Zelfde regels als
    # Sync-Forecasts.ps1: ontbrekend -> Epoch (alles), en <OverrideDays>N</OverrideDays>
    # overschrijft het watermerk naar N dagen geleden (middernacht lokale tijd).
    $SyncStateFile = "$PSScriptRoot\configs\LastSyncDates.xml"
    $SinceDate     = Get-SyncWatermark -Path $SyncStateFile -Name 'SBPdf'

    $OverrideDays = Get-SyncOverrideDays -Path $SyncStateFile
    if ($null -ne $OverrideDays) {
        $SinceDate = (Get-Date).Date.AddDays(-$OverrideDays)
        Write-Log WARNING "OverrideDays actief ($OverrideDays): sync vanaf $($SinceDate.ToString('o'))"
    }

    Write-Log INFO "=== TEST: PDF ophalen van goedgekeurde SB-quotes ==="
    Write-Log INFO "Delta sinds (opportunity closedAt >): $SinceDate"

    # Watermerk schuift alleen op als élke gevonden quote succesvol is verwerkt
    # (zelfde batch-regel als de flows in Sync-Forecasts.ps1). Een 404 (geen PDF) of
    # fout houdt de datum vast, zodat de volgende run die quote(s) opnieuw probeert.
    $Complete = $true

    # DEZELFDE discovery als Flow 2: gesloten opportunities in het venster -> primaire
    # quote -> alleen de 'approved' quotes. Zo vindt dit script exact de quotes die de
    # sync als Won verwerkt.
    $ClosedOpportunities = @(Get-SalesbuildrClosedOpportunities -SinceDate $SinceDate)
    Write-Log INFO "$($ClosedOpportunities.Count) gesloten Opportunity(s) gevonden"

    # Bepaal per opportunity de primaire quote, houd alleen de goedgekeurde over en
    # parse meteen de AFAS-sleutels (verkooprelatie/PrId + quotation-id/QuId) uit de
    # opportunity-externalIdentifier, zodat elke PDF straks aan het juiste AFAS-record
    # gekoppeld kan worden. We bewaren een rijk object { Quote, PrId, QuId, SqNo }.
    $Quotes = @()
    foreach ($Opportunity in $ClosedOpportunities) {
        $OpportunityId = $Opportunity.id
        try {
            $Quote = Get-SalesbuildrPrimaryQuote -OpportunityId $OpportunityId
        } catch {
            Write-Log ERROR "[$OpportunityId] Fout bij ophalen primaire quote: $_"
            $Complete = $false
            continue
        }

        if ($null -eq $Quote) {
            Write-Log INFO "[$OpportunityId] Geen primaire quote (Lost) — overgeslagen"
            continue
        }
        if ($Quote.status -ne 'approved') {
            Write-Log INFO "[$OpportunityId] Primaire quote $($Quote.id) status '$($Quote.status)' (geen 'approved') — overgeslagen"
            continue
        }

        # AFAS-sleutels uit de externalIdentifier (afas-Forecast-{fc}-{sqno}-{pr}).
        $ForecastKey = ConvertFrom-ForecastExternalId -ExternalIdentifier $Opportunity.externalIdentifier
        if ($null -eq $ForecastKey) {
            Write-Log WARNING "[$OpportunityId] Onverwacht externalIdentifier-formaat '$($Opportunity.externalIdentifier)' — kan verkooprelatie/quotation-id niet parsen, overgeslagen"
            $Complete = $false
            continue
        }

        $Quotes += [pscustomobject]@{
            Quote      = $Quote
            PrId       = $ForecastKey.PrId        # verkooprelatie (debiteurcode)
            QuId       = $ForecastKey.ForecastId  # AFAS quotation-id (= forecast-id)
            SqNo       = $ForecastKey.SqNo
        }
    }

    Write-Log INFO "$($Quotes.Count) goedgekeurde quote(s) gevonden"

    if ($Max -gt 0 -and $Quotes.Count -gt $Max) {
        Write-Log WARNING "Beperkt tot de eerste $Max quote(s) via -Max"
        $Quotes = $Quotes[0..($Max - 1)]
    }

    $Ok = 0; $NoPdf = 0; $Failed = 0

    foreach ($Item in $Quotes) {
        $Quote    = $Item.Quote
        $QuoteId  = $Quote.id
        $QuoteNr  = $Quote.number
        Write-Log INFO "[Quote $QuoteId] nr $QuoteNr | '$($Quote.title)' | klant '$($Quote.company.name)' | AFAS verkooprelatie $($Item.PrId) | AFAS quotation-id $($Item.QuId)"

        try {
            $Pdf = Get-SalesbuildrQuotePdfBase64 -QuoteId $QuoteId
        } catch {
            Write-Log ERROR "[Quote $QuoteId] Fout bij ophalen PDF: $_"
            $Failed++
            $Complete = $false
            continue
        }

        if ($null -eq $Pdf) {
            Write-Log WARNING "[Quote $QuoteId] Geen PDF beschikbaar (404) — overgeslagen"
            $NoPdf++
            $Complete = $false
            continue
        }

        $isPdf = $Pdf.Bytes.Length -ge 4 -and
                 $Pdf.Bytes[0] -eq 0x25 -and $Pdf.Bytes[1] -eq 0x50 -and   # %P
                 $Pdf.Bytes[2] -eq 0x44 -and $Pdf.Bytes[3] -eq 0x46        # DF
        Write-Log INFO ("[Quote {0}] PDF opgehaald: {1} bytes | Base64 {2} tekens | %PDF-magic: {3}" -f `
            $QuoteId, $Pdf.Bytes.Length, $Pdf.Base64.Length, $isPdf)

        if (-not $isPdf) {
            Write-Log WARNING "[Quote $QuoteId] Respons begint NIET met %PDF — mogelijk geen geldige PDF"
        }

        if ($OutDir) {
            $safeNr  = if ($QuoteNr) { $QuoteNr } else { $QuoteId }
            $pdfPath  = Join-Path $OutDir "Quote-$safeNr.pdf"
            $b64Path  = Join-Path $OutDir "Quote-$safeNr.b64.txt"
            $metaPath = Join-Path $OutDir "Quote-$safeNr.meta.json"
            [System.IO.File]::WriteAllBytes($pdfPath, $Pdf.Bytes)
            Set-Content -Path $b64Path -Value $Pdf.Base64 -Encoding ASCII

            # Metadata + base64 samen: alles wat de AFAS-upload straks nodig heeft, aan
            # elkaar gekoppeld. PrId (verkooprelatie) en QuId (AFAS quotation-id) komen
            # uit de opportunity-externalIdentifier. FileName = 'Quote-{nr}.pdf'.
            $meta = [ordered]@{
                afasVerkooprelatie = $Item.PrId   # PrId (debiteurcode)
                afasQuotationId    = $Item.QuId   # QuId (= forecast-id)
                afasForecastSqNo   = $Item.SqNo
                sbQuoteId          = $QuoteId
                sbQuoteNumber      = $QuoteNr
                fileName           = "Quote-$safeNr.pdf"
                pdfBytes           = $Pdf.Bytes.Length
                fileDataBase64     = $Pdf.Base64
            }
            Set-Content -Path $metaPath -Value ($meta | ConvertTo-Json) -Encoding UTF8
            Write-Log INFO "[Quote $QuoteId] Weggeschreven: $pdfPath + $b64Path + $metaPath"
        }

        # TODO (wacht op payload van de gebruiker): AFAS-upload. De base64 zit in
        # $Pdf.Base64, met de AFAS-sleutels $Item.PrId (verkooprelatie) en $Item.QuId
        # (quotation-id) erbij. Straks: bouw de door de gebruiker aangeleverde payload
        # en POST die naar de juiste AFAS UpdateConnector (bijv. via een
        # Send-AfasQuotationPdf-helper). Zie de todo-lijst.

        $Ok++
    }

    Write-Log INFO "=== Klaar: $Ok gelukt, $NoPdf zonder PDF, $Failed mislukt ==="

    # Watermerk alleen opschuiven als élke quote succesvol is verwerkt. Bij een
    # 404/fout blijft de datum staan zodat de volgende run die quote(s) opnieuw
    # probeert. Set-SyncWatermark laat OverrideDays en Flow1/Flow2 ongemoeid — dus
    # zolang <OverrideDays> gezet is, wint die op elke run alsnog van dit watermerk.
    if ($Complete) {
        Set-SyncWatermark -Path $SyncStateFile -Name 'SBPdf' -Date (Get-Date)
        Write-Log INFO "SBPdf state bijgewerkt"
    } else {
        Write-Log WARNING "SBPdf state NIET bijgewerkt — niet alle quotes verwerkt; wordt opnieuw geprobeerd bij volgende run"
    }

} catch {
    Write-Log ERROR "Fatale fout: $_"
}

#endregion
