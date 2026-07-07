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
filterfieldids=offerte&filtervalues=11310&operatortypes=1
```

`11310` is the AFAS `forecast` id (see externalIdentifier format below) — **not** `SB-{SqNo}` as in an earlier version.

If a matching `Salesbuildr_Voorcalculatie` record is found (`$QuotationExists = $true`), the script skips only the **creation** call (`New-AfasQuotation`) — it does **not** skip the whole opportunity. The Forecast-close call below still runs for a pre-existing quotation, since it's an idempotent `PUT`; this way a prior run that created the AFAS quotation but failed before closing the Forecast still completes the close on the next run.

### Opportunity `externalIdentifier` format

Flow 1 sets the Salesbuildr Opportunity's `externalIdentifier` to `afas-Forecast-{forecast}-{volgnummer}-{verkooprelatie}` (e.g. `afas-Forecast-11310-42-10654`), encoding three distinct `Salesbuildr_Forecasts` fields so Flow 2 can parse the CmForecast key directly with **no re-fetch** of the Forecast:

| Field | Example | Role |
|---|---|---|
| `forecast` | `11310` | Globally-unique AFAS forecast id — used as the AFAS quotation's `KnQuotation.QuId` (idempotency key). **Not** the CmForecast key. |
| `volgnummer` | `42` | CmForecast `SqNo` (composite key part) |
| `verkooprelatie` | `"10654"` | CmForecast `PrId` (composite key part; AFAS debtor code); also used as the AFAS quotation's `KnQuotation.DbId` |

Flow 2 parses all three back out via regex `^afas-Forecast-(?<fc>\d+)-(?<sqno>\d+)-(?<pr>.+)$`.

### Close a Forecast as won or lost (`CmForecast`, `PUT`)

Triggered when a closed Salesbuildr Opportunity is categorized Won or Lost (strictly by its **primary quote** — see [Salesbuildr_API_Guide.md](Salesbuildr_API_Guide.md#promax-implementation-notes-sync-forecastsps1)). The composite primary key `PrId` (verkooprelatie) + `SqNo` (volgnummer) is passed as `@`-prefixed **Element-level** attributes, not inside `Fields`:

```json
{ "CmForecast": { "Element": {
    "@PrId": "10654",
    "@SqNo": 42,
    "Fields": { "ViOp": "G", "ViRe": "00", "DaSc": "2026-07-05", "OrAF": 6284.21 }
}}}
```

Won (`ViOp: "G"`) example above; Lost is identical except `"ViOp": "N"` and **no** `OrAF` field at all.

- `@PrId` / `@SqNo` are parsed straight from the Opportunity's `externalIdentifier` (see format above) — Flow 2 no longer re-fetches the Forecast from AFAS.
- For Won opportunities, this close call is wrapped in its own `try`/`catch` (separate from the `KnQuotation` creation above): if it fails, the flag is cleared and the opportunity is skipped, but the AFAS quotation created earlier in the same run is **not** rolled back — the next run's idempotency check (see above) picks it up and just retries the close.
- `ViRe` is always `"00"`.
- `DaSc` is currently the current date (placeholder — revisit later for a real close date).
- `OrAF` (total quote amount) is included **only** for Won; it's computed client-side from the primary quote's items since `QuoteResponseDto` has no ready-made total: `Σ (price × quantity × (1 - discount))` (`discount` is a decimal fraction; near-zero values like `-1e-6` are rounding noise; `setupPrice` and quote-level discount are ignored).

### Create an AFAS quotation with lines (`KnQuotation`, `POST`)

Creates the **AFAS quotation** (`KnQuotation`, voorcalculatie — distinct from the Salesbuildr "SB quotation" it originates from), via `New-AfasQuotation`. All SB quote lines for one opportunity go into a **single** payload: `KnQuotationLine.Element` is an array of `{ "Fields": {...} }` objects inside one `Objects` entry, one array item per SB quote line:

```json
{ "KnQuotation": { "Element": {
    "@QuId": "11310",
    "Fields": { "QuDa": "2026-07-06", "DbId": "10654", "FcNo": 42, "Ds": "Moderne werkplek Noviflora (fase 1)" },
    "Objects": [ { "KnQuotationLine": { "Element": [
        {
          "Fields": {
            "VaIt": "2", "ItCd": "EP2-20095", "UnId": "St",
            "QuUn": "1", "Qu": "1", "QuSa": "1",
            "Upri": "1749.03", "AmCo": "1381.73"
          }
        },
        {
          "Fields": {
            "VaIt": "2", "ItCd": "EP2-20096", "UnId": "St",
            "QuUn": "2", "Qu": "2", "QuSa": "2",
            "Upri": "99.95", "AmCo": "60.00"
          }
        }
    ] } } ]
}}}
```

- `@QuId` = the AFAS `forecast` id (e.g. `"11310"`) — an **Element-level `@`-attribute**, like `CmForecast`'s `@PrId`/`@SqNo`, **not** a `Fields` entry; doubles as the idempotency key (checked via the `Salesbuildr_Voorcalculatie` GetConnector, see filter above; `Get-AfasQuotation`). Only created for Won opportunities, and only when it doesn't already exist — see the idempotency note above; the Forecast-close call runs regardless of whether creation happened this run or a prior one.
- `DbId` (verkooprelatie) and `FcNo` (volgnummer/`SqNo`) are parsed straight from the Opportunity's `externalIdentifier` — no re-fetch of the Forecast.
- `Ds` (omschrijving) = the SB quote's `title` (`QuoteResponseDto.title`), capped at 100 chars (AFAS limit).
- `QuDa` is currently the current date (placeholder — revisit later for a real quote date).
- `Objects` holds one `KnQuotationLine` with one `Element` array containing one entry per quote line (see example above with two lines).
- Line fields: `VaIt` = `"2"` product / `"1"` service — product/service grouping isn't implemented yet, so this is currently hardcoded `"2"` for every line. `ItCd` = the line's `mpn`. `UnId` = unit, always `"St"` (stuks/pieces) — set on every line. `QuUn`/`Qu`/`QuSa` are all set to the line `quantity`. `Upri` = per-unit sell price (`price`), `AmCo` = per-unit cost (`cost`). All amounts are serialized as invariant-culture strings with a **dot** decimal separator (e.g. `"1749.03"`, never `"1749,03"`).
- ⚠️ **Known caveat:** `Upri` uses the raw per-unit `price` and does **not** apply the item `discount` — unlike `CmForecast.OrAF` (see above), which does apply discount. Pending confirmation; not yet fixed in code.
- The OLD shape — `QuId`/`DbId`/`QuDa`/`Ds`/`CuId`/`FcNo` all inside `Fields`, with line fields `ItCd`/`Qu`/`UP` and no `UnId` — is obsolete.
- Function names: `New-AfasQuotation` (was `New-AfasVoorcalculatie`) creates the quotation; `Get-AfasQuotation` (was `Get-AfasVoorcalculatie`) does the idempotency lookup.

### Create a minimal Article (`FbItemArticle`, `POST`)

Created on demand when a quote line references an item code not yet present in AFAS — checked via a **targeted, per-`mpn` filtered lookup** against `Salesbuildr_Artikelen` (not a bulk catalog fetch — AFAS holds 30,000+ articles):

```
GET /connectors/Salesbuildr_Artikelen?filterfieldids=itemCode&filtervalues={mpn}&operatortypes=1&skip=0&take=1
```

```json
{ "FbItemArticle": { "Element": { "Fields": {
    "ItCd": "EP2-20095", "AuId": false,
    "Ds": "Microsoft Surface Pro 11 Copilot+ PC ...", "Grp": "70",
    "BiUn": "St", "VaRc": "2"
}}}}
```

> **Promax item code + article group:**
> - `ItCd` = the Salesbuildr quote line's **`mpn`** (always — the `product` field is nullable). Lines without an `mpn` are skipped.
> - `AuId` = always `false` (item code is supplied explicitly, no AFAS auto-numbering).
> - `Ds` = the item `name`, capped at 100 characters (AFAS limit).
> - `Grp` (artikelgroep, **required**) is now a **direct one-hop** lookup: quote line `category.id` → `configs/mapping-artikelgroepen.xml` (`<categorie SB-id="..." AFAS-id="..." AFAS-naam="..."/>`) → `Grp`. The old two-hop route — `GET /public-api/category` → `costCenterId` → `configs/config.xml`'s `<artikelgroepmapping><costcenter>` — is obsolete; that config block has been removed entirely. A category missing from the mapping file, or mapped with an empty `AFAS-id`, causes the article — and its whole opportunity — to be skipped with a WARNING (watermark held for retry). See `Get-AfasArtikelgroep` / `New-AfasArtikel` and Flow 2 step 2b.
> - `BiUn` = `"St"` and `VaRc` = `"2"` — fixed placeholders for now.
> - The OLD fields `Ds_1043`, `VaTp`, `BiSt`, `CoLa`, `Bl` are no longer sent.

---

## Further Reading

- AFAS API docs — Concepts: `https://docs.afas.help/profit/nl/concepts`
- AFAS API docs — GetConnector (filtering, skip/take, orderby, metainfo): `https://docs.afas.help/profit/nl/get-connector`
- AFAS API docs — UpdateConnector (POST/PUT/DELETE, @Action, sub-objects): `https://docs.afas.help/profit/nl/update-connector`
- AFAS Developer Portal: `https://help.afas.nl/help/NL/SE/App_Cnnctr_Add.htm`
- GetConnector functional docs: `https://help.afas.nl/help/NL/SE/App_Cnnctr_Get.htm`
- UpdateConnector functional docs: `https://help.afas.nl/help/NL/SE/App_Cnr_Rest_Update.htm`
