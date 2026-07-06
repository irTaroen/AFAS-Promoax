# Promax — AFAS ↔ Salesbuildr Integration

PowerShell scripts that synchronise data between **AFAS Profit** (ERP) and **Salesbuildr** (CPQ/sales platform) for the customer Promax.

## Project layout

| Path | Purpose |
|---|---|
| `Sync-Forecasts.ps1` | Bidirectional: AFAS Forecasts → Salesbuildr Opportunities; closed Opportunities → AFAS Voorcalculatie lines |
| `configs/mapping-artikelgroepen.xml` | Maps Salesbuildr `category.id` directly to the AFAS artikelgroep (`Grp`) used when creating articles |
| `configs/config.xml` | Runtime config, **plaintext, gitignored**: mode (TEST/PROD), `<flows><flow1>/<flow2>>` on/off toggles, AFAS environment number + token, connector names, Salesbuildr URL/API key, country mapping |
| `configs/config.example.xml` | Committable config template with `{afas_token_data}` / `{salesbuildr_api_key}` placeholders |
| `configs/LastForecastSyncDate.xml`, `configs/LastSyncDate_Opportunities.xml` | Sync watermark state files, gitignored via `configs/Last*.xml` |
| `Modules/Logging.psm1` | Structured logging helper |

`configs/` is created automatically by the script if missing.

## Business flows

Organisations & contacts have no dedicated sync script at the moment.

1. **Forecasts → Opportunities** (`Sync-Forecasts.ps1`, self-contained, no `Modules/` dependency yet):
   - **Flow 1 — AFAS Forecasts → Salesbuildr Opportunities**: delta sync via `configs/LastForecastSyncDate.xml`; fetches changed forecasts (`gewijzigd` filter, operator 4 = greater than — note `5` is *less than*; the datetime value must be local time `yyyy-MM-ddTHH:mm:ss`, a trailing `Z` triggers a server error); links each Opportunity to its Company via `companyExtId = "afas-Organisatie-{organisatie}"` (the same key the org-sync writes — **not** `verkooprelatie`); if that Company does not exist in Salesbuildr the forecast is logged (WARNING) and skipped; sets the **owner** (required by the API) via `ownerId = verantwoordelijkeOwnerID` (the GetConnector resolves the responsible AFAS employee to their SB user id — the owner is a SB *user*, not a Contact, so it cannot be looked up by e-mail); resolves the **client contact** from `contactpersoonMail` via `Get-SalesbuildrContactByEmail` (`GET /public-api/contact?query={email}`, exact `email` match) and sets `contactId` if found (optional — a miss logs a WARNING and upserts without a contact); sets `externalIdentifier = "afas-Forecast-{forecast}-{volgnummer}-{verkooprelatie}"` (e.g. `afas-Forecast-11310-42-10654`) — encodes three distinct `Salesbuildr_Forecasts` fields (`forecast` = globally-unique AFAS forecast id, used as the voorcalculatie `QuId`; `volgnummer` = CmForecast `SqNo`; `verkooprelatie` = CmForecast `PrId`, the debtor code) so Flow 2 can parse the CmForecast key straight from the identifier with **no re-fetch**; upserts via `PUT /public-api/opportunity/ext/{externalIdentifier}`; skips if the Opportunity is already `statusId: "closed"` in Salesbuildr.
   - **Flow 2 — Closed Salesbuildr Opportunities → AFAS Voorcalculatieregels**: delta sync via `configs/LastSyncDate_Opportunities.xml`; fetches closed Opportunities (`statusId: "closed"`, `size`/`from` pagination); gets the primary quote via `GET /public-api/quote?filters=opportunity.id:{id}` (filter key is **`opportunity.id`**, not `opportunityId` — that returns 0), then `primary: true` (**no fallback** to any other approved quote); parses `PrId`/`SqNo`/`QuId` directly from the Opportunity's `externalIdentifier` via regex `^afas-Forecast-(?<fc>\d+)-(?<sqno>\d+)-(?<pr>.+)$` — the AFAS Forecast is **no longer re-fetched**. Categorizes strictly on the primary quote: **Won** (primary quote exists and `status == "approved"`) creates missing `Salesbuildr_Artikelen` in AFAS via `FbItemArticle`, creates `KnQuotation` with lines, then closes the originating AFAS Forecast (`PUT CmForecast`, `ViOp = "G"`, `OrAF` = total quote amount = Σ `price × quantity × (1 - discount)` over quote items); **Lost** (no primary quote, or primary quote `status != "approved"`) only closes the Forecast (`ViOp = "N"`, no `OrAF`, no articles/voorcalculatie). A missing/unapproved primary quote is **not** an error — it's a legitimate Lost outcome. Idempotency via filtering `Salesbuildr_Voorcalculatie` on `offerte = "{forecast-id}"` (e.g. `offerte = "11310"`, the AFAS `forecast` id — no `SB-` prefix).
   - **Flow toggles**: each flow can be switched on/off independently via `configs/config.xml`'s `<flows><flow1>/<flow2>>` (`ConvertTo-ConfigBool`: accepts `true/1/yes/ja/on` and `false/0/no/nee/off`, case-insensitive; empty/missing/unrecognized → default **true**, so a config without `<flows>` still runs both flows). A disabled flow is skipped entirely (logs `"=== Flow N is uitgeschakeld in config.xml ... ==="`) and its state file is left untouched (logs `"Flow N uitgeschakeld — state ongewijzigd"`) — no warning, since nothing was attempted.
   - **Watermark**: each flow advances its state file **only if every record in the batch was processed successfully** (`$Flow1Complete` / `$Flow2Complete`). Any skip (missing org, unmapped category) or error holds the date so the next run retries those records; a Lost categorization is **not** a skip and still advances the watermark once its Forecast is closed successfully; the two flows advance independently.
   - Field mappings and exact JSON payloads: see the "Promax Implementation Notes" sections in [AFAS_API_Guide.md](docs/api/AFAS_API_Guide.md) and [Salesbuildr_API_Guide.md](docs/api/Salesbuildr_API_Guide.md).
   - **Item code (`ItCd`)**: the AFAS item code is **always** the quote line's `mpn` — used for both the "does the article exist?" lookup (`Salesbuildr_Artikelen.itemCode`, a targeted per-`mpn` filtered GetConnector call, not a bulk catalog fetch — AFAS holds 30,000+ articles) and creation (`FbItemArticle.ItCd`). The quote item's `product` field is **nullable** (free-form lines have no linked catalog product), so it must **not** be relied on. Quote lines without an `mpn` are logged (WARNING) and skipped (no article code).
   - **Article group (`Grp`)**: a new AFAS article's artikelgroep (required) is now resolved in a **direct one hop**: quote line `category.id` → `configs/mapping-artikelgroepen.xml` (`<categorie SB-id="..." AFAS-id="..." AFAS-naam="..."/>`) → `Grp`. The quote line already carries `category.id`, so the old `/public-api/category` fetch and `costCenterId` indirection are gone. Only categories with a non-empty `AFAS-id` are loaded; a category missing from the file (or with an empty `AFAS-id`) is "not mapped" and skips the article **and its whole opportunity** (WARNING, watermark held for retry — a partial voorcalculatie would reference a non-existent article); `AFAS-naam` is logging-only. `configs/config.xml`'s old `<afas><artikelgroepmapping><costcenter>` block has been removed entirely (superseded by `configs/mapping-artikelgroepen.xml`). See `Get-AfasArtikelgroep`, `New-AfasArtikel`.

## AFAS connector mapping (from configs/config.xml)

| Purpose | GetConnector | UpdateConnector |
|---|---|---|
| Forecasts / Opportunities | `Salesbuildr_Forecasts` | `CmForecast` |
| Articles / Products | `Salesbuildr_Artikelen` | `FbItemArticle` |
| Voorcalculatie / Quotes | `Salesbuildr_Voorcalculatie` | `KnQuotation` |

AFAS environment number: **53307** (`https://53307.rest.afas.online/profitrestservices`).  
Salesbuildr base URL: **`https://verkoop.promax.nl/public-api`** (tenant `promax`).

## Credentials

Credentials are stored **plaintext** in `configs/config.xml` (no DPAPI, no encryption) — the file is gitignored; `configs/config.example.xml` is the committable template with `{afas_token_data}` / `{salesbuildr_api_key}` placeholders.  
**Never write actual tokens or keys into code, docs, or commit messages.** Use placeholders like `{afas_token_data}` / `{salesbuildr_api_key}` in examples.

- AFAS auth: `Authorization: AfasToken {base64(xml_token)}` — the full `<token>…</token>` XML (stored in a CDATA block, read via `$config.SelectSingleNode('afas/token').InnerText`) is Base64-encoded at runtime.
- Salesbuildr auth: `api-key: {api_key}` request header.

## API reference docs

Consult these files only when the task involves the respective API:

- **[AFAS_API_Guide.md](docs/api/AFAS_API_Guide.md)** — UpdateConnector schemas, field tables, and HTTP examples for `CmForecast`, `FbItemArticle`, `KnQuotation`.
- **[Salesbuildr_API_Guide.md](docs/api/Salesbuildr_API_Guide.md)** — Endpoint reference, auth, pagination, rate limiting, webhooks, Quotes/Opportunities config.
- **[openapi.json](docs/api/openapi.json)** — Full Salesbuildr OpenAPI spec. Schema components are at `#/components/schemas/{Name}`.

## PowerShell conventions

- `$ErrorActionPreference = 'Stop'` everywhere — let exceptions bubble.
- AFAS token encoding: `[System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($token))`.
- Config is read from `configs/config.xml` (plaintext, gitignored) via each script's local `Read-XMLConfig` helper — no encryption, no `Configuration` module; the AFAS token is read via `$config.SelectSingleNode('afas/token').InnerText` (works with the CDATA block).
- Log via `Write-Log -Level INFO|WARNING|ERROR -Message '...'`.

## Workflow

- After every big code change, update the docs — but delegate the doc update to the **sonnet** model (e.g. spawn a Sonnet subagent to do it).
