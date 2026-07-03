# Sync-Afas2Salesbuildr-Forecasts — Execution Flow

## Setup & bootstrap (lines 412–458)

- Clear error state (`$Error.Clear()`) and enter the top-level `try`.
- Load config from `config.xml` into `$config` (:415).
- Ensure `work/` dir exists — creates it if missing (:417-419).
- Read the two watermark state files (:422-428):
  - `LastForecastSyncDate.xml` → `$LastForecastSync` (Flow 1)
  - `LastSyncDate_Opportunities.xml` → `$LastOpportunitySync` (Flow 2)
  - Both default to the Unix epoch (1970) on first run, so an initial run pulls everything.
- Decrypt credentials from the DPAPI-encrypted blobs in config (:434-447) — AFAS token and Salesbuildr API key. (Marked as temporary until `Configuration.psm1` is wired in.)
- Connect to both APIs (:449-450):
  - `Connect-Afas` sets global REST URL + `AfasToken` header (base64-encoding the token).
  - `Connect-Salesbuildr` sets the base URI + `api-key` header.
- Resolve connector names from config into `$ConnForecastGet`, `$ConnForecastUpdate`, etc. (:453-458).

## Flow 1 — AFAS Forecasts → Salesbuildr Opportunities (lines 461–528)

- Fetch changed forecasts: `Invoke-AfasGetConnectorFiltered` queries the `Salesbuildr_Forecasts` GetConnector server-side filtered on `gewijzigd > $LastForecastSync` (operator 5 = greater-than), paginating 100 at a time.
- Set `$Flow1Complete = $true` (:478) — the batch-watermark flag; any skip/error flips it to `$false`.
- Loop each forecast (:480):
  - Build `$ExternalId = "afas-Forecast-{SqNo}"` and `$CompanyExtId = "afas-Organisatie-{organisatie}"` (:486-491).
  - **Company existence check** (:496-501): if the Salesbuildr Company doesn't exist (org not yet synced), log WARNING, set `$Flow1Complete = $false`, and `continue` (skip).
  - **Already-closed check** (:504-508): if the Opportunity exists and is `statusId: "closed"`, skip it (this is a legitimate skip — does not clear the flag).
  - Build the payload (:510-519): `name`, `companyExtId`, `probability`, `onetimeRevenue`, and optionally `expectedCloseDate`.
  - Upsert via `PUT /public-api/opportunity/ext/{ExternalId}` (:522-527); on error, log ERROR and clear the flag.

## Flow 2 — Closed Opportunities → AFAS Voorcalculatieregels (lines 531–670)

- Fetch closed opportunities: `Get-SalesbuildrClosedOpportunities` pages through `statusId:closed` (size/from pagination), then client-side filters `updatedAt > $LastOpportunitySync`.
- Set `$Flow2Complete = $true` (:543).

### Stap 2a — collect quote lines & create missing articles (:545-604)

- For each closed opportunity, fetch its primary quote (`Get-SalesbuildrPrimaryQuote`) — queries `GET /public-api/quote?filters=opportunityId:{id}`, picks `primary: true`, or falls back to the most recent approved quote. On error/missing quote → log, clear flag, skip. Store each quote's items in `$AllQuotationLines` keyed by opportunity id.
- Collect unique item codes from `product.externalIdentifier` across all lines (:578-580).
- Fetch existing AFAS articles (`Salesbuildr_Artikelen`) and their itemCodes (:585-586).
- Create any missing articles in AFAS via `New-AfasArtikel` (`FbItemArticle`), using the quote item's name as description; on error, clear the flag.

### Stap 2b — create voorcalculaties per opportunity (:606-670)

- Derive `$ForecastSqNo` from the opportunity's `externalIdentifier` (`afas-Forecast-{SqNo}`) and build `$QuId = "SB-{SqNo}"` (:611-612).
- Re-fetch the AFAS Forecast by SqNo (`Get-AfasForecastBySqNo`) to get `verkooprelatie` → `$DbId`/`$PrId` (not present on the Opportunity). If not found → log ERROR, clear flag, skip.
- **Idempotency check** (:625-630): filter `Salesbuildr_Voorcalculatie` on `offerte = QuId`. If it already exists, just close the Forecast and continue.
- Build line items (:634-644) — `ItemCode`/`Omschrijving`/`Aantal`/`Prijs` from each quote item.
- Create the `KnQuotation` via `New-AfasVoorcalculatie`; on success set `$VoorcalculatieGelukt = $true`.
- Close the originating Forecast (`Close-AfasForecast`, `ViOp = "G"` = won) — only if the voorcalculatie was created successfully. Errors clear the flag.

## State update (lines 673–692)

- Advance each watermark independently, but only if its flag is still true:
  - `$Flow1Complete` → write current date to `LastForecastSyncDate.xml` (:680-685).
  - `$Flow2Complete` → write current date to `LastSyncDate_Opportunities.xml` (:687-692).
- If a flag is false, the date is held so the next run retries the unprocessed records.

## Error handling (lines 694–696)

- Any unhandled exception bubbles to the outer `catch` and is logged as a fatal error — note this means a fatal crash mid-run leaves both watermarks untouched, so the next run re-processes the batch.

## Naming note

- The file is `Sync-Forecasts.ps1` but its header and CLAUDE.md both call it `Sync-Afas2Salesbuildr-Forecasts.ps1` — same script, just renamed on disk.
