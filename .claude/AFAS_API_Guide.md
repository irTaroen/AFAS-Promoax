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

Replace `{environment_number}` with your AFAS environment number (5-digit number provided by AFAS). For Promax this is **53307**.

### Environment types

AFAS provides three environment types. The domain suffix selects which one you hit:

| Type | Base URL | Purpose |
|---|---|---|
| **Production** | `https://{id}.rest.afas.online/ProfitRestServices` | Live environment where customers work |
| **Test** | `https://{id}.resttest.afas.online/ProfitRestServices` | Usually a snapshot copy of production for testing; may also be a demo/template environment |
| **Accept** | `https://{id}.restaccept.afas.online/ProfitRestServices` | First to receive a new AFAS Profit version — customers test a release here before production is updated |

> There is **no** way to push definition changes from accept/test to production automatically. Connector definitions must be manually [imported/exported](https://help.afas.nl/help/NL/SE/App_Cnnctr_ImpExp.htm).

### Request URL anatomy

`https://12345.rest.afas.online/ProfitRestServices/connectors/Profit_Employees?skip=0&take=1`

| Part | Example | Description |
|---|---|---|
| Protocol | `https` | Always HTTPS |
| Environment id | `12345` | The customer's AFAS domain (5 digits) |
| API service | `rest` | The REST web service |
| Environment type | *(empty)* / `test` / `accept` | Empty for production; `test`/`accept` otherwise |
| Domain | `afas.online` | Hosting domain |
| Endpoint path | `/connectors/Profit_Employees` | Connector being addressed |
| Query parameters | `?skip=0&take=1` | Key-value pairs after `?`, joined with `&` |

---

## Authentication

Every request requires an `Authorization` header with your AFAS token.

### Token Format

The raw token is an XML string:

```xml
<token><version>1</version><data>{TOKEN_DATA}</data></token>
```

This XML string must be **Base64-encoded** before use. Store the raw token in a secure location outside version control (e.g. a gitignored `configs/config.xml`) and encode it at runtime.

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

A GetConnector is an endpoint an AFAS administrator composes in Profit; it determines which records and fields you can read. Call it with `GET`; to receive new data you issue a new request (polling). A GetConnector may also carry a **built-in** filter or authorization configured in Profit (e.g. "current year only") on top of any per-request filter you send.

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
| `filterjson` | URL-encoded JSON filter (alternative to the three params above) | see [JSON filter](#json-filter-filterjson) |
| `orderbyfieldids` | Field(s) to sort by (prefix `-` for descending) | `DaSt` |

### Filter operators (`operatortypes`)

The full set of operators supported by AFAS Profit:

| Value | Meaning | Symbol |
|---|---|---|
| `1` | equal | `=` |
| `2` | greater than or equal | `>=` |
| `3` | less than or equal | `<=` |
| `4` | **greater than** — use this for delta sync | `>` |
| `5` | less than | `<` |
| `6` | contains | `*` |
| `7` | not equal | `!=` |
| `8` | is empty | `[]` |
| `9` | is not empty | `![]` |
| `10` | starts with | `@` |
| `11` | does not contain | `!*` |
| `12` | does not start with | `!@` |
| `13` | ends with | `&` |
| `14` | does not end with | `!&` |
| `15` | quick filter (snelfilter) | `Sf` |

> ⚠️ **Operator 4, not 5, is "greater than".** Operator `5` is *less than*. An earlier version of the sync used `5` for delta and silently returned 0 rows.

> ⚠️ **Datetime filter format:** use `yyyy-MM-ddTHH:mm:ss` in **local** time — e.g. `2026-06-29T00:00:00`. A trailing `Z` (UTC designator) causes a server error (`Conversion from string "0Z" to type 'Integer' is not valid`), and a bare date with no time component also fails.

> **Operators 8 / 9 (empty / not empty):** you must still pass a `filtervalues` entry, but it may be empty — e.g. `filterfieldids=PrefixBirthName&operatortypes=8&filtervalues=""`.

### Combining filters — AND / OR

With the `filterfieldids` / `filtervalues` / `operatortypes` triple, the separator between values decides the boolean relationship. All three parameters must list their entries in the same order and count.

**AND** — separate with a comma `,`:

```
GET /connectors/Profit_Administrations?filterfieldids=fieldA,fieldB&filtervalues=valueA,valueB&operatortypes=1,1
```

**OR** — separate with a semicolon `;`:

```
GET /connectors/Profit_Administrations?filterfieldids=fieldA;fieldB&filtervalues=valueA;valueB&operatortypes=1;1
```

### JSON filter (`filterjson`)

For anything beyond a flat AND/OR list, pass a single URL-encoded JSON object in the `filterjson` query parameter instead of the three separate params. This keeps complex filters readable.

**Semantics:** fields **within one** `Filter` have an **AND** relationship; multiple `Filter` blocks have an **OR** relationship between them.

The example below filters on `(AdminId = 1 AND AdminNm contains 'Internet') OR (AdminId = 3 AND AdminNm = 'Internet')`:

```json
{
    "Filters": {
        "Filter": [{
                "@FilterId": "Filter 1",
                "Field": [
                    { "@FieldId": "AdminId", "@OperatorType": "1", "#text": "1" },
                    { "@FieldId": "AdminNm", "@OperatorType": "6", "#text": "Internet" }
                ]
            }, {
                "@FilterId": "Filter 2",
                "Field": [
                    { "@FieldId": "AdminId", "@OperatorType": "1", "#text": "3" },
                    { "@FieldId": "AdminNm", "@OperatorType": "1", "#text": "Internet" }
                ]
            }
        ]
    }
}
```

Structure notes:
- `@FieldId` — the field to filter on; `@OperatorType` — an operator value from the table above; `#text` — the filter value.
- With a **single** filter and a **single** field, `Filter` and `Field` are plain objects (not arrays):

  ```json
  { "Filters": { "Filter": { "@FilterId": "Filter 1",
      "Field": { "@FieldId": "Medewerker", "@OperatorType": "1", "#text": "ALLARDJ" } } } }
  ```

The JSON must be **URL-encoded** into the request:

```
GET /connectors/Profit_Administrations?filterjson=%7B%22Filters%22%3A%7B%22Filter%22%3A%5B...%5D%7D%7D&skip=0&take=20&orderbyfieldids=AdminId
```

> **Downside:** `filterjson` inflates the query string and hits the URL length limit (see below) much sooner.

**Example (simple triple-parameter filter):**

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

> Datetime fields end with a `Z`; AFAS recommends **ignoring** the `Z` — the time is always Amsterdam time, not UTC.

### Skip and take (pagination)

Profit tables can hold far more data than you want in one response. Every GetConnector `GET` applies `skip` and `take`, defaulting to `skip=0`, `take=100`.

- Rule of thumb for a healthy request: `[number of columns] × [number of rows] < 150.000`. A good request completes within ~1000 ms.
- Fetching too much yields an HTTP `500` with `Out of String space` / `Out of memory`. Implement `skip`/`take` robustly to avoid over-fetching and excessive requests.
- **Deep paging is slow:** performance degrades as `skip` grows; beyond `skip` ≈ 100.000 it is generally unacceptable. Instead, slice the data by adjusting the *filter* per call (e.g. per article, per employee, per posting date), and still use `skip`/`take` within each slice. Up to **5 concurrent** calls are allowed to shorten wall-clock time.
- **Get-all** (`skip=-1&take=-1`) fetches everything in one go. AFAS **strongly discourages** this — it can overload the AFAS servers and your own system. Prefer a generous but bounded `take`.

> ⚠️ **`orderbyfieldids` is mandatory when using `skip`/`take`.** Without it the database picks an arbitrary (and possibly varying) order, so rows can be skipped or duplicated across pages.

### OrderBy

`orderbyfieldids` sets the sort order; you may list multiple fields. Prefer **integer** fields — they have the fastest index.

- Ascending: `orderbyfieldids=Account`
- Descending: prefix with `-` → `orderbyfieldids=-Account`
- Multiple fields (URL-encode the comma as `%2C`): `orderbyfieldids=Account%2CType`

### URL length limit

The **parameter string** (everything from `?` onward, including `?` and `&`) is limited to **2049 characters**. Exceeding it returns HTTP **`404 Not Found`**. This is the main practical constraint on large `filterjson` filters.

### MetaInfo request

Ask a connector to describe itself — fields, per-field data type, labels, field length, and (for coded fields) the code-table values — by inserting `/metainfo/get/` before the connector name:

```
GET /metainfo/get/Profit_Accounts
```

```json
{
  "name": "Profit_Accounts",
  "description": "Grootboekrekeningen (Financieel)",
  "fields": [
    { "id": "Account", "fieldId": "U001", "dataType": "string", "label": "Rekeningnummer", "length": 16, "controlType": 5, "decimals": 0, "decimalsFieldId": "" }
  ]
}
```

A `MetaInfo` request with no connector name lists all GetConnectors in the environment (and shows which are blocked).

### Row count

There is no direct count parameter. To get a row count, an AFAS administrator makes a copy of the GetConnector, adds a **verdichting** (grouping/aggregation) on the key, and hides the other fields.

---

## UpdateConnector — Writing Data

An external application inserts, updates, or deletes records in the Profit database via an UpdateConnector (which operations are allowed varies per endpoint). Every UpdateConnector has a [`metainfo`](https://docs.afas.help/profit/nl/apidoc) request that lists all available fields, including custom fields (vrije velden).

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

> `@`-prefixed properties on `Element` are **key / attribute** values (e.g. `"@UsId": "..."`), distinct from the record data inside `Fields`.

### POST — insert & validation

`POST` creates records. AFAS validates before creating; a failed validation returns HTTP **`500`**. Examples of validations: BSN must pass the 11-check, an address must carry a country code, a financial mutation must balance (debit total = credit total).

A successful UpdateConnector call usually returns **`201`**. The `FieldId` in the response body is the **primary key** of the object the POST acted on:

```json
{ "results": { "KnSubject": { "SbId": "999999" } } }
```

### POST on a sub-object

Nested UpdateConnectors let you update the main object while inserting into a sub-object (e.g. add an article line to an existing sales order). Two methods:

**1. `@Action` tag in the body.** Add `@Action` as a property of a `Fields` object. Allowed values: `insert`, `update`, `delete`. The whole body is validated and processed as one transaction — flexible for deeply nested structures (up to ~6 levels; common on `KnEmployee`, `FbDeliveryNote`, `FbSales`, etc.). Example — deactivate one bank account and add another on an employee in a single request:

```json
{
  "AfasEmployee": {
    "Element": {
      "@EmId": "1234568774",
      "Fields": { "@Action": "update" },
      "Objects": [{
        "AfasBankInfo": {
          "Element": [
            { "@AcId": "NL57RABO0312000111", "@NoBk": false,
              "Fields": { "@Action": "update", "SeNo": 3, "SaAc": false, "Iban": "NL57RABO0312000111" } },
            { "@AcId": "NL40BOTK0755026802", "@NoBk": false,
              "Fields": { "@Action": "insert", "SaAc": true, "IbCk": true, "Iban": "NL40BOTK0755026802" } }
          ]
        }
      }]
    }
  }
}
```

**2. Sub-object in the URL.** POST straight at the sub-object path; updating the main object is then optional. Deeper nested objects in the body are created too.

- Main object: `../ProfitRestServices/connectors/HrMobility`
- Sub-object: `../ProfitRestServices/connectors/HrMobility/HrEmployeeMobilityRegistration`

### PUT — update

Per endpoint the OpenAPI spec states which actions are allowed. On a `PUT`, only the **key fields** are required (usually the same keys as the `POST` result). A `PUT` updates every field it is given, plus every sub-object whose key is supplied.

**Clearing a field:** send an empty value. E.g. to blank a filled `Ds` field: `"Ds": ""`.

### DELETE

Some endpoints allow `DELETE`. This is a **permanent** delete — the record no longer exists afterwards. Pass the key as **URL parameters**, not a body:

```
DELETE /connectors/KnAppointment/KnAppointment/ApId/123
```

This deletes the `KnAppointment` whose `ApId` = `123`. To delete a **nested** row, include the full key path of both the main element and the sub-element in the URL.

> The body-based DELETE examples further down in this guide are the equivalent for connectors that accept a keyed body; the URL-parameter form above is the form AFAS documents for `DELETE`.

---

## Salesbuildr_Organisaties — GetConnector (Read Organisations)

**Connector name:** `Salesbuildr_Organisaties`  
Read-only connector returning organisation/company records from AFAS, used to upsert companies into Salesbuildr (no dedicated sync script currently). No corresponding UpdateConnector — organisations are written to Salesbuildr, not back to AFAS.

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

> **Note:** Promax uses `NL` → `NL` country mapping directly. Exceptions (e.g. `B` → `BE`) are configured in `configs/config.xml` under `<countrymapping>`.

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
| `artikelgroep` | string\|null | Article group code | `Grp` (the `FbItemArticle` write field for article group; the read connector surfaces it as `artikelgroep`) |

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

## Salesbuildr_DebiteurenCrediteuren — GetConnector (no longer used)

Flow 3 no longer reads this connector (the `<afas><connectors><debcred_get>` config key is no longer read; `Get-AfasInkooprelatie` is removed). The supplier → AFAS crediteurcode mapping now comes from `configs/mapping-leveranciers.xml` (SB `supplier.name` → `AFAS-cred`), see [KnQuotation](#knquotation--pre-calculation--quote-voorcalculatie) below.

---

## KnQuotation — Pre-calculation / Quote (Voorcalculatie)

**Connector name:** `KnQuotation`

Manages pre-calculation quotations (voorcalculaties) in AFAS Profit.

**Primary key:** `QuId` (quotation number). Leave blank or omit for auto-assignment. For Promax, AFAS itself creates the voorcalc, and its number (`QuId`) is the **SB offerte number** — the Salesbuildr primary quote's `number` (`QuoteResponseDto.number`, e.g. `2026-00380`) — **not** the forecast id.

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

## Salesbuildr_Dossieritems — GetConnector (Read Attachment Records)

**Connector name:** `Salesbuildr_Dossieritems`  
Read-only connector returning dossieritem (attachment) records linked to a quotation. Use this to check whether a SalesBuildr quote PDF has already been attached to an AFAS quotation before writing via `KnSubject` (the `KnSubject` POST itself is **not** idempotent).

```http
GET /connectors/Salesbuildr_Dossieritems?skip=0&take=100
Authorization: AfasToken {base64_encoded_token}
```

### Response Schema

```json
{
  "skip": 0,
  "take": 100,
  "rows": [
    {
      "Type": 46,
      "Ja_Nee": true,
      "Verkooprelatie": "10654",
      "Offerte": "2026-00380"
    }
  ]
}
```

### Field Reference

| Field | Type | Description | Maps to `KnSubject` |
|---|---|---|---|
| `Type` | integer | Dossieritemtype | `StId` |
| `Ja_Nee` | boolean | Whether the attachment is present | — (idempotency flag) |
| `Verkooprelatie` | string | Customer account code (debtor code) | `KnSubjectLink.SfId` |
| `Offerte` | string | AFAS voorcalc number (SB offerte number, e.g. `2026-00380`; = `KnQuotation.QuId`) | `KnSubjectLink.QuId` |

### Filtering

```http
# Look up existing attachments for a given quotation (AFAS forecast id)
GET /connectors/Salesbuildr_Dossieritems?filterfieldids=Offerte&filtervalues=2026-00380&operatortypes=1
```

A row with `Type` equal to the configured dossieritemtype (`StId`, see Promax Implementation Notes below) and `Ja_Nee == true` means the SB quote PDF is already attached — Flow 4 skips creation in that case.

---

## KnSubject — Dossieritem (Attachment)

**Connector name:** `KnSubject`

Creates a dossieritem (file attachment) in AFAS Profit, optionally linked to a relation/subject and carrying a file attachment sub-object. Used by Flow 4 to attach the SalesBuildr quote PDF to the AFAS quotation.

**Sub-objects:** `KnSubjectLink` (links the dossieritem to a relation/subject), `KnSubjectAttachment` (the file itself) — both nested under `Objects`.

> ⚠️ Unlike `CmForecast` (`PUT`) and `KnQuotation` (idempotency checked via `offerte` before creating), a `KnSubject` `POST` is **not** idempotent — re-posting creates a duplicate attachment. Always check `Salesbuildr_Dossieritems` first (see above).

---

### Field Reference

#### Identity & Header

| Field | Type | Description |
|---|---|---|
| `StId` | integer | Dossieritemtype (e.g. `46`) — configurable via `configs/config.xml`'s `<afas><kn_subject_stid>` |
| `Ds` | string | Description |
| `Da` | datetime | Date/time (`yyyy-MM-ddTHH:mm`) |
| `UsId` | string | AFAS user id that owns the dossieritem — configurable via `configs/config.xml`'s `<afas><kn_subject_usid>` |

#### `KnSubjectLink` (sub-object)

| Field | Type | Description |
|---|---|---|
| `ToSR` | boolean | Link to subject/relation (always `true` in Promax usage) |
| `SfTp` | integer | Source type of the link target — always `4` in Promax usage |
| `SfId` | string | Source id — the verkooprelatie/debtor code |
| `QuId` | string | Quotation number (AFAS voorcalc number = SB offerte number) the dossieritem is linked to |

#### `KnSubjectAttachment` (sub-object)

| Field | Type | Description |
|---|---|---|
| `FileName` | string | File name including extension (e.g. `SB-Offerte-2026-00380.pdf`) |
| `FileStream` | string (Base64) | The file's raw bytes, Base64-encoded |

---

### Insert a Dossieritem with an Attachment

```http
POST /connectors/KnSubject
Authorization: AfasToken {base64_encoded_token}
Content-Type: application/json

{
  "KnSubject": {
    "Element": {
      "Fields": {
        "StId": 46,
        "Ds": "SB Offerte - 2026-00380",
        "Da": "2026-07-14T10:00",
        "UsId": "53307._sa_salesbldr"
      },
      "Objects": [
        {
          "KnSubjectLink": {
            "Element": {
              "Fields": {
                "ToSR": true,
                "SfTp": 4,
                "SfId": "10654",
                "QuId": "2026-00380"
              }
            }
          }
        },
        {
          "KnSubjectAttachment": {
            "Element": {
              "Fields": {
                "FileName": "SB-Offerte-2026-00380.pdf",
                "FileStream": "{base64_encoded_pdf}"
              }
            }
          }
        }
      ]
    }
  }
}
```

---

## Promax Implementation Notes (Sync-Forecasts.ps1)

Concrete payloads used by the forecast sync script, as implemented.

### Filter syntax reminder

Delta sync filters use `operatortypes=4` (**greater than**) on the `gewijzigd` field.
Note `4` is greater-than; `5` is *less-than*. The datetime value must be local time in
`yyyy-MM-ddTHH:mm:ss` — a trailing `Z` or a bare date (no time) triggers a server error.

```
filterfieldids=gewijzigd&filtervalues=2026-01-01T00:00:00&operatortypes=4
```

AFAS quotation (`KnQuotation`, voorcalculatie — distinct from the Salesbuildr "SB quotation") idempotency check filters on `offerte` (equals, operator 1):

```
filterfieldids=offerte&filtervalues=2026-00380&operatortypes=1
```

`2026-00380` is the voorcalc number = the SB offerte number (the Salesbuildr primary quote's `number`, `$VoorcalcId = $WonQuotes[$OpportunityId].number` in Flow 3 / `$Quote.number` in Flow 4). It is **not** derived from the forecast id (no `{year}{forecastId}`) and **not** `SB-{SqNo}` as in an earlier version. A blank `number` → WARNING "Primaire SB-quote heeft geen offertenummer — voorcalculatienummer onbekend, overgeslagen, watermerk vastgehouden", skip, watermark held (Flow 3/4).

Since AFAS itself creates the main voorcalculatie, this lookup is now only a **precondition** in Flow 4 (the voorcalc must exist, else the PDF is not attached and the watermark held), filtering on `offerte = {VoorcalcId}`. Flow 3 does not do this lookup up front: it sends the `PUT KnQuotation` blind and only after a failed PUT calls `Get-AfasQuotation` (same filter, in its own `try`; an error counts as unknown) to diagnose. Voorcalc does not exist → WARNING "Hoofd-voorcalculatie ({VoorcalcId}) bestaat niet in AFAS — overgeslagen ..."; otherwise (exists, or lookup failed) → ERROR "Fout bij bijwerken AFAS-quotation ({VoorcalcId}), regels: {itemcode (VaIt n), ...} — AFAS-melding: {AFAS error text}" (from `$_.ErrorDetails.Message`, falling back to the exception text). Both skip, Forecast stays open, watermark held. The AFAS error text is not pattern-matched. **Known AFAS error example**: `"De ingevulde waarde bij 'Itemcode' bestaat niet."` (errorNumber -2147220469) — it refers to a **line** item code (an artikel line `VaIt=2` whose `ItCd` `326` is actually a werksoort in AFAS), not to a missing voorcalc. The Flow 3 **idempotency** key is the AFAS Forecast's `status`: `Get-AfasForecast` queries the `Salesbuildr_Forecasts` GetConnector filtered on `forecast` (equals, operator 1):

```
filterfieldids=forecast&filtervalues=11310&operatortypes=1
```

Flow 3 reads the row's `statusCode` (`Get-AfasForecastStatusCode`, trimmed + upper-cased): `G` (gesloten en gescoord) or `N` (gesloten, niet gescoord) → already closed, INFO and the opportunity is skipped entirely (no voorcalc lines, no close, not a watermark hold); `O` (open) → continue; any other or empty value → WARNING, skip, watermark held (never guess, to avoid duplicate lines). The same `statusCode` check also guards the Lost branch (Stap 3d) before closing with `ViOp = "N"`: `G`/`N` → INFO skip, `O` → close, not found/other → WARNING + watermark held. `status` holds the description (e.g. `Open`, `Gesloten en gescoord`) and is only logged. `Salesbuildr_Forecasts` fields used: `forecast`, `forecastOmschrijving`, `volgnummer`, `status`, `statusCode`, `gemaakt`, `gewijzigd`, `organisatie`, `verkooprelatie`, ...

A line-level GetConnector `Salesbuildr_Voorcalculatie_Extra` also exists in AFAS (fields: `offerte`, `offerteOmschrijving`, `itemCode`, `itemOmschrijving`, `aantal`, `aantalVerkoop`, `kostprijs`, `verkoopprijs`, `verkooprelatie`, `verkooprelatieNaam`, `gemaakt`, `gewijzigd`) but is **not used** by the script.

### Opportunity `externalIdentifier` format

Flow 1 sets the Salesbuildr Opportunity's `externalIdentifier` to `afas-Forecast-{forecast}-{volgnummer}-{verkooprelatie}` (e.g. `afas-Forecast-11310-42-10654`), encoding three distinct `Salesbuildr_Forecasts` fields so Flows 3 and 4 can parse the CmForecast key directly from it (Flow 3 fetches the Forecast only for the status check; Flow 4 does no Forecast re-fetch):

| Field | Example | Role |
|---|---|---|
| `forecast` | `11310` | Globally-unique AFAS forecast id — used for `Get-AfasForecast` lookups (Flow 3 status check) only; unrelated to the voorcalc number / `KnQuotation.QuId` (= SB offerte number). **Not** the CmForecast key. |
| `volgnummer` | `42` | CmForecast `SqNo` (composite key part) |
| `verkooprelatie` | `"10654"` | CmForecast `PrId` (composite key part; AFAS debtor code); also used as the AFAS quotation's `KnQuotation.DbId` |

Flow 3 (quotation creation / Forecast close) and Flow 4 (PDF attachment) each parse all three back out independently via regex `^afas-Forecast-(?<fc>\d+)-(?<sqno>\d+)-(?<pr>.+)$` (`ConvertFrom-ForecastExternalId`).

### Close a Forecast as won or lost (`CmForecast`, `PUT`)

Triggered when a closed/lost Salesbuildr Opportunity is categorized Won or Lost (`statusId = 'lost'` → Lost directly; `closed` → by its **primary quote** — see [Salesbuildr_API_Guide.md](Salesbuildr_API_Guide.md#promax-implementation-notes-sync-forecastsps1)). The composite primary key `PrId` (verkooprelatie) + `SqNo` (volgnummer) is passed as `@`-prefixed **Element-level** attributes, not inside `Fields`:

```json
{ "CmForecast": { "Element": {
    "@PrId": "10654",
    "@SqNo": 42,
    "Fields": { "ViSt": "5", "ViOp": "G", "ViRe": "00", "DaSc": "2026-07-05", "OrAF": 6284.21 }
}}}
```

Won (`ViOp: "G"`) example above; Lost is identical except `"ViOp": "N"` and **no** `OrAF` field at all.

- `@PrId` / `@SqNo` are parsed straight from the Opportunity's `externalIdentifier` (see format above) — Flow 3 no longer re-fetches the Forecast from AFAS.
- For Won opportunities, this close call is wrapped in its own `try`/`catch` (separate from the `KnQuotation` creation above): if it fails, the flag is cleared and the opportunity is skipped, but the AFAS quotation created earlier in the same run is **not** rolled back — the next run's idempotency check (see above) picks it up and just retries the close.
- `ViSt` is always `"5"` (both Won and Lost).
- `ViRe` is always `"00"`.
- `DaSc` is currently the current date (placeholder — revisit later for a real close date).
- `OrAF` (total quote amount) is included **only** for Won; it's computed client-side from the primary quote's items since `QuoteResponseDto` has no ready-made total: `Σ (price × quantity × (1 - discount))` (`discount` is a decimal fraction; near-zero values like `-1e-6` are rounding noise; `setupPrice` and quote-level discount are ignored).

### Update an AFAS quotation with lines (`KnQuotation`, `PUT`)

**Updates** the **existing** AFAS quotation (`KnQuotation`, voorcalculatie — distinct from the Salesbuildr "SB quotation" it originates from) via `Update-AfasQuotation` (`PUT`, replaced `New-AfasQuotation`/`POST`). The main voorcalculatie is created by AFAS itself; Flow 3 updates its header and **inserts** the voorcalculatieregels in one transaction. All SB quote lines for one opportunity go into a **single** payload: `KnQuotationLine.Element` is an array of `{ "Fields": {...} }` objects inside one `Objects` entry, one array item per SB quote line:

```json
{ "KnQuotation": { "Element": {
    "@QuId": "2026-00380",
    "Fields": {
        "@Action": "update", "Ds": "Moderne werkplek Noviflora (fase 1)",
        "UA766A69149986338FE462D83768E24DA": "PO-12345",
        "U1D8B1C0045A26507C9B67995789BFF16": "G"
    },
    "Objects": [ { "KnQuotationLine": { "Element": [
        {
          "Fields": {
            "@Action": "insert",
            "VaIt": "2", "ItCd": "EP2-20095", "UnId": "St",
            "QuUn": "1", "Qu": "1", "QuSa": "1",
            "Upri": "1749.03", "AmCo": "1381.73",
            "UC61B5DF54390117579CF9AA289E985F0": true,
            "U69BD7B0B402F2007FEC9E485BB4B59C9": "50029"
          }
        },
        {
          "Fields": {
            "@Action": "insert",
            "VaIt": "1", "ItCd": "101", "UnId": "",
            "QuUn": "2", "Qu": "2", "QuSa": "2",
            "Upri": "99.95", "AmCo": "0",
            "StId": "N"
          }
        }
    ] } } ]
}}}
```

- `@QuId` = the voorcalc number = SB offerte number (`$VoorcalcId`, e.g. `"2026-00380"`) — an **Element-level `@`-attribute**, like `CmForecast`'s `@PrId`/`@SqNo`, **not** a `Fields` entry; it identifies the **existing** voorcalc (= `offerte` in `Salesbuildr_Voorcalculatie`). Header `Fields` carry `"@Action": "update"`, `Ds` and the free field below; every `KnQuotationLine` `Fields` carries `"@Action": "insert"`.
- `DbId`, `FcNo` and `QuDa` are **no longer sent** (the existing voorcalc already has them); the earlier `ConvertTo-AfasQuotationBody -DbId/-FcNo` params were removed.
- `Ds` (omschrijving) = the SB quote's `title` (`QuoteResponseDto.title`), capped at 100 chars (AFAS limit).
- **Idempotency / known risk:** the line insert is **not** idempotent. Flow 3 guards it via the Forecast `statusCode` (already `G` or `N` → skip, see above). If the update succeeds but the subsequent Forecast close (`CmForecast`, `ViOp = "G"`) fails, the Forecast is still open and the next run re-inserts the lines (duplicates) — such an ERROR needs manual review.
- `Objects` holds one `KnQuotationLine` with one `Element` array containing one entry per quote line (see example above — one article line, one werksoort line).
- **Line fields (`ItCd`/`VaIt` resolved per line by `Resolve-AfasLineItem`):** `ItCd = mpn` with `VaIt = "2"` (artikel) when the quote line has an `mpn`; otherwise, when the line's main category is **"Diensten"** (`configs/config.xml`'s `<salesbuildr><diensten_maincategory_id>`, SB main-category id `UyOpp42UPGy3LKgSOQGX` by default), `ItCd` = the line's **`internalProductId`** (via `Get-SalesbuildrProductInternalId` — always a full `GET /public-api/product/{id}` fetch, the inline quote-line `product` reference never carries `internalProductId`) with `VaIt = "1"` (werksoort) if that code already exists in AFAS, or `VaIt = "3"` (tekstregel/TXT, `ItCd` forced to `"SBO"`) if it doesn't (or `internalProductId` is blank) — see the **three `KnQuotationLine` shapes** below and [Salesbuildr_API_Guide.md](Salesbuildr_API_Guide.md#promax-implementation-notes-sync-forecastsps1) for the full resolution logic. The **old "AFAS werksoort" product custom field is no longer read** — a werksoort must now sit under the Diensten main category. Diensten item codes are **referenced only**, same as before — never created via `FbItemArticle` (that connector creates articles, `VaTp`/`type=2`, only) — but a Diensten code missing from AFAS no longer makes the line unavailable; it becomes a TXT line instead (never a skip). **Subscription lines (abonnementen) always become a TXT line** (`VaIt = "3"`, `ItCd = "SBA"` — not `"SBO"`, which is only for Diensten TXT lines): `Resolve-AfasLineItem` checks `QuoteItemResponseDto.term` FIRST (before `mpn`) — any non-empty `term` other than `one-time` (seen: `one-time`, `month`, `year`) returns `Kind = 'abonnement'`, even when the line has an `mpn` or is under Diensten; the Regel carries an extra `Termijn` field, gets no existence check, and never causes a skip (crediteur free fields still apply when the supplier is mapped). A line with neither an `mpn` nor a Diensten main category (and no subscription `term`) is unmappable. `ConvertTo-AfasQuotationBody` sets `VaIt` from each Regel's `Soort` field (falls back to `"2"` if absent). `UnId` = unit: `"St"` (stuks/pieces) on artikel lines, **empty string `""`** on werksoort and TXT lines. `QuUn`/`Qu`/`QuSa` are all set to the line `quantity` on artikel/werksoort lines, and to **empty strings** on a TXT line. `Upri` = per-unit sell price (`price`) on artikel/werksoort lines, empty string on TXT. `AmCo` = per-unit cost (`cost`) on an artikel line, **always `"0"`** on a werksoort line, empty string on TXT. All amounts are serialized as invariant-culture strings with a **dot** decimal separator (e.g. `"1749.03"`, never `"1749,03"`).
- **PO number (free field `UA766A69149986338FE462D83768E24DA`):** the header carries `UA766A69149986338FE462D83768E24DA` = the SB quote's `poNumber` (primary quote, `QuoteResponseDto.poNumber`) **only when non-blank**; omitted otherwise so a blank PO does not wipe an existing value in AFAS; `Re` (Opmerking) is **not** sent (`-PoNumber` param on `ConvertTo-AfasQuotationBody` / `Update-AfasQuotation`).
- **Free fields:** the `KnQuotation` **header** always carries a constant free field `U1D8B1C0045A26507C9B67995789BFF16 = "G"`. A **werksoort** line (`VaIt="1"`) always carries `StId = "N"` on the line (unrelated to `KnSubject.StId`/dossieritemtype used by Flow 4 — same field name, different connector). **Every** line type — artikel (`VaIt="2"`), werksoort (`VaIt="1"`) and TXT (`VaIt="3"`, SBO and SBA) — carries `U69BD7B0B402F2007FEC9E485BB4B59C9` = the AFAS **crediteurcode** together with `UC61B5DF54390117579CF9AA289E985F0 = true` (boolean) — **only when** the Regel's `CredCode` is non-blank; the code comes from `configs/mapping-leveranciers.xml` (`$LeverancierMap`), keyed on the SB quote line's `supplier.name` (`Get-SalesbuildrLineSupplierName`, trimmed, case-insensitive). An unmapped supplier logs one WARNING per name in Stap 3b and **both** fields are omitted from that line (no skip, watermark still advances); UC61 is no longer always true on artikel lines.
- ⚠️ **Whole-opportunity enforcement (Flow 3, Stap 3c):** if any line of a Won opportunity is unmappable (no `mpn` and not a Diensten line) or resolves to an **article** (`Kind = 'artikel'` only) unavailable in AFAS (not yet created — that's Flow 2's job), the **entire opportunity** is skipped — the AFAS quotation is not updated (no lines inserted) and the originating Forecast is **not** closed (stays open), with the watermark held for retry. This extends the earlier unmapped-artikelgroep skip (see `Grp` below, which happens in Flow 2 and surfaces here in Flow 3 as a missing article) to cover unmappable/unavailable article lines in general. **Diensten and subscription lines are exempt** — a Diensten line always resolves to a werksoort or TXT line (see below) and can never trigger this skip, even when its `internalProductId` doesn't exist in AFAS.

#### The three `KnQuotationLine` shapes (`VaIt` values)

`VaIt` on a `KnQuotationLine` was previously undocumented here; it now has three possible values, all produced by `Resolve-AfasLineItem` / `ConvertTo-AfasQuotationBody`:

| `VaIt` | Meaning | When |
|---|---|---|
| `"2"` | Artikel | Quote line has an `mpn` |
| `"1"` | Werksoort | Quote line has no `mpn`, is under the Diensten main category, and its `internalProductId` already exists in AFAS |
| `"3"` | Tekstregel (TXT) | Quote line has no `mpn`, is under the Diensten main category, and its `internalProductId` is blank or not found in AFAS — **or** the line is a subscription (`term` non-empty and not `one-time`), regardless of `mpn`/category |

Exact field shapes:

```json
// Artikel — VaIt "2" (carries both free fields below only when the supplier maps to a crediteurcode; otherwise both omitted)
{ "Fields": {
    "VaIt": "2", "ItCd": "EP2-20095", "UnId": "St",
    "QuUn": "1", "Qu": "1", "QuSa": "1",
    "Upri": "1749.03", "AmCo": "1381.73",
    "UC61B5DF54390117579CF9AA289E985F0": true,
    "U69BD7B0B402F2007FEC9E485BB4B59C9": "50029"
}}

// Werksoort — VaIt "1" (AmCo is always "0"; always carries StId = "N")
{ "Fields": {
    "VaIt": "1", "ItCd": "<internalProductId>", "UnId": "",
    "QuUn": "2", "Qu": "2", "QuSa": "2",
    "Upri": "99.95", "AmCo": "0",
    "StId": "N"
}}

// Tekstregel / TXT — VaIt "3" (ItCd fixed to "SBO" — "SBA" for subscriptions; no quantities or amounts; the two crediteur free fields appear here too when the supplier is mapped)
{ "Fields": {
    "VaIt": "3", "ItCd": "SBO",
    "Ds": "Implementatie werkplek - aantal 2, prijs 99.95, kostprijs 60.00",
    "UnId": "", "QuUn": "", "Qu": "", "QuSa": "", "Upri": "", "AmCo": ""
}}
```

- **Line `Ds` (omschrijving):** artikel (`VaIt=2`) and werksoort (`VaIt=1`) lines send `Ds` = the SB quote line's `shortDescription` (non-blank, trimmed; capped at 255 chars; Regel field `Omschrijving`); when empty `Ds` is omitted so AFAS uses the item's default description. The `KnQuotation` header `Ds` (quote title, 100 chars) is unchanged.
- The TXT line's `Ds` is the composed info string `"{name} (= `shortDescription` when filled, else line `name`) - aantal {qty}, prijs {price}{per}, kostprijs {cost}{per}"` (`{per}` = `" per maand"` for `month`, `" per jaar"` for `year`, `" per {term}"` otherwise, empty for non-subscription TXT lines; e.g. `"Promax | Beheer | Firewall - aantal 1, prijs 85 per maand, kostprijs 40 per maand"`; price/cost on a subscription line are per period; subscription TXT lines also carry an extra `Termijn` field), capped at **255 chars** (not the 100-char cap used elsewhere for `Ds`/`FbItemArticle.Ds`).
- A werksoort line's `AmCo` is **always `"0"`**, regardless of the SB quote line's actual `cost` — Diensten lines never carry a real cost price into AFAS.
- Werksoort and TXT line examples above omit the crediteur free fields (`U69BD7B0B402F2007FEC9E485BB4B59C9` + `UC61B5DF54390117579CF9AA289E985F0 = true`); they appear on those lines too whenever the SB line's supplier is mapped in `mapping-leveranciers.xml`.
- A TXT line has no `UnId`, quantities, or amounts at all — all five are empty strings, not `"0"` or omitted.
- ⚠️ **Known caveat:** `Upri` uses the raw per-unit `price` and does **not** apply the item `discount` — unlike `CmForecast.OrAF` (see above), which does apply discount. Pending confirmation; not yet fixed in code.
- The OLD shape — `QuId`/`DbId`/`QuDa`/`Ds`/`CuId`/`FcNo` all inside `Fields`, with line fields `ItCd`/`Qu`/`UP` and no `UnId` — is obsolete.
- Function names: `ConvertTo-AfasQuotationBody` builds the payload (header + lines) shown above; it's shared by `Update-AfasQuotation` (the real `PUT`) and Flow 3's `$AfasWritesOnHold3` dry-run branch, which previews the **exact same payload** (via the same function, logged as full JSON in its WARNING) without writing. `Update-AfasQuotation` (was `New-AfasQuotation`) updates the existing quotation; the voorcalc number `$VoorcalcId` is the SB offerte number (Flow 3: `$WonQuotes[$OpportunityId].number`; Flow 4: `$Quote.number`; blank → WARNING, skip, watermark held; used for `@QuId`/on-hold payload log) — `Get-AfasVoorcalcId` was removed; `Get-AfasQuotation` (was `Get-AfasVoorcalculatie`) does the existence lookup (precondition, `offerte = {VoorcalcId}`) — used by Flow 4 only, no longer by Flow 3; `Get-AfasForecast` + `Get-AfasForecastStatusCode` do the idempotency check.

### Create a minimal Article (`FbItemArticle`, `POST`)

Created on demand when a quote line references an item code not yet present in AFAS — checked via a **targeted, per-`mpn` filtered lookup** against `Salesbuildr_Artikelen` (not a bulk catalog fetch — AFAS holds 30,000+ articles):

```
GET /connectors/Salesbuildr_Artikelen?filterfieldids=itemCode&filtervalues={mpn}&operatortypes=1&skip=0&take=1
```

```json
{ "FbItemArticle": { "Element": { "Fields": {
    "ItCd": "EP2-20095", "AuId": false,
    "Ds": "Microsoft Surface Pro 11 Copilot+ PC ...", "Grp": "70",
    "BiUn": "St", "VaRc": "2",
    "BiSt": false, "AdSr": false
}}}}
```

> **Promax item code + article group:**
> - `ItCd` = the Salesbuildr quote line's **`mpn`** (always — the `product` field is nullable). Lines without an `mpn` are skipped.
> - `AuId` = always `false` (item code is supplied explicitly, no AFAS auto-numbering).
> - `Ds` = the item `name`, capped at 100 characters (AFAS limit).
> - `Grp` (artikelgroep, **required**) is resolved via a **two-hop main-category lookup**: the quote line's leaf `category.id` is walked up to its main (root) category by `Get-SalesbuildrMainCategoryId`, using the parent map built at startup by `Get-SalesbuildrCategoryParentMap` (`GET /public-api/category`, flat list, keyed by `parentCategoryId`); that main-category id is then looked up in `configs/mapping-artikelgroepen.xml` (`<categorie SB-maincat-id="..." AFAS-id="..." AFAS-naam="..."/>`) → `Grp`. See [Salesbuildr_API_Guide.md](Salesbuildr_API_Guide.md#article-group-grp-via-configsmapping-artikelgroepenxml) for the full two-hop mechanism. `configs/config.xml`'s old `<artikelgroepmapping><costcenter>` block remains removed (superseded by `configs/mapping-artikelgroepen.xml`). A leaf category that cannot be resolved to a main category, a main category missing from the mapping file, or one mapped with an empty `AFAS-id`, causes Flow 2 to skip creating that article, with a WARNING (its watermark held for retry) — the article then stays missing in AFAS, so Flow 3 subsequently detects it via its own existence check and skips the whole opportunities that reference it. See `Get-AfasArtikelgroep` (now takes `-CategoryParentMap`) / `New-AfasArtikel` and Flow 2 (Items).
> - `BiUn` = `"St"` and `VaRc` = `"2"` — fixed placeholders for now.
> - `BiSt` (Voorraad bijhouden) and `AdSr` (Administratie serienummers) — both boolean, non-mandatory — are sent as follows: `BiSt` from the `Voorraad` attribute of the article's `<categorie>` row in `configs/mapping-artikelgroepen.xml` (loaded into `$ArtikelVlaggenMap` keyed by main-category id, passed as `New-AfasArtikel -Voorraad`; parsed with `ConvertTo-ConfigBool -Default $false`, so missing/empty/unrecognized = `false`); `AdSr` from the Salesbuildr product field `isSerialized` (via `Get-SalesbuildrProductIsSerialized`, full product fetch; no product or null = `false`), passed as `New-AfasArtikel -Serienummer`.
> - The OLD fields `Ds_1043`, `VaTp`, `CoLa`, `Bl` are no longer sent.

### Attach the SB quote PDF as a dossieritem (`KnSubject`, `POST`, Flow 4)

Triggered for a closed **Won** Opportunity (approved primary quote) once its AFAS quotation (`KnQuotation`) already exists — created by AFAS and filled by Flow 3 (`Get-AfasQuotation` filtering `Salesbuildr_Voorcalculatie.offerte = {VoorcalcId}`). If the quotation doesn't exist yet, Flow 4 holds its watermark and retries next run instead of attaching a PDF to nothing.

**Idempotency check first** — `Get-AfasQuotationAttachment` filters `Salesbuildr_Dossieritems` on `Offerte`:

```
GET /connectors/Salesbuildr_Dossieritems?filterfieldids=Offerte&filtervalues=2026-00380&operatortypes=1&skip=0&take=100
```

A returned row with `Type == StId` (the configured dossieritemtype, e.g. `46`) and `Ja_Nee == true` means the PDF is already attached — Flow 4 skips this opportunity. This check is required because, unlike Flow 1's and Flow 3's `PUT`s, the `KnSubject` `POST` below is **not** idempotent: re-running it would create a duplicate attachment.

**PDF fetch** — `Get-SalesbuildrQuotePdf -QuoteId` does `GET /public-api/quote/{id}/pdf` (see [Salesbuildr_API_Guide.md](Salesbuildr_API_Guide.md#quote)) via `Invoke-WebRequest` directly, **not** the JSON wrapper `Invoke-SalesbuildrRequest` (which would corrupt the binary via `ConvertFrom-Json`); reads `RawContentStream.ToArray()` and Base64-encodes it. HTTP 404 or an empty response returns `$null` (logged WARNING, watermark held).

**Create the dossieritem:**

```json
{ "KnSubject": { "Element": {
    "Fields": { "StId": 46, "Ds": "SB Offerte - 2026-00380", "Da": "2026-07-14T10:00", "UsId": "53307._sa_salesbldr" },
    "Objects": [
      { "KnSubjectLink": { "Element": { "Fields": {
          "ToSR": true, "SfTp": 4, "SfId": "10654", "QuId": "2026-00380"
      }}}},
      { "KnSubjectAttachment": { "Element": { "Fields": {
          "FileName": "SB-Offerte-2026-00380.pdf", "FileStream": "{base64_encoded_pdf}"
      }}}}
    ]
}}}
```

- `StId` = dossieritemtype, from `configs/config.xml`'s `<afas><kn_subject_stid>` (default `46`).
- `Ds` = `"SB Offerte - {VoorcalcId}"`. `New-AfasSubjectAttachment`'s parameter was renamed `-ForecastId` → `-OfferteNr`.
- `Da` = current datetime (`yyyy-MM-ddTHH:mm`), like `KnQuotation.QuDa`/`CmForecast.DaSc` a placeholder — revisit later for a real timestamp.
- `UsId` = AFAS user id, from `configs/config.xml`'s `<afas><kn_subject_usid>` (default `53307._sa_salesbldr`).
- `KnSubjectLink.SfTp` = `4` always; `SfId` = the verkooprelatie (AFAS `PrId`); `QuId` = the voorcalc number `{VoorcalcId}` (= SB offerte number; `Offerte`/`KnQuotation.QuId`). `PrId` and `ForecastId` are parsed from the Opportunity's `externalIdentifier` via `ConvertFrom-ForecastExternalId`; Flow 4 does no Forecast re-fetch (`$VoorcalcId = $Quote.number`; blank → WARNING, skip, watermark held).
- `KnSubjectAttachment.FileName` = `"SB-Offerte-{VoorcalcId}.pdf"`; `FileStream` = the Base64 PDF from `Get-SalesbuildrQuotePdf`.
- Function names: `Get-AfasQuotationAttachment` (idempotency check), `New-AfasSubjectAttachment` (creates the dossieritem).

---

## Further Reading

- AFAS API docs — Concepts: `https://docs.afas.help/profit/nl/concepts`
- AFAS API docs — GetConnector (filtering, skip/take, orderby, metainfo): `https://docs.afas.help/profit/nl/get-connector`
- AFAS API docs — UpdateConnector (POST/PUT/DELETE, @Action, sub-objects): `https://docs.afas.help/profit/nl/update-connector`
- AFAS Developer Portal: `https://help.afas.nl/help/NL/SE/App_Cnnctr_Add.htm`
- GetConnector functional docs: `https://help.afas.nl/help/NL/SE/App_Cnnctr_Get.htm`
- UpdateConnector functional docs: `https://help.afas.nl/help/NL/SE/App_Cnr_Rest_Update.htm`
