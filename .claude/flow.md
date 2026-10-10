# Sync-Forecasts — Execution Flow

Four independent flows, each with its own config toggle (`<flows><flowN>`) and watermark node (`FlowN` in `configs/last-sync-dates.xml`), run in sequence within one script invocation:

- **Flow 1** — AFAS Forecasts → Salesbuildr Opportunities
- **Flow 2 (Items)** — won closed Opportunities → create missing AFAS articles (`FbItemArticle`)
- **Flow 3 (Quotations)** — won closed Opportunities → update the existing AFAS quotation (`KnQuotation`, voorcalculatie, created by AFAS) with the voorcalculatieregels + close the Forecast; lost → close the Forecast only
- **Flow 4 (PDF)** — won closed Opportunities → attach the SB quote PDF to the AFAS quotation as a dossieritem (`KnSubject`)

Flows 2, 3 and 4 each independently fetch their own batch of closed Opportunities (own watermark) and categorize Won/Lost via the same shared helper (`Split-ClosedOpportunities`), so none of them block on another flow running in the *same* invocation — Flow 3 re-checks article availability itself (tolerating Flow 2 being off/behind/failed), and Flow 4 holds its watermark until the AFAS quotation exists (tolerating Flow 3 being off/behind/failed).

## Setup & bootstrap (lines 1023–1150)

- Clear error state (`$Error.Clear()`) and enter the top-level `try` (:1023-1024).
- Ensure `configs/` dir exists — creates it if missing (:1027-1029).
- Load config from `configs/config.xml` into `$config` (:1031).
- Read all **four** watermarks from the single state file `configs/last-sync-dates.xml` (:1038-1041):
  - `Flow1` node → `$LastForecastSync`
  - `Flow2` node → `$LastItemsSync`
  - `Flow3` node → `$LastQuotationsSync`
  - `Flow4` node → `$LastAttachmentSync`
  - Read via `Get-SyncWatermark -Path -Name` (:108-124); a missing file or node defaults to `2026-01-01` local time (`$DefaultDate`), so an initial run pulls everything from that date forward.
- **OverrideDays test override** (:1043-1055, `Get-SyncOverrideDays -Value` :125-142): if `configs/config.xml`'s top-level `<OverrideDays>` element contains an integer N, **all four** watermarks above are replaced by N days ago at midnight local time (`(Get-Date).Date.AddDays(-N)`), and a WARNING `"OverrideDays actief (N): alle flows syncen vanaf …"` is logged. Empty/missing element → no override (normal watermarks apply); a non-numeric value logs a WARNING and is ignored. The four Flow watermarks are still written independently at the end of the run as usual; the override lives in `config.xml` (not the state file), so it stays active (and warns) every run until manually cleared there.
- Read credentials straight from the plaintext `configs/config.xml` (:1057-1065) — AFAS token via `$config.SelectSingleNode('afas/token').InnerText` (works with the CDATA block), Salesbuildr API key via `$config.salesbuildr.apikey`. No decryption, no `Configuration.psm1`.
- Read `<salesbuildr><diensten_maincategory_id>` into `$DienstenMainCatId` (:1067-1072), falling back to the known id `UyOpp42UPGy3LKgSOQGX` when absent/blank — used by `Resolve-AfasLineItem` in Flows 2 and 3 to tell an artikel line from a Diensten (service) line.
- Read Flow 4's `<afas><kn_subject_stid>` / `<kn_subject_usid>` into `$KnSubjectStId` / `$KnSubjectUsId` (:1074-1078), falling back to `46` / `53307._sa_salesbldr` when absent.
- Parse the flow toggles via `ConvertTo-ConfigBool` (:1080-1088, function :70-86): `$Flow1Enabled`/`$Flow2Enabled`/`$Flow3Enabled`/`$Flow4Enabled` from `<flows><flow1>/<flow2>/<flow3>/<flow4>>`; missing/empty/unrecognized values default to `$true` (all four flows on), so an older config without `<flows>` (or missing individual nodes) is unaffected.
- Validate that the four required config values (`afas.omgeving`, `afas.token`, `salesbuildr.apikey`, `salesbuildr.url`) are non-empty, throwing otherwise (:1090-1097).
- Connect to both APIs (:1099-1100):
  - `Connect-Afas` sets global REST URL (TEST mode → `resttest.afas.online`) + `AfasToken` header (base64-encoding the token).
  - `Connect-Salesbuildr` sets the base URI + `api-key` header.
- **Credential check** (:1102-1115, `Test-AfasConnection` :180-192 / `Test-SalesbuildrConnection` :637-649): a light GET against each API validates the credentials before any flow logic runs — `Test-AfasConnection` does `GET {AfasRestUrl}/metainfo`, `Test-SalesbuildrConnection` does `GET {SalesbuildrUri}/public-api/opportunity?size=1`; each returns `$true` on success, `$false` on HTTP 401 (any other error, e.g. network/5xx, bubbles up unhandled). Both are checked — not short-circuited — so a single run surfaces both an invalid AFAS token and an invalid Salesbuildr API key at once, each logged as its own WARNING (`"AFAS-token ongeldig (HTTP 401) ..."` / `"SalesBuildr API-key ongeldig (HTTP 401) ..."`). If either check fails, the script `return`s immediately — no flow runs, all four watermarks are left untouched.
- Resolve connector names from config into `$ConnForecastGet`, `$ConnForecastUpdate`, `$ConnArtikelenGet`, `$ConnArtikelenUpdate`, `$ConnVoorcalcGet`, `$ConnVoorcalcUpdate` (:1118-1123), plus Flow 4's `$ConnDossierGet` / `$ConnSubjectUpdate` (:1124-1126, falling back to `Salesbuildr_Dossieritems` / `KnSubject` when the config nodes are absent, so older configs keep working).
- Load the article-group mapping from `configs/mapping-artikelgroepen.xml` into `$ArtikelgroepMap` (SB main-category id → AFAS `Grp`) and `$ArtikelgroepNaamMap` (logging-only names) (:1135-1144). Only `<categorie>` entries with a non-empty `AFAS-id` are loaded; anything else counts as "not mapped" when Flow 2 tries to create an article under that main category.
- Fetch the SB category tree once per run into `$CategoryParentMap` via `Get-SalesbuildrCategoryParentMap` (:1149-1150, `GET /public-api/category`) — used by both Flow 2 and Flow 3 to walk a quote line's leaf `category.id` up to its main (root) category.

## Flow 1 — AFAS Forecasts → Salesbuildr Opportunities (lines 1153–1253)

- If `$Flow1Enabled` is `$false` (:1157-1158), logs `"=== Flow 1 is uitgeschakeld in config.xml (flows/flow1) — overgeslagen ==="` and the whole flow body is skipped.
- Fetch changed forecasts (:1164): `Invoke-AfasGetConnectorFiltered` queries the `Salesbuildr_Forecasts` GetConnector server-side filtered on `gewijzigd > $LastForecastSync` (**operator 4 = greater-than**; 5 is *less*-than), paginating 100 at a time. The filter value is local time `yyyy-MM-ddTHH:mm:ss` — no `ToUniversalTime`, no trailing `Z` (that triggers a server error).
- Set `$Flow1Complete = $true` (:1172) — the batch-watermark flag; any skip/error flips it to `$false`.
- Loop each forecast (:1174-1252):
  - Build `$ExternalId = "afas-Forecast-{forecast}-{volgnummer}-{verkooprelatie}"` and `$CompanyExtId = "afas-Organisatie-{organisatie}"` (:1186-1188). The external id encodes the full CmForecast key so Flows 3 and 4 need no re-fetch.
  - **Company existence check** (:1192-1197): if the Salesbuildr Company doesn't exist (org not yet synced), log WARNING, set `$Flow1Complete = $false`, and `continue` (skip).
  - **Already-closed check** (:1200-1204): if the Opportunity exists and is `statusId: "closed"`, skip it (this is a legitimate skip — does not clear the flag).
  - **Client contact** (:1210-1222): resolves `contactpersoonMail` via `Get-SalesbuildrContactByEmail` (exact `email` match). Contact is **required** — no e-mail or no match logs a WARNING, sets `$Flow1Complete = $false`, and skips the forecast entirely (the Opportunity is not upserted).
  - Build the payload (:1224-1243): `name`, `companyExtId`, `probability` (= `scoringkans / 100` — AFAS `scoringkans` is 0–100, Salesbuildr `probability` expects a 0–1 fraction), `onetimeRevenue`, the **required** `ownerId` (= `verantwoordelijkeOwnerID`, a SB user id supplied by the GetConnector), plus `contactId` and, if present, `expectedCloseDate`.
  - Upsert via `PUT /public-api/opportunity/ext/{ExternalId}` (:1245-1251); on error, log ERROR and clear the flag.

## Flow 2 — Items: create missing AFAS articles for won closed Opportunities

Preparatory step for Flow 3 — a `KnQuotationLine` must not reference a non-existent article, so Flow 2 makes sure the articles exist before Flow 3 inserts the quotation lines. Diensten (service) lines are **never** created here — those are resolved to a werksoort or TXT line entirely inside Flow 3.

- If `$Flow2Enabled` is `$false`, logs `"=== Flow 2 is uitgeschakeld in config.xml (flows/flow2) — overgeslagen ==="` and the whole flow body is skipped.
- Fetch closed opportunities: `Get-SalesbuildrClosedOpportunities -SinceDate $LastItemsSync` pages through `statusId:closed` (size/from pagination), then client-side filters `closedAt > SinceDate` (not `updatedAt`, which moves on any edit; records without a `closedAt` are skipped) — the SB search API has equality filters only, no date range operators. Flow 2 fetches this **independently** of Flows 3/4 — its own call, its own watermark.
- Set `$Flow2Complete = $true`.
- An `$AfasWritesOnHold2` dev switch (hardcoded `$false`) can pause all AFAS writes for this flow (fetch/categorize/log only) — used for inspection-only dry runs; flips `$Flow2Complete = $false` so the watermark doesn't advance.
- **Categorize Won/Lost** via the shared `Split-ClosedOpportunities -LogPrefix "Flow 2"` helper (see below) — only Won opportunities carry lines that might need a new article; Lost is a no-op for Flow 2.
- Flatten all Won quote lines and resolve each via `Resolve-AfasLineItem -CategoryParentMap $CategoryParentMap -DienstenMainCategoryId $DienstenMainCatId` (see "Resolving a line item" below); collect unique item codes for lines with `Kind = 'artikel'` (i.e. an `mpn`) — Diensten codes are **never** included here.
- Per unique `mpn`:
  - Resolve the SB (sub)category → main category → AFAS artikelgroep via `Get-SalesbuildrMainCategoryId` / `Get-AfasArtikelgroep` (the main-category id also keys the `Voorraad`/`Serienummer` flags).
  - A targeted per-item existence lookup via `Get-AfasArtikelByItemCode` (`Salesbuildr_Artikelen` filtered on `itemCode`) — no bulk catalog fetch (AFAS holds 30,000+ articles). If it already exists, skip (INFO) and move to the next code.
  - An unmapped category logs a WARNING and clears `$Flow2Complete` — but this does **not** skip a whole opportunity; Flow 2 has no opportunity-level concept, it simply fails to create this one article. The article then stays missing in AFAS, so Flow 3 will independently detect it via its own existence check and skip the opportunities that reference it.
  - Otherwise create the article via `New-AfasArtikel` (`FbItemArticle`; `Ds` = quote item name capped at 100 chars, `Grp` = mapped group, `BiSt` = `Voorraad` and `AdSr` = `Serienummer` booleans from the same `mapping-artikelgroepen.xml` row via `$ArtikelVlaggenMap`, default `false`); on error, clear the flag.

## Flow 3 — Quotations: update the AFAS quotation with lines and close the Forecast

- If `$Flow3Enabled` is `$false`, logs `"=== Flow 3 is uitgeschakeld in config.xml (flows/flow3) — overgeslagen ==="` and the whole flow body is skipped.
- Fetch closed opportunities the same way as Flow 2, but **independently** — own call to `Get-SalesbuildrClosedOpportunities -SinceDate $LastQuotationsSync`, own watermark (`Flow3`).
- Set `$Flow3Complete = $true`.
- An `$AfasWritesOnHold3` dev switch (hardcoded `$false`) can pause all AFAS writes for this flow the same way as Flow 2's.

### Stap 3a — categorize Won/Lost

- `Split-ClosedOpportunities -LogPrefix "Flow 3"` (see below) returns `$Outcome.Won`/`.Lost`/`.Lines`/`.Titles`; `$Outcome.AllOk = $false` (a genuine quote-fetch failure) clears `$Flow3Complete`.

### Stap 3b — resolve lines + determine AFAS availability (Won only)

- Flatten all Won quote lines and resolve each via `Resolve-AfasLineItem` — same helper Flow 2 uses, called again independently here on Flow 3's own fetched batch.
- **Diensten existence check**: for each unique non-blank Diensten `internalProductId`, `Get-AfasArtikelByItemCode` checks whether it exists in AFAS, stored in `$DienstenExists`. Diensten codes are **never** added to `$FailedItemCodes` and **never created** via `FbItemArticle` — not here, not in Flow 2.
- **Article availability check**: for each unique artikel `mpn`, `Get-AfasArtikelByItemCode` checks it **already exists** in AFAS — this is an availability check, not creation (creation is Flow 2's job). A missing `mpn` logs a WARNING and is added to `$FailedItemCodes`; this is how Flow 3 stays correct even when Flow 2 is disabled, failed, or hasn't run yet for a newly-mapped category.

### Stap 3c — update the AFAS quotation per Won opportunity

The main voorcalculatie (`KnQuotation`) is created by AFAS itself; Flow 3 only **updates** it and **inserts** the voorcalculatieregels in one `PUT KnQuotation` transaction.

- Parse the CmForecast key (`ForecastId`/`SqNo`/`PrId`) straight from the opportunity's `externalIdentifier` via `ConvertFrom-ForecastExternalId` (regex `^afas-Forecast-(?<fc>\d+)-(?<sqno>\d+)-(?<pr>.+)$`). An unexpected format → log ERROR, clear flag, skip.
- `$Lines = $WonQuoteLines[$OpportunityId]` is fetched first, since the unmapped-line guard and the payload build both need it.
- **Fetch the AFAS Forecast**: `Get-AfasForecast` queries the `Salesbuildr_Forecasts` GetConnector filtered `forecast = {ForecastId}` (operatortypes=1). Not found → WARNING, clear flag, skip (watermark held).
- **Idempotency check**: the Forecast's `statusCode` (`Get-AfasForecastStatusCode`, trimmed + upper-cased): `G` (gesloten en gescoord) or `N` (gesloten, niet gescoord) → already closed, INFO and the opportunity is skipped entirely (no voorcalc lines, no close, not a watermark hold); `O` (open) → continue; any other or empty value → WARNING, skip, watermark held (never guess, to avoid duplicate lines). This is **not** a skip that holds the watermark. (The exact `status` values are not yet confirmed against live data.)
- **Precondition**: the main voorcalc must already exist — `Get-AfasQuotation` filters `Salesbuildr_Voorcalculatie` on `offerte = {ForecastId}` (the bare AFAS forecast id, e.g. `11310`). Missing → WARNING, clear flag, skip (Forecast stays open, watermark held).
- **Whole-opportunity skip**: if any Won line is unmappable (no `mpn` and not Diensten) or is an artikel whose `mpn` is in `$FailedItemCodes`, skip the entire opportunity (WARNING, flag cleared) — a voorcalc line must not reference a non-existent or unresolved item. Diensten lines **never** trigger this — they always resolve to a werksoort or TXT line (see below).
- Build the `Regels` array — a Diensten line becomes a werksoort line (`Soort='1'`) if `$DienstenExists[$Res.ItemCode]` is true, else a TXT line (`Kind='txt'`); an artikel line keeps `ItemCode`/`Soort` from the resolution. Each carries `Aantal`/`Prijs`/`Kostprijs` from the quote line's `quantity`/`price`/`cost`. The payload comes from `ConvertTo-AfasQuotationBody` (no `-DbId`/`-FcNo` params anymore); the `$AfasWritesOnHold3` dry-run logs this same JSON in its WARNING instead of writing.
- Send via `Update-AfasQuotation` (`PUT KnQuotation`): header `@QuId` = ForecastId (Element attribute) + Fields `"@Action": "update"`, `Ds` = the SB quote's `title` (capped at 100 chars), `U1D8B1C0045A26507C9B67995789BFF16 = "G"`; `QuDa`/`DbId`/`FcNo` are no longer sent. Every `KnQuotationLine` `Fields` carries `"@Action": "insert"`. On error, clear flag and `continue` (skips the close below).
- **Closing the Won Forecast** — `Close-AfasForecast -ViOp "G" -OrAF (Get-SalesbuildrQuoteTotal -Items $Lines)` — runs right after a successful update, wrapped in its own `try`/`catch`: on error, logs ERROR, clears the flag, and `continue`s.
- **Known risk**: the line insert is **not** idempotent. If the update succeeds but the Forecast close fails, the Forecast is not yet Won, so the next run re-inserts the lines (duplicates). Such an ERROR needs manual review.

### Stap 3d — close Lost forecasts

- For each Lost opportunity, parse the CmForecast key from its `externalIdentifier` via `ConvertFrom-ForecastExternalId` (same as 3c, no re-fetch; bad format → ERROR, clear flag) and close it in AFAS via `Close-AfasForecast` with `ViOp = "N"` (no `OrAF`, no articles/voorcalculatie update). Errors clear the flag.

## Flow 4 — PDF: attach the SB quote PDF to the AFAS quotation (lines 1617–1720)

- If `$Flow4Enabled` is `$false` (:1631-1632), logs `"=== Flow 4 is uitgeschakeld in config.xml (flows/flow4) — overgeslagen ==="` and the whole flow body is skipped.
- Fetch closed opportunities (:1638) the same way as Flows 2/3, but **independently** — own call, own watermark (`Flow4`).
- Set `$Flow4Complete = $true` (:1642).
- An `$AfasWritesOnHold4` dev switch (:1645-1649, hardcoded `$false`) can pause all AFAS writes for this flow the same way as Flows 2/3's.
- Categorize via `Split-ClosedOpportunities -LogPrefix "Flow 4"` (:1653-1655) — only `$Outcome.Won` gets a PDF; Lost is a legitimate no-op (no PDF, not a skip, watermark still advances if `AllOk`).
- Loop each Won opportunity (:1657-1719):
  - Parse `ForecastId`/`PrId` from `externalIdentifier` via `ConvertFrom-ForecastExternalId` (:1662-1667) — no re-fetch.
  - **Precondition** (:1672-1676): the AFAS quotation must already exist (`Get-AfasQuotation` filtering `Salesbuildr_Voorcalculatie.offerte = {ForecastId}`, same check Flow 3 uses) — if Flow 3 hasn't created it yet (this run or a prior one), log WARNING, clear the flag, and `continue` (hold the watermark and retry next run rather than attach a PDF to a non-existent quotation).
  - **Idempotency check** (:1679-1682): `Get-AfasQuotationAttachment` queries `Salesbuildr_Dossieritems` filtered on `Offerte = {ForecastId}` (operatortypes=1); a row with `Type == StId` (config `<afas><kn_subject_stid>`) and `Ja_Nee == true` means the PDF is already attached → skip (INFO, not a flag-clearing skip) — this matters because the `KnSubject` POST is **not** idempotent, so without this check a re-run would create duplicate attachments.
  - **PDF fetch** (:1685-1696): `Get-SalesbuildrQuotePdf -QuoteId $Quote.id` does `GET /public-api/quote/{id}/pdf` via `Invoke-WebRequest` directly (**not** the JSON wrapper `Invoke-SalesbuildrRequest`, which would corrupt binary via `ConvertFrom-Json`), reading `RawContentStream.ToArray()` and returning Base64. HTTP 404 or an empty response → `$null` (logged WARNING, flag cleared, watermark held).
  - **AFAS upload** (:1705-1718): `New-AfasSubjectAttachment` POSTs `KnSubject` with `StId` (config, default `46`), `UsId` (config, default `53307._sa_salesbldr`), a `KnSubjectLink` sub-object (`ToSR=true`, `SfTp=4` always, `SfId = PrId`, `QuId = ForecastId`), and a `KnSubjectAttachment` sub-object (`FileName = "SB-Offerte-{ForecastId}.pdf"`, `FileStream` = the Base64 PDF). Any error clears the flag.

## Shared helper — `Split-ClosedOpportunities` (lines 812–878)

Categorizes gesloten Opportunities as Won or Lost based **exclusively** on the primary quote (`primary: true`, **no fallback** to any other approved quote) — used independently by Flows 2, 3 and 4 so all three apply identical Won/Lost logic and quote-line data:

- **Won**: primary quote exists and `status == "approved"` → collects `Lines[opportunityId]` (quote `items`), `Titles[opportunityId]` (quote `title`, for `KnQuotation.Ds`), `Quotes[opportunityId]` (the quote itself, e.g. for Flow 4's `Quote.id`).
- **Lost**: no primary quote, or primary quote `status != "approved"` — not an error.
- `AllOk = $false` only on a genuine quote-fetch failure (network/API); the caller then clears its own `$FlowNComplete` and holds its watermark for the whole batch.

## Resolving a line item — `Resolve-AfasLineItem` (called from Flows 2 and 3)

Each quote line resolves to an AFAS item code and `Kind`, in order:

1. **`mpn` present** → `ItemCode = mpn`, `Kind = 'artikel'`, `VaIt = "2"`.
2. **No `mpn`, main category (via `Get-SalesbuildrMainCategoryId`) is Diensten** (`$DienstenMainCatId`) → `Kind = 'diensten'`, `ItemCode` = the line's `internalProductId` (via `Get-SalesbuildrProductInternalId`, always a full `GET /public-api/product/{id}` fetch — cached in `$Global:SbProductCache`), or `''` if the product has none.
3. **Neither** → unmappable, returns `$null`.

Flow 2 only acts on `Kind = 'artikel'` results (creates missing articles). Flow 3 acts on both: `Kind = 'artikel'` results feed the article-availability check (Stap 3b) and the artikel `KnQuotationLine` shape; `Kind = 'diensten'` results feed the Diensten existence check and become a werksoort or TXT line; `$null` (unmappable) results feed the whole-opportunity skip in Stap 3c.

## State update (lines 1723–1769)

- A disabled flow (`$FlowNEnabled = $false`) leaves its watermark node untouched and logs `"Flow N uitgeschakeld — state ongewijzigd"` — no warning, since nothing was attempted.
- Otherwise, advance each watermark independently, but only if its flag is still true:
  - `$Flow1Complete` → `Set-SyncWatermark -Name 'Flow1'` (:1728-1730).
  - `$Flow2Complete` → `Set-SyncWatermark -Name 'Flow2'` (:1737-1739).
  - `$Flow3Complete` → `Set-SyncWatermark -Name 'Flow3'` (:1746-1748).
  - `$Flow4Complete` → `Set-SyncWatermark -Name 'Flow4'` (:1755-1757).
- `Set-SyncWatermark` (:144-160) touches only its own node (round-trip `'o'` format) — the other flows' nodes are left as-is. The `OverrideDays` override lives in `configs/config.xml`, a separate file `Set-SyncWatermark` never touches, so it survives every run until manually cleared there.
- If a flag is false, the date is held so the next run retries the unprocessed records.

## Error handling (lines 1765–1767)

- Any unhandled exception bubbles to the outer `catch` and is logged as a fatal error — note this means a fatal crash mid-run leaves all four watermarks untouched, so the next run re-processes every flow's batch.

## Naming note

- The script was renamed on disk from `Sync-Afas2Salesbuildr-Forecasts.ps1` to `Sync-Forecasts.ps1`; the script header, CLAUDE.md and the API guides now all use the new name.
- The original combined "Flow 2" (article creation + quotation creation + Forecast close) was split into Flow 2 (Items) and Flow 3 (Quotations); the SB quote-PDF flow, originally added as "Flow 3", was renumbered to Flow 4 to make room. See the script's own `.NOTES` release history (`v0.4`/`v0.5`) for the exact sequence.
