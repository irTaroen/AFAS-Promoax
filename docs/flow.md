# Sync-Forecasts — Execution Flow

## Setup & bootstrap (lines 607–685)

- Clear error state (`$Error.Clear()`) and enter the top-level `try` (:607-608).
- Ensure `configs/` dir exists — creates it if missing (:611-613).
- Load config from `configs/config.xml` into `$config` (:615).
- Read both watermarks from the **single** state file `configs/LastSyncDates.xml` (:619-622):
  - `Flow1` node → `$LastForecastSync` (Flow 1)
  - `Flow2` node → `$LastOpportunitySync` (Flow 2)
  - Read via `Get-SyncWatermark -Path -Name` (:93-107); a missing file or node defaults to the Unix epoch (1970), so an initial run pulls everything. The old separate `LastForecastSyncDate.xml` / `LastSyncDate_Opportunities.xml` files are gone.
- **OverrideDays test override** (:624-634, `Get-SyncOverrideDays` :109-126): if the state file's optional `<OverrideDays>` node contains an integer N, **both** `$LastForecastSync` and `$LastOpportunitySync` are replaced by N days ago at midnight local time (`(Get-Date).Date.AddDays(-N)`), and a WARNING `"OverrideDays actief (N): …"` is logged. Empty/missing node → no override (normal watermarks apply); a non-numeric value logs a WARNING and is ignored. The Flow1/Flow2 watermarks are still written at the end of the run as usual, and `Set-SyncWatermark` never touches the `OverrideDays` node — the override stays active (and warns) every run until manually cleared.
- Read credentials straight from the plaintext `configs/config.xml` (:636-644) — AFAS token via `$config.SelectSingleNode('afas/token').InnerText` (works with the CDATA block), Salesbuildr API key via `$config.salesbuildr.apikey`. No decryption, no `Configuration.psm1`.
- Parse the flow toggles via `ConvertTo-ConfigBool` (:646-648, function :55-70): `$Flow1Enabled` / `$Flow2Enabled` from `<flows><flow1>/<flow2>>`; missing/empty/unrecognized values default to `$true` (both flows on), so an older config without `<flows>` is unaffected.
- Validate that the four required config values are non-empty, throwing otherwise (:650-657).
- Connect to both APIs (:659-660):
  - `Connect-Afas` sets global REST URL (TEST mode → `resttest.afas.online`) + `AfasToken` header (base64-encoding the token).
  - `Connect-Salesbuildr` sets the base URI + `api-key` header.
- Resolve connector names from config into `$ConnForecastGet`, `$ConnForecastUpdate`, etc. (:662-668).
- Load the article-group mapping from `configs/mapping-artikelgroepen.xml` into `$ArtikelgroepMap` (SB `category.id` → AFAS `Grp`) and `$ArtikelgroepNaamMap` (logging-only names) (:670-685). Only `<categorie>` entries with a non-empty `AFAS-id` are loaded; anything else counts as "not mapped" in Flow 2 step 2b.

## Flow 1 — AFAS Forecasts → Salesbuildr Opportunities (lines 688–782)

- If `$Flow1Enabled` is `$false` (:692-694), logs `"=== Flow 1 is uitgeschakeld in config.xml (flows/flow1) — overgeslagen ==="` and the whole flow body is skipped.
- Fetch changed forecasts (:699): `Invoke-AfasGetConnectorFiltered` (:164-191) queries the `Salesbuildr_Forecasts` GetConnector server-side filtered on `gewijzigd > $LastForecastSync` (**operator 4 = greater-than**; 5 is *less*-than), paginating 100 at a time. The filter value is local time `yyyy-MM-ddTHH:mm:ss` — no `ToUniversalTime`, no trailing `Z` (that triggers a server error).
- Set `$Flow1Complete = $true` (:707) — the batch-watermark flag; any skip/error flips it to `$false`.
- Loop each forecast (:709):
  - Build `$ExternalId = "afas-Forecast-{forecast}-{volgnummer}-{verkooprelatie}"` and `$CompanyExtId = "afas-Organisatie-{organisatie}"` (:721-723). The external id encodes the full CmForecast key so Flow 2 needs no re-fetch.
  - **Company existence check** (:727-732): if the Salesbuildr Company doesn't exist (org not yet synced), log WARNING, set `$Flow1Complete = $false`, and `continue` (skip).
  - **Already-closed check** (:735-739): if the Opportunity exists and is `statusId: "closed"`, skip it (this is a legitimate skip — does not clear the flag).
  - **Client contact** (:744-753): if `contactpersoonMail` is set, resolve it via `Get-SalesbuildrContactByEmail` (exact case-insensitive `email` match); no match logs a WARNING and the Opportunity is upserted **without** a contact — the forecast is not skipped.
  - Build the payload (:755-772): `name`, `companyExtId`, `probability`, `onetimeRevenue`, the **required** `ownerId` (= `verantwoordelijkeOwnerID`, a SB user id supplied by the GetConnector), plus optionally `contactId` and `expectedCloseDate`.
  - Upsert via `PUT /public-api/opportunity/ext/{ExternalId}` (:774-780); on error, log ERROR and clear the flag.

## Flow 2 — Closed Opportunities → AFAS Voorcalculatieregels (lines 784–1019)

- If `$Flow2Enabled` is `$false` (:788-790), logs `"=== Flow 2 is uitgeschakeld in config.xml (flows/flow2) — overgeslagen ==="` and the whole flow body is skipped.
- Fetch closed opportunities (:795): `Get-SalesbuildrClosedOpportunities` (:450-477) pages through `statusId:closed` (size/from pagination), then client-side filters `closedAt > $LastOpportunitySync` (not `updatedAt`, which moves on any edit; records without a `closedAt` are skipped) — the SB search API has equality filters only, no date range operators.
- Set `$Flow2Complete = $true` (:800).

### Stap 2a — categorize Won/Lost on the primary quote (:802-858)

- For each closed opportunity, fetch its **primary** quote via `Get-SalesbuildrPrimaryQuote` (:534-564) — `GET /public-api/quote?filters=opportunity.id:{id}` (filter key is `opportunity.id`, **not** `opportunityId`), then picks the quote with `primary: true`. **No fallback** to any other approved quote. Only a genuine API/network error clears the flag and skips (:828-835).
- **Won** = primary quote exists and `status == "approved"` → collect its `items` into `$WonQuoteLines[opportunityId]` and queue the opportunity for steps 2b/2c (:841-848).
- **Lost** = no primary quote, or primary quote `status != "approved"` → queue for step 2d only (:849-855). A missing/unapproved primary quote is **not** an error and does not clear the flag.

### Stap 2b — create missing articles in AFAS (Won only) (:860-920)

- Flatten all Won quote lines and collect unique item codes from **`mpn`** (:863-870) — the AFAS item code (`ItCd`) is always the `mpn`; the `product` field is nullable (free-form lines) and is not used. Lines without an `mpn` have no article code.
- Per unique `mpn`: a targeted per-item existence lookup via `Get-AfasArtikelByItemCode` (:211-228, `Salesbuildr_Artikelen` filtered on `itemCode`) — no bulk catalog fetch (AFAS holds 30,000+ articles) (:891).
- Resolve the article group via `Get-AfasArtikelgroep` (:282-296): quote line `category.id` → `$ArtikelgroepMap` → `Grp`, one direct hop (no `/public-api/category` fetch, no cost-center indirection). An unmapped category logs a WARNING, records the `mpn` in `$FailedItemCodes`, and clears the flag (:906-911).
- Create missing articles via `New-AfasArtikel` (`FbItemArticle`; `Ds` = quote item name capped at 100 chars, `Grp` = mapped group) (:913-919); on error, clear the flag.

### Stap 2c — create the AFAS quotation (KnQuotation, voorcalculatie) per Won opportunity (:922-995)

- Parse the CmForecast key (`ForecastId`/`SqNo`/`PrId`) straight from the opportunity's `externalIdentifier` via `ConvertFrom-ForecastExternalId` (:72-91, regex `^afas-Forecast-(?<fc>\d+)-(?<sqno>\d+)-(?<pr>.+)$`) — no re-fetch of the AFAS Forecast. An unexpected format → log ERROR, clear flag, skip (:929-934).
- **Idempotency check** (:939-943): `Get-AfasQuotation` filters `Salesbuildr_Voorcalculatie` on `offerte = {ForecastId}` (the bare AFAS forecast id, e.g. `11310` — no `SB-` prefix). If it already exists, skip.
- **Whole-opportunity skip on unmapped articles** (:951-957): if any of its lines' `mpn`s are in `$FailedItemCodes`, skip the entire opportunity (WARNING, flag cleared) — a voorcalc line must not reference a non-existent article.
- Build line items (:959-975) — `ItemCode` (= `mpn`), `Aantal` (= `quantity`), `Prijs` (= `price`), `Kostprijs` (= `cost`); lines without an `mpn` are logged (WARNING) and skipped.
- Create the `KnQuotation` via `New-AfasQuotation` (:977-988): `@QuId` = ForecastId, `DbId` = PrId, `FcNo` = SqNo, lines as one `KnQuotationLine.Element` array; on error, clear flag.
- Closing the Won Forecast (`Close-AfasForecast`, `ViOp = "G"` + `OrAF` via `Get-SalesbuildrQuoteTotal`) is still deliberately **commented out** pending a later step (:990-994), so Won forecasts are not closed yet.

### Stap 2d — close Lost forecasts (:997-1018)

- For each Lost opportunity, parse the CmForecast key from its `externalIdentifier` via `ConvertFrom-ForecastExternalId` (same as 2c, no re-fetch; bad format → ERROR, clear flag) and close it in AFAS via `Close-AfasForecast` with `ViOp = "N"` (no `OrAF`, no articles/voorcalculatie). Errors clear the flag.

## State update (lines 1022–1046)

- A disabled flow (`$Flow1Enabled` / `$Flow2Enabled` = `$false`) leaves its watermark node untouched and logs `"Flow N uitgeschakeld — state ongewijzigd"` — no warning, since nothing was attempted.
- Otherwise, advance each watermark independently, but only if its flag is still true:
  - `$Flow1Complete` → `Set-SyncWatermark -Name 'Flow1'` writes the current date to the `Flow1` node of `configs/LastSyncDates.xml` (:1032-1034).
  - `$Flow2Complete` → `Set-SyncWatermark -Name 'Flow2'` writes to the `Flow2` node (:1041-1043).
- `Set-SyncWatermark` (:128-144) touches only its own node (round-trip `'o'` format) — the other flow's node and the `OverrideDays` node are left as-is. An active OverrideDays override therefore survives every run until manually cleared.
- If a flag is false, the date is held so the next run retries the unprocessed records.

## Error handling (lines 1048–1050)

- Any unhandled exception bubbles to the outer `catch` and is logged as a fatal error — note this means a fatal crash mid-run leaves both watermarks untouched, so the next run re-processes the batch.

## Naming note

- The script was renamed on disk from `Sync-Afas2Salesbuildr-Forecasts.ps1` to `Sync-Forecasts.ps1`; the script header, CLAUDE.md and the API guides now all use the new name.
