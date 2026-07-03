# AFAS Profit REST API — Usage Guide

---

## Overview

AFAS Profit exposes its data through a REST API called the **App Connector**. It uses two connector types:

| Type | Purpose | HTTP Methods |
|---|---|---|
| **GetConnector** | Read data | `GET` |
| **UpdateConnector** | Write data (insert, update, delete) | `POST`, `PUT`, `DELETE` |

---

## Base URL

```
https://{environment_number}.rest.afas.online/profitrestservices/
```

Replace `{environment_number}` with your AFAS environment number (5-digit number provided by AFAS).

---

## Authentication

Every request requires an `Authorization` header with your AFAS token.

### Token Format

The raw token is an XML string:

```xml
<token><version>1</version><data>{TOKEN_DATA}</data></token>
```

This XML string must be **Base64-encoded** before use. Store the raw token in a secure location (e.g. `.env`) and encode it at runtime.

### Request Header

```http
Authorization: AfasToken {base64_encoded_token}
```

**Example (Node.js):**

```javascript
const rawToken = process.env.AFAS_TOKEN;
const encoded = Buffer.from(rawToken).toString('base64');

fetch(url, {
  headers: {
    'Authorization': `AfasToken ${encoded}`,
    'Content-Type': 'application/json'
  }
});
```

---

## GetConnector — Reading Data

```
GET /connectors/{connectorName}
```

### Query Parameters

| Parameter | Description | Example |
|---|---|---|
| `skip` | Pagination offset | `0` |
| `take` | Number of records to return | `100` |
| `filterfieldids` | Field(s) to filter on | `PrId` |
| `filtervalues` | Value(s) to filter on | `ACME001` |
| `operatortypes` | Filter operator (see table below) | `1` |
| `orderbyfieldids` | Field(s) to sort by | `DaSt` |

**Operator types** (verified against environment 53307):

| Value | Meaning |
|---|---|
| `1` | equal (`=`) |
| `2` | greater than or equal (`>=`) |
| `3` | less than or equal (`<=`) |
| `4` | **greater than (`>`)** — use this for delta sync |
| `5` | less than (`<`) |
| `6` | contains |
| `7` | not equal (`!=`) |

> ⚠️ **Operator 4, not 5, is "greater than".** Operator `5` is *less than*. An earlier version of the sync used `5` for delta and silently returned 0 rows.

> ⚠️ **Datetime filter format:** use `yyyy-MM-ddTHH:mm:ss` in **local** time — e.g. `2026-06-29T00:00:00`. A trailing `Z` (UTC designator) causes a server error (`Conversion from string "0Z" to type 'Integer' is not valid`), and a bare date with no time component also fails.

**Example:**

```http
GET /connectors/CmForecast?skip=0&take=50&filterfieldids=PrId&filtervalues=ACME001&operatortypes=1
Authorization: AfasToken {base64_encoded_token}
```

### Response

```json
{
  "skip": 0,
  "take": 50,
  "rows": [
    { "PrId": "ACME001", "SqNo": 1, "Ds": "Q3 Renewal", ... }
  ]
}
```

---

## UpdateConnector — Writing Data

All write operations use the same endpoint and body structure:

```
POST   /connectors/{connectorName}     ← Insert
PUT    /connectors/{connectorName}     ← Update
DELETE /connectors/{connectorName}     ← Delete
```

### Request Body Structure

```json
{
  "{ConnectorName}": {
    "Element": {
      "Fields": {
        "FieldCode": "value"
      }
    }
  }
}
```

For updates and deletes, include only the key fields and the fields you want to change.

---

## Salesbuildr_Organisaties — GetConnector (Read Organisations)

**Connector name:** `Salesbuildr_Organisaties`  
Read-only connector returning organisation/company records from AFAS. Used by `Sync-Afas2Salesbuildr.ps1` to upsert companies into Salesbuildr. No corresponding UpdateConnector — organisations are written to Salesbuildr, not back to AFAS.

```http
GET /connectors/Salesbuildr_Organisaties?skip=0&take=100
Authorization: AfasToken {base64_encoded_token}
```

### Response Schema

```json
{
  "skip": 0,
  "take": 20,
  "rows": [
    {
      "Nummer": "1000235",
      "Omschrijving": "Organisatie",
      "Naam": "Anthura BV",
      "Geblokkeerd": false,
      "Type_verkooprelatie": "Actief Promax",
      "Telnr_werk": "010-5291919",
      "E-mail_werk": null,
      "Straat": "Anthuriumweg",
      "Huisnummer": 14,
      "Toevoeging": null,
      "Postcode": "2665 KV",
      "Woonplaats": "Bleiswijk",
      "Land": "NL",
      "Accountmanager": "Robert van Dijk",
      "Gewijzigd_op": "2026-02-13T14:56:29Z",
      "Aangemaakt_op": "2013-10-16T18:25:36Z"
    }
  ]
}
```

### Field Reference

| Field | Type | Description | Salesbuildr mapping |
|---|---|---|---|
| `Nummer` | string | Account number (primary key / external identifier) | `number` / `externalIdentifier` |
| `Omschrijving` | string | Record type label (always `"Organisatie"`) | — |
| `Naam` | string | Company name | `name` |
| `Geblokkeerd` | boolean | Blocked / inactive flag | `isActive` (inverted) |
| `Type_verkooprelatie` | string | Customer type/segment label | — |
| `Telnr_werk` | string\|null | Work phone number | `phone` |
| `E-mail_werk` | string\|null | Work e-mail address | `email` |
| `Straat` | string\|null | Street name | address |
| `Huisnummer` | integer\|null | House number | address |
| `Toevoeging` | string\|null | House number suffix | address |
| `Postcode` | string\|null | Postal code | address |
| `Woonplaats` | string\|null | City | address |
| `Land` | string\|null | Country code (ISO 3166-1 alpha-2, e.g. `NL`) | `country` |
| `Accountmanager` | string\|null | Account manager full name | — |
| `Gewijzigd_op` | datetime | Last modified timestamp | — |
| `Aangemaakt_op` | datetime | Created timestamp | — |

> **Note:** Promax uses `NL` → `NL` country mapping directly. Exceptions (e.g. `B` → `BE`) are configured in `config.xml` under `<countrymapping>`.

### Filtering

```http
# Delta sync — organisations modified after a given date (operator 4 = greater than; local time, no trailing Z)
GET /connectors/Salesbuildr_Organisaties?filterfieldids=Gewijzigd_op&filtervalues=2026-01-01T00:00:00&operatortypes=4

# Only active (non-blocked) organisations
GET /connectors/Salesbuildr_Organisaties?filterfieldids=Geblokkeerd&filtervalues=false&operatortypes=1

# Look up a specific organisation by number
GET /connectors/Salesbuildr_Organisaties?filterfieldids=Nummer&filtervalues=1000235&operatortypes=1
```

---

## Salesbuildr_Forecasts — GetConnector (Read Forecasts)

**Connector name:** `Salesbuildr_Forecasts`  
Use this read-only GetConnector to retrieve forecasts from AFAS. It returns a flattened, Dutch-language view of `CmForecast` data — more readable than raw UpdateConnector fields.

```http
GET /connectors/Salesbuildr_Forecasts?skip=0&take=100
Authorization: AfasToken {base64_encoded_token}
```

### Response Schema

```json
{
  "skip": 0,
  "take": 20,
  "rows": [
    {
      "forecast": 13,
      "forecastOmschrijving": "Nieuwe ESX + SAN",
      "status": "Gesloten en gescoord",
      "gemaakt": "2013-12-19T14:58:13Z",
      "gewijzigd": "2016-08-08T11:39:16Z",
      "organisatie": "1000350",
      "verkooprelatie": "10127",
      "verkooprelatieNaam": "Roveg Fruit B.V.",
      "scoringkans": 100,
      "bedrag": 0,
      "bedragVerwacht": 0,
      "verantwoordelijke": "10011",
      "verantwoordelijkeOwnerID": "sZ404hyXGcN1TyVmbBN5",
      "verantwoordelijkeNaam": "Wim de Heer",
      "verantwoordelijkeMail": "wim@example.nl",
      "begindatum": "2013-12-19T00:00:00Z",
      "einddatumVerwacht": null,
      "contactpersoon": 8324,
      "contactpersoonNaam": "Roveg Fruit - ICT - Jan Jansen",
      "contactpersoonMail": "jan.jansen@example.nl"
    }
  ]
}
```

### Field Reference

| Field | Type | Description | Maps to `CmForecast` |
|---|---|---|---|
| `forecast` | integer | Sequence number (primary key) | `SqNo` |
| `forecastOmschrijving` | string | Description | `Ds` |
| `status` | string | Human-readable status label | `ViSt` / `ViOp` |
| `gemaakt` | datetime | Created timestamp | — |
| `gewijzigd` | datetime | Last modified timestamp | — |
| `organisatie` | string | AFAS organisation number | — (→ Salesbuildr `companyExtId` as `afas-Organisatie-{organisatie}`) |
| `verkooprelatie` | string | Customer account code (debtor) | `PrId` |
| `verkooprelatieNaam` | string | Customer account name | — (joined) |
| `scoringkans` | integer | Win probability (0–100) | `Pc` × 100 |
| `bedrag` | decimal | Actual amount | `Am` |
| `bedragVerwacht` | decimal | Expected/weighted amount | `AmF` |
| `verantwoordelijke` | string | Responsible employee code | `EmId` |
| `verantwoordelijkeOwnerID` | string | Salesbuildr **user id** of the responsible employee (resolved in the GetConnector) | — (→ Salesbuildr `ownerId`) |
| `verantwoordelijkeNaam` | string | Responsible employee name | — (joined) |
| `verantwoordelijkeMail` | string | Responsible employee work e-mail | — (informational; not sent to Salesbuildr) |
| `begindatum` | datetime | Start date | `DaSt` |
| `einddatumVerwacht` | datetime\|null | Expected close date | `DaEn` |
| `contactpersoon` | integer | Client contact person number | `CtPe` |
| `contactpersoonNaam` | string | Client contact person name | — (joined) |
| `contactpersoonMail` | string | Client contact work e-mail | — (→ Salesbuildr `contactId`, resolved via `/public-api/contact` e-mail lookup) |

### Filtering

```http
# Forecasts modified after a specific date (operator 4 = greater than; local time, no trailing Z)
GET /connectors/Salesbuildr_Forecasts?filterfieldids=gewijzigd&filtervalues=2024-01-01T00:00:00&operatortypes=4

# Forecasts for a specific customer
GET /connectors/Salesbuildr_Forecasts?filterfieldids=verkooprelatie&filtervalues=10127&operatortypes=1
```

---

## CmForecast — Forecast (Verkoopkansen)

**Connector name:** `CmForecast`

This connector manages sales forecasts / opportunities in AFAS Profit CRM.

**Primary key:** `PrId` + `SqNo` (composite)

---

### Field Reference

Fields marked `*` are **required** for insert operations.

#### Identity

| Field | Dutch Label | Type | Constraints | Description |
|---|---|---|---|---|
| `PrId` * | Verkooprelatie | string | Max 16 chars | Sales relation (debtor/relation code) |
| `SqNo` * | Volgnummer | integer | — | Sequence number (auto-assigned if omitted on insert) |

#### General

| Field | Dutch Label | Type | Constraints | Description |
|---|---|---|---|---|
| `Ds` | Omschrijving | string | Max 100 chars | Description / title of the forecast |
| `CtPe` | Contactpersoon | integer | — | Contact person ID |
| `EmId` | Verantwoordelijke | string | Max 15 chars | Responsible employee ID |
| `Re` | Opmerking | byte | — | Internal note / remark |

#### Dates

| Field | Dutch Label | Type | Description |
|---|---|---|---|
| `DaSt` | Begindatum | date | Start date |
| `DaEn` | Verwachte einddatum | date | Expected end date |
| `DaSc` | Einddatum | date | Actual close date |

#### Classification

| Field | Dutch Label | Type | Constraints | Description |
|---|---|---|---|---|
| `ViGr` | Forecastgroep | string | Max 20 chars | Forecast group |
| `SbHi` | Aanleiding | integer | — | Occasion / trigger code |
| `ScId` | Bron | string | Max 5 chars | Lead source code |
| `CaId` | Campagne | integer | — | Campaign ID |
| `PjId` | Project | string | Max 15 chars | Project code |
| `ViSt` | Voortgang | string | Max 10 chars | Progress / stage |

#### Financials

| Field | Dutch Label | Type | Constraints | Description |
|---|---|---|---|---|
| `Pc` | Scoringskans | number | Multiple of `0.01` | Win probability (0–100, e.g. `75.00`) |
| `Am` | Verwacht bedrag basisvaluta | number | Multiple of `1e-10` | Expected amount in base currency |
| `AmF` | Verwacht bedrag | number | Multiple of `1e-10` | Expected amount in transaction currency |
| `CaQB` | Verwacht bedrag berekenen obv offertes | boolean | — | Auto-calculate expected amount from quotes/pre-calc |
| `OrAm` | Orderbedrag basisvaluta | number | Multiple of `1e-10` | Order amount in base currency |
| `OrAF` | Orderbedrag | number | Multiple of `1e-10` | Order amount in transaction currency |
| `CuId` | Valuta | string | Max 3 chars | Currency code (e.g. `EUR`, `USD`) |
| `Rate` | Valutakoers | number | Multiple of `1e-10` | Exchange rate |

#### Result

| Field | Dutch Label | Type | Allowed Values | Description |
|---|---|---|---|---|
| `ViOp` | Resultaat | enum | `G` \| `N` \| `O` | Outcome: `G` = Closed won · `N` = Closed lost · `O` = Open |
| `ViRe` | Reden | enum | `PR` \| `FU` \| `SE` \| `PKW` \| `ORG` \| `VI` \| `ERV` \| `REF` | Loss reason (see table below) |
| `ViFo` | Verloren aan | string | Max 20 chars | Lost to (competitor name) |

#### Loss Reason Codes (`ViRe`)

| Code | Dutch | English |
|---|---|---|
| `PR` | Prijs | Price |
| `FU` | Functionaliteit | Functionality |
| `SE` | Serviceverlening | Service |
| `PKW` | Productkwaliteit | Product quality |
| `ORG` | Organisatie | Organisation |
| `VI` | Visie | Vision |
| `ERV` | Ervaring | Experience |
| `REF` | Referentie | References |

---

### Insert a Forecast

```http
POST /connectors/CmForecast
Authorization: AfasToken {base64_encoded_token}
Content-Type: application/json

{
  "CmForecast": {
    "Element": {
      "Fields": {
        "PrId": "ACME001",
        "SqNo": 1,
        "Ds": "Microsoft 365 Migration",
        "EmId": "JDOE",
        "DaSt": "2026-07-01",
        "DaEn": "2026-09-30",
        "ViGr": "Software",
        "ViSt": "Proposal",
        "Pc": 75.00,
        "AmF": 25000.00,
        "CuId": "EUR",
        "ViOp": "O"
      }
    }
  }
}
```

---

### Update a Forecast

```http
PUT /connectors/CmForecast
Authorization: AfasToken {base64_encoded_token}
Content-Type: application/json

{
  "CmForecast": {
    "Element": {
      "Fields": {
        "PrId": "ACME001",
        "SqNo": 1,
        "ViOp": "G",
        "DaSc": "2026-08-15",
        "OrAF": 23500.00
      }
    }
  }
}
```

Only include the key fields (`PrId`, `SqNo`) and the fields you want to change.

---

### Delete a Forecast

```http
DELETE /connectors/CmForecast
Authorization: AfasToken {base64_encoded_token}
Content-Type: application/json

{
  "CmForecast": {
    "Element": {
      "Fields": {
        "PrId": "ACME001",
        "SqNo": 1
      }
    }
  }
}
```

---

### Close a Forecast as Won

```http
PUT /connectors/CmForecast
Authorization: AfasToken {base64_encoded_token}
Content-Type: application/json

{
  "CmForecast": {
    "Element": {
      "Fields": {
        "PrId": "ACME001",
        "SqNo": 1,
        "ViOp": "G",
        "DaSc": "2026-08-15",
        "OrAF": 23500.00,
        "OrAm": 23500.00
      }
    }
  }
}
```

---

### Close a Forecast as Lost

```http
PUT /connectors/CmForecast
Authorization: AfasToken {base64_encoded_token}
Content-Type: application/json

{
  "CmForecast": {
    "Element": {
      "Fields": {
        "PrId": "ACME001",
        "SqNo": 1,
        "ViOp": "N",
        "ViRe": "PR",
        "ViFo": "Competitor BV",
        "DaSc": "2026-08-15"
      }
    }
  }
}
```

---

## Error Handling

AFAS returns standard HTTP status codes:

| Status | Meaning |
|---|---|
| `200` / `201` | Success |
| `400` | Bad request — invalid field value or missing required field |
| `401` | Unauthorized — token missing or invalid |
| `404` | Record or connector not found |
| `500` | Server error — check AFAS error message in response body |

Error responses include a JSON body with details:

```json
{
  "exceptionMessage": "Waarde veld 'PrId' is niet gevuld",
  "message": "An error has occurred."
}
```

---

## Salesbuildr_Artikelen — GetConnector (Read Articles)

**Connector name:** `Salesbuildr_Artikelen`  
Read-only connector returning both services (werksoorten, `type=1`) and physical articles (`type=2`). Use this to check which items already exist in AFAS before upserting via `FbItemArticle`.

```http
GET /connectors/Salesbuildr_Artikelen?skip=0&take=100
Authorization: AfasToken {base64_encoded_token}
```

### Response Schema

```json
{
  "skip": 0,
  "take": 20,
  "rows": [
    {
      "type": "1",
      "typeOmschrijving": "Werksoort",
      "itemCode": "101",
      "itemOmschrijving": "Reistijd",
      "artikelgroep": null
    },
    {
      "type": "2",
      "typeOmschrijving": "Artikel",
      "itemCode": "HAR-BE-U1216",
      "itemOmschrijving": "KingSener 10.95v 5.2Ah Laptop batterij",
      "artikelgroep": "70"
    }
  ]
}
```

### Field Reference

| Field | Type | Description | Maps to `FbItemArticle` |
|---|---|---|---|
| `type` | string | Article type code | `VaTp` |
| `typeOmschrijving` | string | Type label | — (derived) |
| `itemCode` | string | Article/item code (primary key) | `ItCd` |
| `itemOmschrijving` | string | Description | `Ds_1043` (Dutch) |
| `artikelgroep` | string\|null | Article group code | `ItGr` |

### Type Values

| `type` | `typeOmschrijving` | Description |
|---|---|---|
| `1` | Werksoort | Service / labour type — no physical stock |
| `2` | Artikel | Physical article / product |

### Filtering

```http
# Only physical articles
GET /connectors/Salesbuildr_Artikelen?filterfieldids=type&filtervalues=2&operatortypes=1

# Look up a specific item by code
GET /connectors/Salesbuildr_Artikelen?filterfieldids=itemCode&filtervalues=HAR-BE-U1216&operatortypes=1
```

---

## FbItemArticle — Article (Artikel)

**Connector name:** `FbItemArticle`

Manages product/article master data in AFAS Profit.

**Primary key:** `ItCd` (item code). Set `AuId: true` to let AFAS auto-assign the item code.

**Sub-objects:** `FbArticleCustom` (custom fields) — nested under `Objects`.

---

### Field Reference

#### Identity & Numbering

| Field | Dutch Label | Type | Constraints | Description |
|---|---|---|---|---|
| `ItCd` | Itemcode | string | Max 40 chars | Item code (primary key) |
| `AuId` | Autonummering | boolean | — | Auto-assign item code on insert |

#### Descriptions

| Field | Dutch Label | Type | Constraints | Description |
|---|---|---|---|---|
| `Ds` | Omschrijving | string | Max 100 chars | Description (default language) |
| `Ds_1031` | Omschrijving (Duits) | string | Max 100 chars | German description |
| `Ds_1036` | Omschrijving (Frans) | string | Max 100 chars | French description |
| `Ds_1043` | Omschrijving (Nederlands) | string | Max 100 chars | Dutch description |
| `Ds_2057` | Omschrijving (Engels) | string | Max 100 chars | English description |
| `Ds_2067` | Omschrijving (Vlaams) | string | Max 100 chars | Flemish description |
| `DsEx` | Extra omschrijving | string | Max 100 chars | Extra description |
| `DsEx_1031` | Extra omschrijving (Duits) | string | Max 100 chars | Extra description (German) |
| `DsEx_1036` | Extra omschrijving (Frans) | string | Max 100 chars | Extra description (French) |
| `DsEx_1043` | Extra omschrijving (Nederlands) | string | Max 100 chars | Extra description (Dutch) |
| `DsEx_2057` | Extra omschrijving (Engels) | string | Max 100 chars | Extra description (English) |
| `DsEx_2067` | Extra omschrijving (Vlaams) | string | Max 100 chars | Extra description (Flemish) |
| `ChDs` | Omschrijving te wijzigen | boolean | — | Allow description override on order line |

#### Classification

| Field | Dutch Label | Type | Constraints | Description |
|---|---|---|---|---|
| `Grp` | Artikelgroep | string | Max 15 chars | Article group |
| `Loc` | Locatie | string | Max 15 chars | Default warehouse location |
| `PgId` | Presentatiegroep | string | Max 8 chars | Presentation group |
| `BiSaItCd` | Itemcode verkoop | string | Max 40 chars | Sales item code (alias) |
| `Bl` | Geblokkeerd | boolean | — | Block article from use |

#### Article Type

| Field | Dutch Label | Type | Allowed | Description |
|---|---|---|---|---|
| `VaTp` | Artikeltype | enum | `0`–`5` | Article type (see table below) |
| `ArSu` | Type subartikel | enum | `0`\|`1`\|`2`\|`3`\|`5`\|`6`\|`7` | Sub-article type (see table below) |

**`VaTp` — Article type values:**

| Value | Description |
|---|---|
| `0` | Standard article |
| `1` | Serial number article |
| `2` | Batch article |
| `3` | 1 article dimension |
| `4` | 2 article dimensions |
| `5` | Order line specification |

**`ArSu` — Sub-article type values:**

| Value | Description |
|---|---|
| `0` | Normal article |
| `1` | Raw material |
| `2` | Semi-finished product |
| `3` | Label |
| `5` | Packaging |
| `6` | Subscription article (without purchase) |
| `7` | Subscription article (with purchase) |

#### Stock & Inventory

| Field | Dutch Label | Type | Constraints | Description |
|---|---|---|---|---|
| `BiSt` | Voorraad bijhouden | boolean | — | Track stock |
| `BiDc` | Aantal decimalen | integer | — | Stock decimal places |
| `BiUn` | Basiseenheid | string | Max 15 chars | Base unit of measure |
| `UnPR` | Voorkeur aanvraageenheid | string | Max 15 chars | Preferred purchase request unit |
| `PrFc` | Prijsfactor | integer | — | Price factor |
| `WaSe` | Magazijntoewijzing | boolean | — | Warehouse assignment |
| `StAd` | Voorraadaanvulling | boolean | — | Auto stock replenishment |
| `StMi` | Minimum voorraad | number | Multiple of `0.00001` | Minimum stock level |
| `StMa` | Aanvullen tot | number | Multiple of `0.00001` | Replenish-to level |

| Field | Dutch Label | Type | Allowed | Description |
|---|---|---|---|---|
| `StCh` | Voorraadcontrole | enum | `0`\|`1`\|`2`\|`3` | Stock control method |
| `VaDo` | Uitlevervolgorde | enum | `0`\|`1`\|`2`\|`3` | Delivery sequence |
| `VaCr` | Bestelvoorstel bij verkoop | enum | `N`\|`V`\|`S`\|`A`\|`R` | Purchase proposal on sales |

**`StCh` — Stock control:**

| Value | Description |
|---|---|
| `0` | Check free stock (sales order + packing slip) |
| `1` | Check economic stock (sales order) |
| `2` | Check free stock (packing slip only) |
| `3` | No stock control |

**`VaDo` — Delivery sequence:**

| Value | Description |
|---|---|
| `0` | No sequence |
| `1` | FIFO — First In First Out |
| `2` | LIFO — Last In First Out |
| `3` | FEFO — First Expired First Out |

**`VaCr` — Purchase proposal on sales:**

| Value | Description |
|---|---|
| `N` | Never |
| `V` | Ask when stock shortage |
| `S` | Always ask (regardless of stock) |
| `A` | Always (entire order line via purchase order) |
| `R` | Remainder (shortage part only) |

#### Pricing

| Field | Dutch Label | Type | Constraints | Description |
|---|---|---|---|---|
| `StPrice` | Verrekenprijs | number | Multiple of `1e-10` | Transfer/settlement price |
| `CoPrice` | Kostprijs | number | Multiple of `1e-10` | Cost price |
| `SaPrice` | Verkoopprijs | number | Multiple of `1e-10` | Sales price |
| `PuPrice` | Inkoopprijs | number | Multiple of `1e-10` | Purchase price |
| `CsPrice` | Consumentenprijs | number | Multiple of `1e-10` | Consumer/RRP price |
| `DatPri` | Ingangsdatum prijzen | date | — | Price effective date |
| `PrGr` | Prijsgroep | string | Max 10 chars | Price group |
| `PrFr` | Prijs van | string | Max 40 chars | Price source item code |
| `TrCo` | Transportkosten | number | Multiple of `1e-10` | Transport costs |
| `PcLo` | Verlies (%) | number | Multiple of `0.01` | Loss percentage |

#### VAT & Tax

| Field | Dutch Label | Type | Constraints | Description |
|---|---|---|---|---|
| `CoLa` | Land wetgeving | string | Max 3 chars | Country of legislation (e.g. `NL`) |
| `VaRc` | Tariefgroep | string | Max 4 chars | VAT rate group |
| `VaAr` | Tariefgroep bij afwijking | string | Max 4 chars | VAT rate group (override) |
| `EUSe` | Dienstenberekening | boolean | — | EU services calculation |
| `TaCd` | TARIC-code | string | Max 2 chars | TARIC code |

#### Purchase

| Field | Dutch Label | Type | Constraints | Description |
|---|---|---|---|---|
| `CrId` | Inkooprelatie | string | Max 16 chars | Default supplier (creditor) |
| `ItSp` | Itemcode inkooprelatie | string | Max 30 chars | Supplier's item code |
| `ChPu` | Controle handmatige inkoop | boolean | — | Validate manual purchase price |

#### Sales & Commerce

| Field | Dutch Label | Type | Description |
|---|---|---|---|
| `ChSa` | Controle handmatige verkoop | boolean | Validate manual sales price |
| `OrLi` | Gebruiken in ordertraject | boolean | Use in order flow |
| `Ch` | Doorbelasten | boolean | Pass through costs |
| `ExTS` | Met Transsmart uitwisselen | boolean | Exchange with Transsmart (shipping platform) |

#### Weight & Dimensions

| Field | Dutch Label | Type | Allowed / Constraints | Description |
|---|---|---|---|---|
| `VaWt` | Gewichtseenheid | enum | `0`–`5` | Weight unit (see table below) |
| `NeWe` | Nettogewicht | number | Multiple of `0.001` | Net weight |
| `GrWe` | Brutogewicht | number | Multiple of `0.001` | Gross weight |
| `CsWe` | CBS-gewicht | number | Multiple of `0.001` | CBS statistical weight |
| `QuLe` | Voorkeur lengte | number | — | Preferred length |
| `QuWi` | Voorkeur breedte | number | — | Preferred width |
| `QuHe` | Voorkeur hoogte | number | — | Preferred height |
| `Stck` | Stapelbaar | boolean | — | Stackable |

**`VaWt` — Weight unit:**

| Value | Description |
|---|---|
| `0` | No weight |
| `1` | Microgram (µg) |
| `2` | Milligram (mg) |
| `3` | Gram (g) |
| `4` | Kilogram (kg) |
| `5` | Ton |

#### CBS / Statistics (Intrastat)

| Field | Dutch Label | Type | Constraints | Description |
|---|---|---|---|---|
| `CsGc` | CBS-goederencode | string | Max 8 chars | Commodity code |
| `CoOr` | CBS-land van oorsprong | string | Max 3 chars | Country of origin (ISO 3166) |
| `ExUn` | Aanvullende eenheid CBS | string | Max 15 chars | Supplementary unit |
| `CBSQuUn` | Aantal eenheden CBS | number | Multiple of `0.01` | Number of supplementary units |

#### Barcode

| Field | Dutch Label | Type | Allowed / Constraints | Description |
|---|---|---|---|---|
| `VaBc` | Type barcode | enum | `0`–`8` | Barcode type (see table below) |
| `BaCo` | Barcode | string | Max 30 chars | Barcode value |

**`VaBc` — Barcode type:**

| Value | Description |
|---|---|
| `0` | No validation |
| `1` | EAN-8 |
| `2` | UPC |
| `3` | EAN-13 |
| `4` | EAN-14 |
| `5` | SSCC |
| `6` | Code 128 |
| `7` | Interleaved 2/5 |
| `8` | Interleaved 2/5 (with check digit) |

#### Deposit & Packaging

| Field | Dutch Label | Type | Constraints | Description |
|---|---|---|---|---|
| `PcYn` | Emballage | boolean | — | Is packaging article |
| `PkTp` | Verpakkingssoort | string | Max 10 chars | Packaging type |
| `PkPr` | Statiegeld | number | Multiple of `1e-10` | Deposit amount |
| `RtPr` | Statiegeld retour | number | Multiple of `1e-10` | Return deposit amount |

#### Environmental / Recycling Fees

| Field | Dutch Label | Type | Constraints | Description |
|---|---|---|---|---|
| `DiFe` | Verwijderingsbijdrage | boolean | — | Disposal fee applies |
| `FoDi` | Verwijderingsbijdr. buitenl. levering | boolean | — | Apply disposal fee on foreign deliveries |
| `DiCo` | Bedrag verwijderingsbijdrage (excl. btw) | number | Multiple of `1e-10` | Disposal fee amount (excl. VAT) |
| `WeGl` | Gewicht glas (gr) | number | Multiple of `0.01` | Glass weight (grams) |
| `WeAl` | Gewicht aluminium (gr) | number | Multiple of `0.01` | Aluminium weight (grams) |
| `WeMe` | Gewicht overig metaal (gr) | number | Multiple of `0.01` | Other metal weight (grams) |
| `WePl` | Gewicht kunststof (gr) | number | Multiple of `0.01` | Plastic weight (grams) |
| `WeBp` | Gewicht biokunststof (gr) | number | Multiple of `0.01` | Bioplastic weight (grams) |
| `WePa` | Gewicht papier/karton (gr) | number | Multiple of `0.01` | Paper/cardboard weight (grams) |
| `WeWo` | Gewicht hout (gr) | number | Multiple of `0.01` | Wood weight (grams) |
| `WeOt` | Gewicht overig (gr) | number | Multiple of `0.01` | Other material weight (grams) |

#### Article Dimensions & Expiry

| Field | Dutch Label | Type | Constraints | Description |
|---|---|---|---|---|
| `StD1` | Artikeldimensie 1 | string | Max 10 chars | Article dimension 1 (e.g. colour) |
| `StD2` | Artikeldimensie 2 | string | Max 10 chars | Article dimension 2 (e.g. size) |
| `EdMn` | Expiratiedatum verplicht | boolean | — | Expiry date mandatory |

#### Auto-assignment (Batch/Serial)

| Field | Dutch Label | Type | Allowed | Description |
|---|---|---|---|---|
| `VaAs` | Toewijzen in verkoop | enum | `0`\|`1`\|`2` | Auto-assign on sales (`0`=none, `1`=ask, `2`=always) |
| `VaAb` | Wachtorders toewijzen | enum | `0`\|`1` | Assign backorders (`0`=no, `1`=yes) |

#### Administration

| Field | Dutch Label | Type | Description |
|---|---|---|---|
| `AdYn` | Administratie bijhouden | boolean | Track serial/batch administration |
| `AdSr` | Administratie serienummers | boolean | Serial number administration |

#### Substitution

| Field | Dutch Label | Type | Allowed / Constraints | Description |
|---|---|---|---|---|
| `SuIt` | Vervangend type item | enum | `Wst`\|`Pid`\|`Deg`\|`Dim`\|`Art`\|`Txt`\|`Sub`\|`Tsl`\|`Kst`\|`Sam`\|`Crs` | Replacement item type |
| `SuId` | Vervangend artikel | string | Max 40 chars | Replacement article code |
| `SuDe` | Vervangen t/m | date | — | Replaced until date |

#### Forecasting

| Field | Dutch Label | Type | Allowed | Description |
|---|---|---|---|---|
| `PreC` | Voorspelmodel | enum | `0`–`5` | Forecast model (see table below) |
| `ABCXYZClass` | ABC-XYZ klasse | string | Max 2 chars | ABC-XYZ classification |

**`PreC` — Forecast model:**

| Value | Description |
|---|---|
| `0` | No forecast |
| `1` | SMA — Simple Moving Average |
| `2` | ARIMA — AutoRegressive Integrated Moving Average |
| `3` | SARIMA — Seasonal ARIMA |
| `4` | Exponential Smoothing |
| `5` | Holt-Winters (Exponential Smoothing + trend + seasonality) |

#### Remarks (Multilingual)

| Field | Dutch Label | Type | Description |
|---|---|---|---|
| `Rm` | Opmerking | byte | Internal remark |
| `Rm_1031` | Opmerking (Duits) | byte | Remark (German) |
| `Rm_1036` | Opmerking (Frans) | byte | Remark (French) |
| `Rm_1043` | Opmerking (Nederlands) | byte | Remark (Dutch) |
| `Rm_2057` | Opmerking (Engels) | byte | Remark (English) |
| `Rm_2067` | Opmerking (Vlaams) | byte | Remark (Flemish) |

#### File Attachments

Up to 7 file slots. Each slot has a filename and a Base64-encoded byte stream.

| Fields | Description |
|---|---|
| `FileName` / `FileStream` | Primary attachment |
| `FileName1` / `FileStream1` … `FileName6` / `FileStream6` | Extra attachments 1–6 |

All `FileName*` fields: string, max 255 chars. All `FileStream*` fields: byte (Base64).

#### Other

| Field | Dutch Label | Type | Description |
|---|---|---|---|
| `UpdateComDs` | Omschrijving doorvoeren naar samenstellingsonderdelen | boolean | Propagate description to BOM components |

---

### Insert an Article

```http
POST /connectors/FbItemArticle
Authorization: AfasToken {base64_encoded_token}
Content-Type: application/json

{
  "FbItemArticle": {
    "Element": {
      "Fields": {
        "ItCd": "M365-E3-USER",
        "Ds": "Microsoft 365 E3 per user/month",
        "Ds_2057": "Microsoft 365 E3 per user/month",
        "Ds_1043": "Microsoft 365 E3 per gebruiker/maand",
        "Grp": "SOFTWARE",
        "VaTp": "0",
        "ArSu": "6",
        "BiSt": false,
        "BiUn": "PCS",
        "SaPrice": 35.00,
        "PuPrice": 28.50,
        "CuId": "EUR",
        "CoLa": "NL",
        "VaRc": "H",
        "Bl": false
      }
    }
  }
}
```

---

### Update Article Pricing

```http
PUT /connectors/FbItemArticle
Authorization: AfasToken {base64_encoded_token}
Content-Type: application/json

{
  "FbItemArticle": {
    "Element": {
      "Fields": {
        "ItCd": "M365-E3-USER",
        "SaPrice": 38.00,
        "PuPrice": 30.00,
        "DatPri": "2026-07-01"
      }
    }
  }
}
```

---

### Insert with Auto-numbered Code

```http
POST /connectors/FbItemArticle
Authorization: AfasToken {base64_encoded_token}
Content-Type: application/json

{
  "FbItemArticle": {
    "Element": {
      "Fields": {
        "AuId": true,
        "Ds": "New Product",
        "Grp": "HARDWARE",
        "VaTp": "0",
        "BiSt": true,
        "BiUn": "PCS",
        "SaPrice": 149.99
      }
    }
  }
}
```

---

### Insert with Custom Sub-object (FbArticleCustom)

Custom fields are nested under `Objects`:

```http
POST /connectors/FbItemArticle
Authorization: AfasToken {base64_encoded_token}
Content-Type: application/json

{
  "FbItemArticle": {
    "Element": {
      "Fields": {
        "ItCd": "CUSTOM-001",
        "Ds": "Custom article"
      },
      "Objects": {
        "FbArticleCustom": {
          "Element": {
            "Fields": {
              "YourCustomField": "value"
            }
          }
        }
      }
    }
  }
}
```

---

### Delete an Article

```http
DELETE /connectors/FbItemArticle
Authorization: AfasToken {base64_encoded_token}
Content-Type: application/json

{
  "FbItemArticle": {
    "Element": {
      "Fields": {
        "ItCd": "M365-E3-USER"
      }
    }
  }
}
```

---

## Salesbuildr_Voorcalculatie — GetConnector (Read Quotations)

**Connector name:** `Salesbuildr_Voorcalculatie`  
Read-only connector returning pre-calculation quotation headers from AFAS. Use this to check which quotations already exist before writing via `KnQuotation`.

```http
GET /connectors/Salesbuildr_Voorcalculatie?skip=0&take=100
Authorization: AfasToken {base64_encoded_token}
```

### Response Schema

```json
{
  "skip": 0,
  "take": 20,
  "rows": [
    {
      "offerte": "202600276-01D",
      "offerteOmschrijving": "Moderne werkplek Noviflora (fase 1)",
      "verkooprelatie": "10654",
      "verkooprelatieNaam": "Noviflora",
      "gemaakt": "2026-06-08T10:57:59Z",
      "gewijzigd": "2026-06-29T16:20:16Z"
    }
  ]
}
```

### Field Reference

| Field | Type | Description | Maps to `KnQuotation` |
|---|---|---|---|
| `offerte` | string | Quotation number (primary key) | `QuId` |
| `offerteOmschrijving` | string | Description | `Ds` |
| `verkooprelatie` | string | Customer account code | `DbId` |
| `verkooprelatieNaam` | string | Customer account name | — (joined) |
| `gemaakt` | datetime | Created timestamp | — |
| `gewijzigd` | datetime | Last modified timestamp | — |

### Filtering

```http
# Look up a specific quotation by number
GET /connectors/Salesbuildr_Voorcalculatie?filterfieldids=offerte&filtervalues=202600276-01D&operatortypes=1

# Quotations for a specific customer
GET /connectors/Salesbuildr_Voorcalculatie?filterfieldids=verkooprelatie&filtervalues=10654&operatortypes=1

# Quotations modified after a specific date (operator 4 = greater than; local time, no trailing Z)
GET /connectors/Salesbuildr_Voorcalculatie?filterfieldids=gewijzigd&filtervalues=2026-01-01T00:00:00&operatortypes=4
```

---

## KnQuotation — Pre-calculation / Quote (Voorcalculatie)

**Connector name:** `KnQuotation`

Manages pre-calculation quotations (voorcalculaties) in AFAS Profit.

**Primary key:** `QuId` (quotation number). Leave blank or omit for auto-assignment.

**Sub-objects:** `KnQuotationLine` (quotation lines) — nested under `Objects`.

---

### Field Reference

#### Identity & Header

| Field | Dutch Label | Type | Constraints | Description |
|---|---|---|---|---|
| `QuId` | Nummer offerte | string | Max 21 chars | Quotation number (primary key) |
| `QuDa` | Datum | date | — | Quotation date |
| `Ds` | Omschrijving | string | Max 100 chars | Description / title |
| `Re` | Opmerking | byte | — | Internal remark |

#### Relation

| Field | Dutch Label | Type | Constraints | Description |
|---|---|---|---|---|
| `DbId` | Verkooprelatie | string | Max 16 chars | Sales relation (debtor code) |
| `BcId` | Organisatie/persoon | string | Max 15 chars | Organisation or person code |

#### Address

| Field | Dutch Label | Type | Constraints | Description |
|---|---|---|---|---|
| `TaLn` | T.a.v. regel | string | Max 120 chars | Attention line |
| `AdLn` | Adresregel | string | Max 80 chars | Address line |
| `ReLn` | Woonplaatsregel | string | Max 80 chars | City line |
| `CoLn` | Landregel | string | Max 80 chars | Country line |
| `AdId` | Afleveradres | integer | — | Delivery address ID |

#### Project & Planning

| Field | Dutch Label | Type | Constraints | Description |
|---|---|---|---|---|
| `PrId` | Project | string | Max 15 chars | Project code |
| `PrSt` | Projectfase | string | Max 15 chars | Project phase |
| `FcNo` | Nummer forecast | integer | — | Related forecast sequence number |
| `PlDa` | Datum planning | date | — | Planning date |
| `DaTi` | Peildatum | date | — | Reference / valuation date |

#### Quotation Classification

| Field | Dutch Label | Type | Constraints | Description |
|---|---|---|---|---|
| `ViOr` | Soort offerte | string | Max 10 chars | Quotation type |
| `VaDa` | Geldigheidsdatum | date | — | Validity / expiry date |
| `SbAt` | Bijlage | integer | — | Attachment |

#### Order Type

| Field | Dutch Label | Type | Allowed | Description |
|---|---|---|---|---|
| `ETOr` | Soort order | enum | `I`\|`O`\|`S` | Order type: `I`=Installation · `O`=Maintenance · `S`=Breakdown/Fault |

#### Financial

| Field | Dutch Label | Type | Description |
|---|---|---|---|
| `CuId` | Valuta | string (max 3) | Currency code (e.g. `EUR`) |
| `InPc` | Factuurkorting (%) | number | Invoice discount percentage |
| `PaPc` | Betalingskorting (%) | number | Payment discount percentage |
| `PaCd` | Betaalvoorwaarde | string (max 5) | Payment terms code |
| `PaTp` | Betaalwijze | string (max 5) | Payment method code |
| `PrIt` | Verkoopprijs inclusief btw | boolean | Sales price includes VAT |

#### VAT

| Field | Dutch Label | Type | Description |
|---|---|---|---|
| `VaDu` | Btw-plicht | string (max 3) | VAT obligation code |
| `VaYN` | Afwijkende btw-tariefgroep | boolean | Override VAT rate group |

#### Cost Allocation (Verbijzondering)

Up to 5 cost allocation axes. Pass the dimension code relevant to your administration.

| Field | Dutch Label | Type | Constraints |
|---|---|---|---|
| `V1Cd` | Code verbijzonderingsas 1 | string | Max 16 chars |
| `V2Cd` | Code verbijzonderingsas 2 | string | Max 16 chars |
| `V3Cd` | Code verbijzonderingsas 3 | string | Max 16 chars |
| `V4Cd` | Code verbijzonderingsas 4 | string | Max 16 chars |
| `V5Cd` | Code verbijzonderingsas 5 | string | Max 16 chars |

#### Logistics

| Field | Dutch Label | Type | Constraints | Description |
|---|---|---|---|---|
| `War` | Magazijn | string | Max 15 chars | Warehouse code |
| `RePo` | Rapport voorcalculatie | string | Max 32 chars | Report layout code |

---

### Insert a Quotation

```http
POST /connectors/KnQuotation
Authorization: AfasToken {base64_encoded_token}
Content-Type: application/json

{
  "KnQuotation": {
    "Element": {
      "Fields": {
        "DbId": "ACME001",
        "QuDa": "2026-07-01",
        "VaDa": "2026-08-01",
        "Ds": "Microsoft 365 licentievoorstel",
        "ViOr": "STANDARD",
        "CuId": "EUR",
        "PaCd": "N30",
        "PrIt": false,
        "V1Cd": "SALES"
      }
    }
  }
}
```

---

### Insert a Quotation with Lines (KnQuotationLine)

```http
POST /connectors/KnQuotation
Authorization: AfasToken {base64_encoded_token}
Content-Type: application/json

{
  "KnQuotation": {
    "Element": {
      "Fields": {
        "DbId": "ACME001",
        "QuDa": "2026-07-01",
        "VaDa": "2026-08-01",
        "Ds": "Microsoft 365 licentievoorstel",
        "CuId": "EUR",
        "PaCd": "N30"
      },
      "Objects": {
        "KnQuotationLine": {
          "Element": [
            {
              "Fields": {
                "ItCd": "M365-E3-USER",
                "Qu": 10,
                "UP": 35.00
              }
            }
          ]
        }
      }
    }
  }
}
```

> **Note:** `KnQuotationLine` field definitions will be added as a separate section. Check the AFAS Swagger/App Connector documentation for the full line schema.

---

### Update a Quotation

```http
PUT /connectors/KnQuotation
Authorization: AfasToken {base64_encoded_token}
Content-Type: application/json

{
  "KnQuotation": {
    "Element": {
      "Fields": {
        "QuId": "OFF-2026-001",
        "VaDa": "2026-09-01",
        "InPc": 5.00
      }
    }
  }
}
```

---

### Delete a Quotation

```http
DELETE /connectors/KnQuotation
Authorization: AfasToken {base64_encoded_token}
Content-Type: application/json

{
  "KnQuotation": {
    "Element": {
      "Fields": {
        "QuId": "OFF-2026-001"
      }
    }
  }
}
```

---

## Promax Implementation Notes (Sync-Afas2Salesbuildr-Forecasts.ps1)

Concrete payloads used by the forecast sync script, as implemented.

### Filter syntax reminder

Delta sync filters use `operatortypes=4` (**greater than**) on the `gewijzigd` field.
Note `4` is greater-than; `5` is *less-than*. The datetime value must be local time in
`yyyy-MM-ddTHH:mm:ss` — a trailing `Z` or a bare date (no time) triggers a server error.

```
filterfieldids=gewijzigd&filtervalues=2026-01-01T00:00:00&operatortypes=4
```

Voorcalculatie idempotency check filters on `offerte` (equals, operator 1):

```
filterfieldids=offerte&filtervalues=SB-13&operatortypes=1
```

### Close a Forecast as won (`CmForecast`, `PUT`)

Triggered when a Salesbuildr Opportunity is closed-won; sets `ViOp` (verkoopkans-opvolging) to `"G"` (gewonnen).

```json
{ "CmForecast": { "Element": { "Fields": {
    "PrId": "<verkooprelatie>",
    "SqNo": <integer>,
    "ViOp": "G",
    "DaSc": "yyyy-MM-dd"
}}}}
```

`PrId` + `SqNo` form the composite key. `SqNo` is parsed by stripping the `afas-Forecast-` prefix off the Opportunity's `externalIdentifier`. `PrId` is the AFAS `verkooprelatie` — this is **not** on the Opportunity (its `companyExtId` holds the organisatienummer), so Flow 2 re-fetches the Forecast from AFAS by `SqNo` (`GET Salesbuildr_Forecasts?filterfieldids=forecast&filtervalues={SqNo}&operatortypes=1`) and reads `verkooprelatie` from it. The same value is used as `DbId` on the `KnQuotation` below.

### Create a Quotation with lines (`KnQuotation`, `POST`)

```json
{ "KnQuotation": { "Element": {
    "Fields": { "QuId": "SB-13", "DbId": "<verkooprelatie>",
                "QuDa": "...", "Ds": "...", "CuId": "EUR", "FcNo": 13 },
    "Objects": { "KnQuotationLine": { "Element": [
        { "Fields": { "ItCd": "...", "Qu": 1, "UP": 100.00 } }
    ]}}
}}}
```

- `QuId` = `"SB-{SqNo}"` — predictable, fits the 21-char limit, and doubles as the idempotency key (checked via the `Salesbuildr_Voorcalculatie` GetConnector, see filter above).
- `FcNo` links the quotation back to the originating Forecast.
- Line field `UP` is unit price — **not** `unitPrice`.

### Create a minimal Article (`FbItemArticle`, `POST`)

Created on demand when a quote line references an item code not yet present in AFAS (checked via `Salesbuildr_Artikelen` GetConnector, filtered on `itemCode`).

```json
{ "FbItemArticle": { "Element": { "Fields": {
    "ItCd": "...", "Ds": "...", "Ds_1043": "...",
    "VaTp": "0", "BiSt": false, "CoLa": "NL", "Bl": false
}}}}
```

> **Open TODO:** `ItCd` is currently set directly from the Salesbuildr quote item's `product.externalIdentifier`. The real Promax item-code generation logic still needs to be implemented — see `New-AfasArtikel` and the `$Regels` construction in Flow 2 step 2b (`Sync-Afas2Salesbuildr-Forecasts.ps1` ~line 515).

---

## Further Reading

- AFAS Developer Portal: `https://help.afas.nl/help/NL/SE/App_Cnnctr_Add.htm`
- App Connector documentation: `https://help.afas.nl/help/NL/SE/App_Cnnctr_Rest_Get.htm`
