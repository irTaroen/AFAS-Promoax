# Promax — AFAS ↔ Salesbuildr Integration

PowerShell scripts that synchronise data between **AFAS Profit** (ERP) and **Salesbuildr** (CPQ/sales platform) for the customer Promax.

## Project layout

| Path | Purpose |
|---|---|
| `Sync-Afas2Salesbuildr.ps1` | Sync AFAS organisations & contacts → Salesbuildr (Companies, Contacts) |
| `Sync-Afas2Salesbuildr-Forecasts.ps1` | Bidirectional: AFAS Forecasts → Salesbuildr Opportunities; closed Opportunities → AFAS Voorcalculatie lines |
| `config.xml` | Runtime config: AFAS environment number, connector names, encrypted credentials, Salesbuildr base URL |
| `Modules/Configuration.psm1` | Config loading helper |
| `Modules/Logging.psm1` | Structured logging helper |
| `.env` | Local dev overrides — **never commit, never echo credentials** |

## Business flows

1. **Organisations & contacts** (`Sync-Afas2Salesbuildr.ps1`): delta sync from AFAS GetConnector `Salesbuildr_Forecasts` → upsert into Salesbuildr via `/ext/{externalIdentifier}`.
2. **Forecasts → Opportunities** (`Sync-Afas2Salesbuildr-Forecasts.ps1`, self-contained, no `Modules/` dependency yet):
   - **Flow 1 — AFAS Forecasts → Salesbuildr Opportunities**: delta sync via `work/LastForecastSyncDate.xml`; fetches changed forecasts (`gewijzigd` filter, operator 4 = greater than — note `5` is *less than*; the datetime value must be local time `yyyy-MM-ddTHH:mm:ss`, a trailing `Z` triggers a server error); links each Opportunity to its Company via `companyExtId = "afas-Organisatie-{organisatie}"` (the same key the org-sync writes — **not** `verkooprelatie`); if that Company does not exist in Salesbuildr the forecast is logged (WARNING) and skipped; upserts via `PUT /public-api/opportunity/ext/{externalIdentifier}`; skips if the Opportunity is already `statusId: "closed"` in Salesbuildr.
   - **Flow 2 — Closed Salesbuildr Opportunities → AFAS Voorcalculatieregels**: delta sync via `work/LastClosedOpportunitySyncDate.xml`; fetches closed Opportunities (`statusId: "closed"`, `size`/`from` pagination); gets the primary quote (`GET /public-api/quote?filters=opportunityId:{id}`, `primary: true`); re-fetches the AFAS Forecast by `SqNo` to obtain `verkooprelatie` (= `PrId`/`DbId`; not present on the Opportunity, whose `companyExtId` holds the organisatienummer); creates missing `Salesbuildr_Artikelen` in AFAS via `FbItemArticle`; creates `KnQuotation` with lines in AFAS; closes the originating AFAS Forecast (`PUT CmForecast`, `ViOp = "G"`). Idempotency via filtering `Salesbuildr_Voorcalculatie` on `offerte = "SB-{SqNo}"`.
   - **Watermark**: each flow advances its state file **only if every record in the batch was processed successfully** (`$Flow1Complete` / `$Flow2Complete`). Any skip (missing org, missing quote) or error holds the date so the next run retries those records; the two flows advance independently.
   - Field mappings and exact JSON payloads: see the "Promax Implementation Notes" sections in [AFAS_API_Guide.md](docs/api/AFAS_API_Guide.md) and [Salesbuildr_API_Guide.md](docs/api/Salesbuildr_API_Guide.md).
   - **Open TODO**: `ItCd` (AFAS item code) is currently taken directly from the Salesbuildr quote item's `product.externalIdentifier`. Real Promax item-code generation logic still needs to be implemented in `New-AfasArtikel` and the `$Regels` construction (Flow 2 step 2b, ~line 515).

## AFAS connector mapping (from config.xml)

| Purpose | GetConnector | UpdateConnector |
|---|---|---|
| Forecasts / Opportunities | `Salesbuildr_Forecasts` | `CmForecast` |
| Articles / Products | `Salesbuildr_Artikelen` | `FbItemArticle` |
| Voorcalculatie / Quotes | `Salesbuildr_Voorcalculatie` | `KnQuotation` |

AFAS environment number: **53307** (`https://53307.rest.afas.online/profitrestservices`).  
Salesbuildr base URL: **`https://verkoop.promax.nl/public-api`** (tenant `promax`).

## Credentials

Credentials are stored encrypted in `config.xml` and plaintext in `.env` (local dev only).  
**Never write actual tokens or keys into code, docs, or commit messages.** Use placeholders like `{afas_token}` / `{salesbuildr_api_key}` in examples.

- AFAS auth: `Authorization: AfasToken {base64(xml_token)}` — the full XML string is Base64-encoded at runtime.
- Salesbuildr auth: `api-key: {api_key}` request header.

## API reference docs

Consult these files only when the task involves the respective API:

- **[AFAS_API_Guide.md](docs/api/AFAS_API_Guide.md)** — UpdateConnector schemas, field tables, and HTTP examples for `CmForecast`, `FbItemArticle`, `KnQuotation`.
- **[Salesbuildr_API_Guide.md](docs/api/Salesbuildr_API_Guide.md)** — Endpoint reference, auth, pagination, rate limiting, webhooks, Quotes/Opportunities config.
- **[openapi.json](docs/api/openapi.json)** — Full Salesbuildr OpenAPI spec. Schema components are at `#/components/schemas/{Name}`.

## PowerShell conventions

- `$ErrorActionPreference = 'Stop'` everywhere — let exceptions bubble.
- AFAS token encoding: `[System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($token))`.
- Config is read from `config.xml` via `Read-XMLConfig`; credentials may be DPAPI-encrypted blobs — decrypt via the `Configuration` module, never handle raw encrypted strings manually.
- Log via `Write-Log -Level INFO|WARNING|ERROR -Message '...'`.
