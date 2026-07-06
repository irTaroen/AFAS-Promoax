# Sync-Forecasts — Execution Flow

## Setup & bootstrap (lines 412–458)

- Clear error state (`$Error.Clear()`) and enter the top-level `try`.
- Load config from `configs/config.xml` into `$config` (:415).
- Ensure `configs/` dir exists — creates it if missing (:417-419).
- Parse the flow toggles via `ConvertTo-ConfigBool` (:579-580): `$Flow1Enabled` / `$Flow2Enabled` from `<flows><flow1>/<flow2>>`; missing/empty/unrecognized values default to `$true` (both flows on), so an older config without `<flows>` is unaffected.
- Read the two watermark state files (:422-428):
  - `configs/LastForecastSyncDate.xml` → `$LastForecastSync` (Flow 1)
  - `configs/LastSyncDate_Opportunities.xml` → `$LastOpportunitySync` (Flow 2)
  - Both default to the Unix epoch (1970) on first run, so an initial run pulls everything.
- Read credentials straight from the plaintext `configs/config.xml` (:434-447) — AFAS token via `$config.SelectSingleNode('afas/token').InnerText` (works with the CDATA block), Salesbuildr API key via `$config.salesbuildr.apikey`. No decryption, no `Configuration.psm1` — that module has been removed.
- Connect to both APIs (:449-450):
  - `Connect-Afas` sets global REST URL + `AfasToken` header (base64-encoding the token).
  - `Connect-Salesbuildr` sets the base URI + `api-key` header.
- Resolve connector names from config into `$ConnForecastGet`, `$ConnForecastUpdate`, etc. (:453-458).

## Flow 1 — AFAS Forecasts → Salesbuildr Opportunities (lines 461–528)

- If `$Flow1Enabled` is `$false` (:624-625), logs `"=== Flow 1 is uitgeschakeld in config.xml (flows/flow1) — overgeslagen ==="` and the whole flow body is skipped.
- Fetch changed forecasts: `Invoke-AfasGetConnectorFiltered` queries the `Salesbuildr_Forecasts` GetConnector server-side filtered on `gewijzigd > $LastForecastSync` (operator 5 = greater-than), paginating 100 at a time.
- Set `$Flow1Complete = $true` (:478) — the batch-watermark flag; any skip/error flips it to `$false`.
- Loop each forecast (:480):
  - Build `$ExternalId = "afas-Forecast-{SqNo}"` and `$CompanyExtId = "afas-Organisatie-{organisatie}"` (:486-491).
  - **Company existence check** (:496-501): if the Salesbuildr Company doesn't exist (org not yet synced), log WARNING, set `$Flow1Complete = $false`, and `continue` (skip).
  - **Already-closed check** (:504-508): if the Opportunity exists and is `statusId: "closed"`, skip it (this is a legitimate skip — does not clear the flag).
  - Build the payload (:510-519): `name`, `companyExtId`, `probability`, `onetimeRevenue`, and optionally `expectedCloseDate`.
  - Upsert via `PUT /public-api/opportunity/ext/{ExternalId}` (:522-527); on error, log ERROR and clear the flag.

## Flow 2 — Closed Opportunities → AFAS Voorcalculatieregels (lines 531–670)

- If `$Flow2Enabled` is `$false` (:720-721), logs `"=== Flow 2 is uitgeschakeld in config.xml (flows/flow2) — overgeslagen ==="` and the whole flow body is skipped.
- Fetch closed opportunities: `Get-SalesbuildrClosedOpportunities` pages through `statusId:closed` (size/from pagination), then client-side filters `updatedAt > $LastOpportunitySync`.
- Set `$Flow2Complete = $true` (:543).

### Stap 2a/2b — categorize Won/Lost, collect quote lines & create missing articles (:545-604)

- For each closed opportunity, fetch its primary quote (`Get-SalesbuildrPrimaryQuote`) — queries `GET /public-api/quote?filters=opportunityId:{id}`, picks `primary: true`, or falls back to the most recent approved quote. On error/missing quote → log, clear flag, skip. Store each quote's items in `$AllQuotationLines` keyed by opportunity id.
- Collect unique item codes from `product.externalIdentifier` across all lines (:578-580).
- Fetch existing AFAS articles (`Salesbuildr_Artikelen`) and their itemCodes (:585-586).
- Create any missing articles in AFAS via `New-AfasArtikel` (`FbItemArticle`), using the quote item's name as description; on error, clear the flag.

### Stap 2c — create voorcalculaties per opportunity (:606-670)

- Derive `$ForecastSqNo` from the opportunity's `externalIdentifier` (`afas-Forecast-{SqNo}`) and build `$QuId = "SB-{SqNo}"` (:611-612).
- Parse the CmForecast key (`ForecastId`/`SqNo`/`PrId`) straight from the opportunity's `externalIdentifier` via `ConvertFrom-ForecastExternalId` — no re-fetch of the AFAS Forecast. If the identifier doesn't match the expected format → log ERROR, clear flag, skip.
- **Idempotency check** (:625-630): `Get-AfasVoorcalculatie` filters `Salesbuildr_Voorcalculatie` on `offerte = QuId`. If it already exists, just close the Forecast and continue.
- Build line items (:634-644) — `ItemCode`/`Omschrijving`/`Aantal`/`Prijs` from each quote item.
- Create the `KnQuotation` via `New-AfasVoorcalculatie`; on success set `$VoorcalculatieGelukt = $true`.
- Close the originating Forecast (`Close-AfasForecast`, `ViOp = "G"` = won) — still deliberately disabled in code pending a later step, so this line does not run yet.

### Stap 2d — close Lost forecasts

- For each Lost opportunity, parse the CmForecast key from its `externalIdentifier` via `ConvertFrom-ForecastExternalId` (same as 2c, no re-fetch) and close it in AFAS via `Close-AfasForecast` with `ViOp = "N"` (no `OrAF`, no articles/voorcalculatie). Errors clear the flag.

## State update (lines 673–692)

- A disabled flow (`$Flow1Enabled` / `$Flow2Enabled` = `$false`) leaves its watermark untouched and logs `"Flow N uitgeschakeld — state ongewijzigd"` — no warning, since nothing was attempted (:962-978).
- Otherwise, advance each watermark independently, but only if its flag is still true:
  - `$Flow1Complete` → write current date to `configs/LastForecastSyncDate.xml` (:680-685).
  - `$Flow2Complete` → write current date to `configs/LastSyncDate_Opportunities.xml` (:687-692).
- If a flag is false, the date is held so the next run retries the unprocessed records.

## Error handling (lines 694–696)

- Any unhandled exception bubbles to the outer `catch` and is logged as a fatal error — note this means a fatal crash mid-run leaves both watermarks untouched, so the next run re-processes the batch.

## Naming note

- The script was renamed on disk from `Sync-Afas2Salesbuildr-Forecasts.ps1` to `Sync-Forecasts.ps1`; the script header, CLAUDE.md and the API guides now all use the new name.
