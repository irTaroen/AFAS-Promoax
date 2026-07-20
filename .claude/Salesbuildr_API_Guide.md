# Salesbuildr Public API — Usage Guide

> **Schema reference:** All request/response schemas described in this guide are defined in [`openapi.json`](../docs/api/openapi.json). JSON pointer format: `openapi.json#/components/schemas/<SchemaName>`.

---

## Overview

The Salesbuildr Public API provides programmatic access to manage your CRM and quoting data. It follows REST conventions with JSON request/response bodies.

> The Public API is a feature that must be enabled for your account. Contact Salesbuildr support if you do not have access.

---

## Base URL

```
https://[your-tenant-name].salesbuildr.com/public-api/
```

---

## Authentication

Every request requires an API key header.

### Generating an API Key

**Admin > Integrations > API Key**

### Request Header

```http
api-key: YOUR_API_KEY_HERE
```

The OpenAPI security scheme is defined at [`openapi.json#/components/securitySchemes/ApiKey`](../docs/api/openapi.json#/components/securitySchemes/ApiKey).

---

## API Reference & Interactive Docs

| Resource | URL |
|---|---|
| API Reference (Redocly) | `https://portal.salesbuildr.com/public-api#/` |
| Swagger (Interactive) | `https://[your-tenant].salesbuildr.com/public-api/swagger` |
| Webhooks Info | `https://[your-tenant].salesbuildr.com/public-api/webhooks` |

---

## Querying & Pagination

Most list endpoints (`GET /public-api/{resource}`) share common query parameters:

| Parameter | Type | Description | Example |
|---|---|---|---|
| `query` | string | Full-text search | `Acme Corp` |
| `filters` | string | Filter by field values | `type:customer,labels:important` |
| `sort` | string | Sort criteria (`-` = desc, `+` = asc) | `-updatedDate,+name` |
| `size` | number | Results per page | `10` |
| `from` | number | Pagination offset | `0` |

List responses return:

```json
{
  "results": [...],
  "total": 42,
  "filters": [...],
  "sortOptions": [...]
}
```

---

## Rate Limiting

**500 requests per 10-minute rolling window** per tenant.

| Response Header | Description |
|---|---|
| `X-RateLimit-Limit` | Maximum requests in window |
| `X-RateLimit-Remaining` | Requests remaining |
| `X-RateLimit-Reset` | Unix timestamp of window reset |

When the limit is reached the API returns `429` with a `Retry-After` header (seconds to wait).

> The `Sync State` endpoint is **exempt** from rate limiting.

---

## Fair Use Policy

**Permitted:** data synchronization, workflow automation, dashboard building.  
**Prohibited:** high-volume bulk requests, continuous polling, data scraping, circumventing limits.

Violations may result in access restrictions or account suspension.

---

## Endpoint Reference

### Company

Schema definitions: [`CreateCompanyDto`](../docs/api/openapi.json#/components/schemas/CreateCompanyDto) · [`UpdateCompanyDto`](../docs/api/openapi.json#/components/schemas/UpdateCompanyDto) · [`CompanyResponseDto`](../docs/api/openapi.json#/components/schemas/CompanyResponseDto)

| Method | Path | Summary | Request Body | Response |
|---|---|---|---|---|
| `GET` | `/public-api/company` | Search | — | [`CompanyResponseDto`](../docs/api/openapi.json#/components/schemas/CompanyResponseDto) |
| `POST` | `/public-api/company` | Create | [`CreateCompanyDto`](../docs/api/openapi.json#/components/schemas/CreateCompanyDto) | `201` CompanyResponseDto |
| `GET` | `/public-api/company/{id}` | Get | — | [`CompanyResponseDto`](../docs/api/openapi.json#/components/schemas/CompanyResponseDto) |
| `PUT` | `/public-api/company/{id}` | Update | [`UpdateCompanyDto`](../docs/api/openapi.json#/components/schemas/UpdateCompanyDto) | [`CompanyResponseDto`](../docs/api/openapi.json#/components/schemas/CompanyResponseDto) |
| `DELETE` | `/public-api/company/{id}` | Delete | — | `204` |
| `GET` | `/public-api/company/ext/{externalIdentifier}` | Get by ext ID | — | [`CompanyResponseDto`](../docs/api/openapi.json#/components/schemas/CompanyResponseDto) |
| `PUT` | `/public-api/company/ext/{externalIdentifier}` | Upsert by ext ID | [`UpdateCompanyDto`](../docs/api/openapi.json#/components/schemas/UpdateCompanyDto) | `200/201` CompanyResponseDto |
| `DELETE` | `/public-api/company/ext/{externalIdentifier}` | Delete by ext ID | — | `200` |

**Required fields for create/update:** `name`, `number`, `type`

**Notable optional fields:** `address` ([`AddressDto`](../docs/api/openapi.json#/components/schemas/AddressDto)), `deliveryAddresses`, `quotePaymentTermId`, `parentCompanyId`, `accountManagerId`, `currency`, `labels`, `customFields`

---

### Contact

Schema definitions: [`CreateContactDto`](../docs/api/openapi.json#/components/schemas/CreateContactDto) · [`UpdateContactDto`](../docs/api/openapi.json#/components/schemas/UpdateContactDto) · [`UpsertContactDto`](../docs/api/openapi.json#/components/schemas/UpsertContactDto) · [`ContactResponseDto`](../docs/api/openapi.json#/components/schemas/ContactResponseDto)

| Method | Path | Summary | Request Body | Response |
|---|---|---|---|---|
| `GET` | `/public-api/contact` | Search contacts | — | `ContactResponseDto[]` |
| `POST` | `/public-api/contact` | Create | [`CreateContactDto`](../docs/api/openapi.json#/components/schemas/CreateContactDto) | `201` |
| `GET` | `/public-api/contact/{id}` | Get | — | [`ContactResponseDto`](../docs/api/openapi.json#/components/schemas/ContactResponseDto) |
| `PUT` | `/public-api/contact/{id}` | Update | [`UpdateContactDto`](../docs/api/openapi.json#/components/schemas/UpdateContactDto) | `200` |
| `DELETE` | `/public-api/contact/{id}` | Delete by ID | — | `200` |
| `PUT` | `/public-api/contact/{id}/undelete` | Undelete by ID | — | `200` |
| `PUT` | `/public-api/contact/by-email` | Upsert by email | [`CreateContactDto`](../docs/api/openapi.json#/components/schemas/CreateContactDto) | `200` |
| `GET` | `/public-api/contact/ext/{externalIdentifier}` | Get by ext ID | — | `200` |
| `PUT` | `/public-api/contact/ext/{externalIdentifier}` | Upsert by ext ID | [`UpsertContactDto`](../docs/api/openapi.json#/components/schemas/UpsertContactDto) | `200` |
| `DELETE` | `/public-api/contact/ext/{externalIdentifier}` | Delete by ext ID | — | `200` |
| `PUT` | `/public-api/contact/ext/{externalIdentifier}/undelete` | Undelete by ext ID | — | `200` |

**Required fields for create:** `firstName`, `middleName`, `lastName`, `phone`, `mobilePhone`, `email`, `companyId`, `companyExtId`, `isActive`, `externalIdentifier`

> **Tip:** Pass `"primary"` as the `companyId` value to link the contact to the primary company.

---

### Opportunity

Schema definitions: [`CreateOpportunityPublicDto`](../docs/api/openapi.json#/components/schemas/CreateOpportunityPublicDto) · [`UpdateOpportunityPublicDto`](../docs/api/openapi.json#/components/schemas/UpdateOpportunityPublicDto) · [`UpsertOpportunityDto`](../docs/api/openapi.json#/components/schemas/UpsertOpportunityDto) · [`OpportunityResponseDto`](../docs/api/openapi.json#/components/schemas/OpportunityResponseDto)

| Method | Path | Summary | Request Body | Response |
|---|---|---|---|---|
| `GET` | `/public-api/opportunity` | Search | — | `{ results: OpportunityResponseDto[], total, filters, sortOptions }` |
| `POST` | `/public-api/opportunity` | Create | [`CreateOpportunityPublicDto`](../docs/api/openapi.json#/components/schemas/CreateOpportunityPublicDto) | `201` OpportunityResponseDto |
| `GET` | `/public-api/opportunity/{id}` | Get by ID | — | [`OpportunityResponseDto`](../docs/api/openapi.json#/components/schemas/OpportunityResponseDto) |
| `PUT` | `/public-api/opportunity/{id}` | Update | [`UpdateOpportunityPublicDto`](../docs/api/openapi.json#/components/schemas/UpdateOpportunityPublicDto) | [`OpportunityResponseDto`](../docs/api/openapi.json#/components/schemas/OpportunityResponseDto) |
| `GET` | `/public-api/opportunity/ext/{externalIdentifier}` | Get by ext ID | — | [`OpportunityResponseDto`](../docs/api/openapi.json#/components/schemas/OpportunityResponseDto) |
| `PUT` | `/public-api/opportunity/ext/{externalIdentifier}` | Upsert by ext ID | [`UpsertOpportunityDto`](../docs/api/openapi.json#/components/schemas/UpsertOpportunityDto) | `200/201` OpportunityResponseDto |
| `POST` | `/public-api/opportunity/ext/{externalIdentifier}/lose` | Mark as lost | — | `201` |
| `POST` | `/public-api/opportunity/ext/{externalIdentifier}/win` | Mark as won | — | `201` |

**Required fields for create:** `name`

**Key optional fields:** `companyId` / `companyExtId`, `contactId` / `contactExtId`, `ownerId` / `ownerExtId`, `pipelineStageId` / `pipelineStageExtId`, `categoryId` / `categoryExtId`, `sourceId` / `sourceExtId`, `expectedCloseDate` (ISO `YYYY-MM-DD`), `probability` (0–1), `onetimeRevenue`, `monthlyRevenue`, `monthlyChurn`, `valueMonths`, `customFields`

---

### Product

Schema definitions: [`CreateProductPublicDto`](../docs/api/openapi.json#/components/schemas/CreateProductPublicDto) · [`UpsertProductDto`](../docs/api/openapi.json#/components/schemas/UpsertProductDto) · [`ProductResponseDto`](../docs/api/openapi.json#/components/schemas/ProductResponseDto) · [`BulkUpsertProductsDto`](../docs/api/openapi.json#/components/schemas/BulkUpsertProductsDto) · [`PutProductInventoriesDto`](../docs/api/openapi.json#/components/schemas/PutProductInventoriesDto)

| Method | Path | Summary | Request Body | Response |
|---|---|---|---|---|
| `GET` | `/public-api/product` | Search | — | `{ results: ProductResponseDto[], total, filters, sortOptions }` |
| `POST` | `/public-api/product` | Create product | [`CreateProductPublicDto`](../docs/api/openapi.json#/components/schemas/CreateProductPublicDto) | [`ProductResponseDto`](../docs/api/openapi.json#/components/schemas/ProductResponseDto) |
| `POST` | `/public-api/product/batch` | Create products in batch (max 100) | [`BulkUpsertProductsDto`](../docs/api/openapi.json#/components/schemas/BulkUpsertProductsDto) | [`BatchProductsResponseDto`](../docs/api/openapi.json#/components/schemas/BatchProductsResponseDto) |
| `GET` | `/public-api/product/{id}` | Get product by ID | — | [`ProductResponseDto`](../docs/api/openapi.json#/components/schemas/ProductResponseDto) |
| `PUT` | `/public-api/product/{id}` | Update product | [`UpsertProductDto`](../docs/api/openapi.json#/components/schemas/UpsertProductDto) | [`ProductResponseDto`](../docs/api/openapi.json#/components/schemas/ProductResponseDto) |
| `DELETE` | `/public-api/product/{id}` | Delete product | — | `200` / `409` if used in quote |
| `PUT` | `/public-api/product/{id}/inventory` | Replace inventories | [`PutProductInventoriesDto`](../docs/api/openapi.json#/components/schemas/PutProductInventoriesDto) | `200` |
| `GET` | `/public-api/product/ext/{externalIdentifier}` | Get by ext ID | — | [`ProductResponseDto`](../docs/api/openapi.json#/components/schemas/ProductResponseDto) |
| `PUT` | `/public-api/product/ext/{externalIdentifier}` | Upsert by ext ID | [`UpsertProductDto`](../docs/api/openapi.json#/components/schemas/UpsertProductDto) | `200/201` ProductResponseDto |
| `DELETE` | `/public-api/product/ext/{externalIdentifier}` | Delete by ext ID | — | `200` / `409` if used in quote |

**Required fields for create:** `name`, `categoryId`

**Optional fields:** `productType`, `shortDescription`, `description`, `mpn`, `cost`, `price`, `markup`, `margin`, `msrp`, `unit`, `term`, `vendor`, `externalIdentifier`, `logo`, `internalProductId`, `listed`, `isSerialized`, `customFields`

> Add `?enrich=true` to create/update calls to trigger product data enrichment.

---

### Quote

Schema definitions: [`CreateQuoteDto`](../docs/api/openapi.json#/components/schemas/CreateQuoteDto) · [`QuoteResponseDto`](../docs/api/openapi.json#/components/schemas/QuoteResponseDto)

| Method | Path | Summary | Request Body | Response |
|---|---|---|---|---|
| `GET` | `/public-api/quote` | Search | — | `{ results: QuoteResponseDto[], total, filters, sortOptions }` |
| `POST` | `/public-api/quote` | Create draft quote | [`CreateQuoteDto`](../docs/api/openapi.json#/components/schemas/CreateQuoteDto) | `201` [`QuoteResponseDto`](../docs/api/openapi.json#/components/schemas/QuoteResponseDto) |
| `POST` | `/public-api/quote/approved` | Create approved quote | [`CreateQuoteDto`](../docs/api/openapi.json#/components/schemas/CreateQuoteDto) | `201` QuoteResponseDto |
| `GET` | `/public-api/quote/{id}` | Get quote | — | [`QuoteResponseDto`](../docs/api/openapi.json#/components/schemas/QuoteResponseDto) |
| `GET` | `/public-api/quote/{id}/pdf` | Download quote PDF | — | PDF file |
| `GET` | `/public-api/quote/{id}/attachment/{title}` | Download attachment | — | Attachment file |

> `GET /public-api/quote/approved` is **deprecated** — use `GET /public-api/quote?filters=statusId:approved` instead.

**Required fields for create:** `opportunityId`, `title`

**Optional fields:** `templateId`, `products` (array of `{ id, quantity }` — see [`CreateQuoteProductDto`](../docs/api/openapi.json#/components/schemas/CreateQuoteProductDto))

**Quote response includes:** `status`, `items` ([`QuoteItemResponseDto`](../docs/api/openapi.json#/components/schemas/QuoteItemResponseDto)), `approvers`, `deliveryAddress`, `paymentTerm`, `shippingType`, `discount` ([`QuoteDiscountResponseDto`](../docs/api/openapi.json#/components/schemas/QuoteDiscountResponseDto)), `attachments`, `formFields`, `opportunity`, `contact`, `company`, `owner`, `link`

---

### Quote Template

Schema definitions: [`CreateQuoteTemplatePublicDto`](../docs/api/openapi.json#/components/schemas/CreateQuoteTemplatePublicDto) · [`UpdateQuoteTemplatePublicDto`](../docs/api/openapi.json#/components/schemas/UpdateQuoteTemplatePublicDto) · [`QuoteTemplateResponseDto`](../docs/api/openapi.json#/components/schemas/QuoteTemplateResponseDto)

| Method | Path | Summary | Request Body | Response |
|---|---|---|---|---|
| `GET` | `/public-api/quote-template` | Get all templates | — | `QuoteTemplateResponseDto[]` |
| `POST` | `/public-api/quote-template` | Create template | [`CreateQuoteTemplatePublicDto`](../docs/api/openapi.json#/components/schemas/CreateQuoteTemplatePublicDto) | `201` QuoteTemplateResponseDto |
| `GET` | `/public-api/quote-template/{id}` | Get single template | — | [`QuoteTemplateResponseDto`](../docs/api/openapi.json#/components/schemas/QuoteTemplateResponseDto) |
| `PUT` | `/public-api/quote-template/{id}` | Update template | [`UpdateQuoteTemplatePublicDto`](../docs/api/openapi.json#/components/schemas/UpdateQuoteTemplatePublicDto) | QuoteTemplateResponseDto |
| `POST` | `/public-api/quote-template/validate` | Validate template data | [`CreateQuoteTemplatePublicDto`](../docs/api/openapi.json#/components/schemas/CreateQuoteTemplatePublicDto) | `200` validated data |

**Required fields for create:** `name`

**Widget types:** `items`, `content`, `single-media`, `image`, `form`, `html-content`, `summary`, `total`, `leasing-summary`

> The GET response can be used directly in PUT requests. All product references use internal Salesbuildr product IDs.

---

### Quote Widget Template

Schema definitions: [`CreateQuoteWidgetTemplatePublicDto`](../docs/api/openapi.json#/components/schemas/CreateQuoteWidgetTemplatePublicDto) · [`UpdateQuoteWidgetTemplatePublicDto`](../docs/api/openapi.json#/components/schemas/UpdateQuoteWidgetTemplatePublicDto) · [`QuoteWidgetTemplateResponseDto`](../docs/api/openapi.json#/components/schemas/QuoteWidgetTemplateResponseDto)

| Method | Path | Summary | Request Body | Response |
|---|---|---|---|---|
| `GET` | `/public-api/quote-widget-template` | Get all widget templates | — | `QuoteWidgetTemplateResponseDto[]` |
| `POST` | `/public-api/quote-widget-template` | Create widget template | [`CreateQuoteWidgetTemplatePublicDto`](../docs/api/openapi.json#/components/schemas/CreateQuoteWidgetTemplatePublicDto) | `201` QuoteWidgetTemplateResponseDto |
| `GET` | `/public-api/quote-widget-template/{id}` | Get single widget template | — | [`QuoteWidgetTemplateResponseDto`](../docs/api/openapi.json#/components/schemas/QuoteWidgetTemplateResponseDto) |
| `PUT` | `/public-api/quote-widget-template/{id}` | Update widget template | [`UpdateQuoteWidgetTemplatePublicDto`](../docs/api/openapi.json#/components/schemas/UpdateQuoteWidgetTemplatePublicDto) | QuoteWidgetTemplateResponseDto |
| `DELETE` | `/public-api/quote-widget-template/{id}` | Delete widget template | — | `204` / `409` if linked to quote templates |
| `POST` | `/public-api/quote-widget-template/validate` | Validate widget data | [`CreateQuoteWidgetTemplatePublicDto`](../docs/api/openapi.json#/components/schemas/CreateQuoteWidgetTemplatePublicDto) | `200` validated data |

> Add `?force=true` to DELETE to remove even if linked to quote templates.

---

### Pricing Book

Schema definitions: [`UpdatePricingBookPublicDto`](../docs/api/openapi.json#/components/schemas/UpdatePricingBookPublicDto) · [`PricingBookResponseDto`](../docs/api/openapi.json#/components/schemas/PricingBookResponseDto) · [`PricingBookProductPublicDto`](../docs/api/openapi.json#/components/schemas/PricingBookProductPublicDto)

| Method | Path | Summary | Request Body | Response |
|---|---|---|---|---|
| `GET` | `/public-api/pricing-book` | Get all pricing books | — | `PricingBookResponseDto[]` |
| `POST` | `/public-api/pricing-book` | Create pricing book | [`UpdatePricingBookPublicDto`](../docs/api/openapi.json#/components/schemas/UpdatePricingBookPublicDto) | `201` PricingBookResponseDto |
| `GET` | `/public-api/pricing-book/{id}` | Get pricing book by ID | — | [`PricingBookResponseDto`](../docs/api/openapi.json#/components/schemas/PricingBookResponseDto) |
| `PUT` | `/public-api/pricing-book/{id}` | Update pricing book | [`UpdatePricingBookPublicDto`](../docs/api/openapi.json#/components/schemas/UpdatePricingBookPublicDto) | PricingBookResponseDto |

**Required fields:** `name`, `description`, `specialBidNumber`, `companyIds[]`, `classificationIds[]`, `products[]`

Each product entry ([`PricingBookProductPublicDto`](../docs/api/openapi.json#/components/schemas/PricingBookProductPublicDto)): `productId`, `price`, `cost`, `validFrom`, `validTo`, `note`

---

### Category

Schema definitions: [`CategoryResponseDto`](../docs/api/openapi.json#/components/schemas/CategoryResponseDto) · [`RootCategoryResponseDto`](../docs/api/openapi.json#/components/schemas/RootCategoryResponseDto)

| Method | Path | Summary | Response |
|---|---|---|---|
| `GET` | `/public-api/category` | Get all categories (flat list) | [`CategoryResponseDto[]`](../docs/api/openapi.json#/components/schemas/CategoryResponseDto) |
| `GET` | `/public-api/category/tree` | Get all categories as tree | [`RootCategoryResponseDto[]`](../docs/api/openapi.json#/components/schemas/RootCategoryResponseDto) |

Add `?includeEmpty=true` to the tree endpoint to include categories with no products.

---

### Field

Schema definitions: [`UpdatePublicFieldDto`](../docs/api/openapi.json#/components/schemas/UpdatePublicFieldDto) · [`FieldValuesResponseDto`](../docs/api/openapi.json#/components/schemas/FieldValuesResponseDto)

| Method | Path | Summary | Request Body | Response |
|---|---|---|---|---|
| `GET` | `/public-api/field/{field}` | Get field and its values | — | [`FieldValuesResponseDto`](../docs/api/openapi.json#/components/schemas/FieldValuesResponseDto) |
| `PUT` | `/public-api/field/{field}` | Replace field values | [`UpdatePublicFieldDto`](../docs/api/openapi.json#/components/schemas/UpdatePublicFieldDto) | `200` |

Each field value ([`UpdatePublicFieldValueDto`](../docs/api/openapi.json#/components/schemas/UpdatePublicFieldValueDto)): `externalIdentifier`, `displayValue`, `isDefault`

---

### Quote Discount Group

Schema definitions: [`UpdateDiscountGroupDto`](../docs/api/openapi.json#/components/schemas/UpdateDiscountGroupDto) · [`DiscountGroupResponseDto`](../docs/api/openapi.json#/components/schemas/DiscountGroupResponseDto) · [`UpdateCompaniesDiscountGroupDto`](../docs/api/openapi.json#/components/schemas/UpdateCompaniesDiscountGroupDto)

| Method | Path | Summary | Request Body | Response |
|---|---|---|---|---|
| `GET` | `/public-api/quote-discount-group` | Get all discount groups | — | array |
| `POST` | `/public-api/quote-discount-group` | Create new | [`UpdateDiscountGroupDto`](../docs/api/openapi.json#/components/schemas/UpdateDiscountGroupDto) | `201` DiscountGroupResponseDto |
| `GET` | `/public-api/quote-discount-group/{id}` | Get by ID | — | [`DiscountGroupResponseDto`](../docs/api/openapi.json#/components/schemas/DiscountGroupResponseDto) |
| `PUT` | `/public-api/quote-discount-group/{id}` | Update by ID | [`UpdateDiscountGroupDto`](../docs/api/openapi.json#/components/schemas/UpdateDiscountGroupDto) | DiscountGroupResponseDto |
| `PUT` | `/public-api/quote-discount-group/{id}/companies` | Set companies for group | [`UpdateCompaniesDiscountGroupDto`](../docs/api/openapi.json#/components/schemas/UpdateCompaniesDiscountGroupDto) | `{ message: string }` |

---

### Sync State

Schema definition: [`SyncStateDto`](../docs/api/openapi.json#/components/schemas/SyncStateDto)

> This endpoint is **exempt from rate limiting**.

| Method | Path | Summary | Request Body | Response |
|---|---|---|---|---|
| `PUT` | `/public-api/sync-state/{entityType}/{id}` | Report sync status | [`SyncStateDto`](../docs/api/openapi.json#/components/schemas/SyncStateDto) | `200` |

**`entityType`** must be `"quote"` or `"product"`.

**Request body:**

```json
{
  "state": "ok",
  "error": "",
  "externalIdentifier": "EXT-123"
}
```

`state` is `"ok"` or `"error"`. If `state` is `"error"`, populate the `error` field with a message.

---

### Contract *(Beta)*

| Method | Path | Summary | Response |
|---|---|---|---|
| `GET` | `/public-api/contract/items` | Get contract items | `200` list of contract items |

> ⚠️ Beta API — may change without notice. Use with caution in production.

Add `?query=<search>` to filter results.

---

## Example Requests

### Create a company

```http
POST /public-api/company HTTP/1.1
Host: your-tenant.salesbuildr.com
api-key: YOUR_API_KEY_HERE
Content-Type: application/json

{
  "name": "Acme Corp",
  "number": "KVK-12345678",
  "type": "customer",
  "telephone": "+31201234567",
  "address": {
    "street": "Hoofdstraat 1",
    "apartment": "",
    "city": "Amsterdam",
    "zip": "1011AB",
    "state": "NH",
    "country": "NL",
    "companyName": "Acme Corp",
    "contactName": "Jane Doe"
  },
  "externalIdentifier": "CRM-001"
}
```

→ Schema: [`CreateCompanyDto`](../docs/api/openapi.json#/components/schemas/CreateCompanyDto)

---

### Create a contact

```http
POST /public-api/contact HTTP/1.1
Host: your-tenant.salesbuildr.com
api-key: YOUR_API_KEY_HERE
Content-Type: application/json

{
  "firstName": "Jane",
  "middleName": "",
  "lastName": "Doe",
  "email": "jane.doe@acme.com",
  "phone": "+31201234567",
  "mobilePhone": "+31612345678",
  "companyId": "primary",
  "companyExtId": "CRM-001",
  "isActive": true,
  "externalIdentifier": "CRM-CONTACT-001"
}
```

→ Schema: [`CreateContactDto`](../docs/api/openapi.json#/components/schemas/CreateContactDto)

---

### Create an opportunity

```http
POST /public-api/opportunity HTTP/1.1
Host: your-tenant.salesbuildr.com
api-key: YOUR_API_KEY_HERE
Content-Type: application/json

{
  "name": "Annual License Renewal",
  "companyExtId": "CRM-001",
  "expectedCloseDate": "2026-09-30",
  "probability": 0.75,
  "onetimeRevenue": 5000,
  "monthlyRevenue": 250,
  "externalIdentifier": "CRM-OPP-001"
}
```

→ Schema: [`CreateOpportunityPublicDto`](../docs/api/openapi.json#/components/schemas/CreateOpportunityPublicDto)

---

### Upsert a product by external ID

```http
PUT /public-api/product/ext/PROD-M365-E3 HTTP/1.1
Host: your-tenant.salesbuildr.com
api-key: YOUR_API_KEY_HERE
Content-Type: application/json

{
  "name": "Microsoft 365 E3",
  "categoryId": "cat-software-123",
  "cost": 28.50,
  "price": 35.00,
  "unit": "user/month",
  "vendor": "Microsoft"
}
```

→ Schema: [`UpsertProductDto`](../docs/api/openapi.json#/components/schemas/UpsertProductDto)

---

### Create a draft quote

```http
POST /public-api/quote HTTP/1.1
Host: your-tenant.salesbuildr.com
api-key: YOUR_API_KEY_HERE
Content-Type: application/json

{
  "opportunityId": "opp-abc123",
  "title": "Proposal for Acme Corp",
  "templateId": "tmpl-001",
  "products": [
    { "id": "prod-001", "quantity": 5 },
    { "id": "prod-002", "quantity": 1 }
  ]
}
```

→ Schema: [`CreateQuoteDto`](../docs/api/openapi.json#/components/schemas/CreateQuoteDto)

---

### Report sync state

```http
PUT /public-api/sync-state/quote/quote-abc123 HTTP/1.1
Host: your-tenant.salesbuildr.com
api-key: YOUR_API_KEY_HERE
Content-Type: application/json

{
  "state": "ok",
  "error": "",
  "externalIdentifier": "PSA-TICKET-001"
}
```

→ Schema: [`SyncStateDto`](../docs/api/openapi.json#/components/schemas/SyncStateDto)

---

## Webhooks

Instead of polling, use webhooks to receive real-time push notifications.

Salesbuildr supports **16 event types** across: Company, Contact, Opportunity, Product, Quote, Order.

### Configuring Webhooks

1. Navigate to **Admin > Integrations > Webhooks**
2. Add your endpoint URL
3. Set optional custom headers
4. Select event types to subscribe to
5. Configure retry settings (up to **10 retry attempts**)

### Webhook vs. Polling

| | Webhooks | Polling |
|---|---|---|
| Real-time | Yes | No |
| Counts against rate limit | No | Yes |
| Recommended | **Yes** | No |

---

## Quotes — Concepts & Configuration

The Quote resource has limited write operations via the API (create and retrieve only — no update or delete). Understanding the full quote model is essential for building reliable integrations.

### Quote Lifecycle

| API Operation | Description |
|---|---|
| `POST /public-api/quote` | Create a new draft quote |
| `POST /public-api/quote/approved` | Create a pre-approved quote |
| `GET /public-api/quote/{id}` | Retrieve a quote |
| `GET /public-api/quote/{id}/pdf` | Download quote PDF |
| `GET /public-api/quote/{id}/attachment/{title}` | Download an attachment |

Quotes cannot be updated or deleted via the API. All modifications must happen through the Salesbuildr UI.

### Quote Status Flow

A quote moves through the following statuses. Each status change can automatically update the parent opportunity (see [Quote Status → Opportunity Stage Mapping](#quote-status--opportunity-stage-mapping)):

```
Draft → Sent → Approved
              → Declined
              → Expired
```

### Quote Configuration Defaults (Admin > Quotes > Configuration)

These global defaults apply to all new quotes and are important context when interpreting API responses:

#### Expiration & Reminders

| Setting | Description |
|---|---|
| `defaultExpirationTime` | Default validity period (e.g., 30 days) |
| `daysBeforeExpiryReminder` | Days before expiry to auto-send a reminder |

> **Timezone note:** Expiration dates are stored in **UTC**. If your account timezone differs, the displayed time may appear shifted. A user on UTC-5 who sets 12:00 PM local gets 12:00 UTC (7:00 AM local).

#### Customer-Facing Presentation

| Setting | Notes |
|---|---|
| Anonymous approvals | Customers can approve without logging in |
| Implicit T&C | No checkbox required — acceptance implies agreement |
| Signature on approval | Digital signature required at approval |
| Recipient can modify quantities | Customers can edit line item quantities |
| Recipient can modify description | Customers can edit line item descriptions |

> **Note:** "Recipient can modify quantities" must be enabled on **the individual quote**, not just globally or in a template.

#### Quote Naming Templates

Quotes use configurable naming templates with dynamic placeholders:

| Template | Example Output |
|---|---|
| `Quote-{quoteNumber}` | `Quote-1042` (PDF filename) |
| `Proposal for {companyName}` | `Proposal for Acme Corp` (quote title) |

### Approval Rules

Salesbuildr supports two approval modes. Quotes requiring approval will not proceed to the customer until approved.

#### Simple Approval (Admin > Quotes > Approval Rules)

| Trigger | Description |
|---|---|
| Above value | Require approval when quote total exceeds a threshold |
| Above discount % | Require approval when discount exceeds a percentage |
| Category filter | Trigger approval for specific product categories |

#### Advanced Approval Workflow

Multi-step, rule-based approvals. Each rule can combine:

- Value thresholds (above/below quote total)
- Discount thresholds
- Markup thresholds
- ARR thresholds
- Opportunity or product category filters
- Quote owner filters
- Manager approval routing
- Stop-other-rules flag

#### Approval Chain Order

1. **Internal approval** — routes to internal approvers
2. **Recipient approval** — sends to the opportunity contact
3. **External approval** — routes to company-configured external approvers

### Payment Terms & Types

These lookup values appear on quotes and are relevant when creating quotes via the API.

**Payment Terms** — Named entries like `Net 30`, `Net 60`, `Due on receipt`  
Managed under **Admin > Quotes > Payment Terms**. A default can be set in Configuration.

**Payment Types** — Accepted payment methods like `Bank transfer`, `Credit card`, `Direct debit`  
Managed under **Admin > Quotes > Payment Types**.

### Shipping Methods

Shipping methods are selectable options when adding shipping to a quote. Each method has:

| Field | Description |
|---|---|
| `name` | Shown on quotes and to customers |
| `cost` | Internal cost (not visible to customers) |
| `price` | Price charged to the customer |

A **free shipping threshold** can be configured in **Admin > Quotes > Configuration** — when the quote total exceeds it, shipping is automatically set to free.

### Discount Groups

Discount groups apply consistent pricing rules across customer segments. They are available as a resource via the API (`GET /public-api/quote-discount-group`).

**How discount groups work:**  
Each group contains one or more rules, each specifying:

| Field | Description |
|---|---|
| `type` | `% markup discount` or `cost + % markup` |
| `amount` | The percentage value |
| `productCategories` | Which categories this rule applies to |

When a quote is created for a company assigned to a discount group, matching product categories automatically receive the configured discount.

**Three customer pricing strategies** that can be combined:

1. **Discount groups** — Percentage-based rules per product category
2. **Pricing books** — Fixed prices per product per customer
3. **Import-to-quote** — Manual price overrides in the quote editor

Companies are assigned to discount groups via individual selection, by classification tier, or through the company manage dialog.

---

## Opportunities — Concepts & Configuration

Understanding how Salesbuildr models opportunities is essential when building integrations that read or write opportunity data via the API.

### How Opportunities Work

An opportunity in Salesbuildr is tightly coupled to its **primary quote**. Rather than updating the opportunity manually, the quote drives the opportunity automatically:

- The **quote status** (Draft, Sent, Approved, Declined, Expired) automatically updates the opportunity's **pipeline stage** and **status** based on your configured stage mapping.
- **One-time and recurring line items** on the quote determine the opportunity value.
- Combined with per-stage probability, this feeds sales forecast and pipeline reporting.

### Pipeline Stages

Opportunities move through configurable pipeline stages (e.g., Prospecting, Proposal Sent, Negotiation, Closed). Each stage has:

| Property | Description |
|---|---|
| `label` | The stage name |
| `probability` | Win probability % (auto-applied when an opportunity enters this stage) |
| `isDefault` | Whether this is the default stage for new opportunities |

> If your tenant is connected to a PSA (Autotask, ConnectWise, HaloPSA), pipeline stages are imported from the PSA and are **read-only** in Salesbuildr.

### Quote Status → Opportunity Stage Mapping

When a quote's status changes, the parent opportunity is automatically updated. This mapping is configured under **Admin > Opportunities > Settings**:

| Quote Status | → Opportunity Pipeline Stage | → Opportunity Status |
|---|---|---|
| Draft | (configurable) | (configurable) |
| Sent | (configurable) | (configurable) |
| Approved | (configurable) | (configurable) |
| Declined | (configurable) | (configurable) |
| Expired | (configurable) | (configurable) |

This auto-update only applies to the **primary quote**. If no mapping is configured, no automatic updates occur.

> **Note:** If a quote contains services, the opportunity stage will NOT be automatically moved even if a mapping is configured.

### Fulfillment Ticket Trigger

A separate mapping defines what happens when a fulfillment ticket is created from a quote — useful for marking the opportunity as Closed once the deal moves into fulfillment. This can also be mapped to an interim stage (e.g., "In Implementation") if fulfillment is a multi-step process.

> Closed opportunities do not appear in the Swimlane (Kanban) view.

### Categories, Sources & Loss Reasons

These are lookup values used when creating or updating opportunities via the API:

| Lookup | Description | PSA Import |
|---|---|---|
| **Categories** | Classify the type of opportunity | Autotask, ConnectWise (from opp. types), HaloPSA (from ticket types) |
| **Sources** | Track lead origin (e.g., Referral, Website) | Autotask, ConnectWise (from marketing campaigns) |
| **Loss Reasons** | Required when marking an opportunity as lost | Autotask only |

Manage these under **Admin > Opportunities**.

### Access Control

When "Restrict opportunity access" is enabled (**Admin > Opportunities > Settings**), non-admin users can only see opportunities and quotes they personally own. Keep this in mind when designing API integrations that read opportunity data on behalf of a user.

### PSA Integration Notes

| PSA | Synced Fields |
|---|---|
| **Autotask** | Pipeline stages, categories, sources, loss reasons, UDF mappings |
| **ConnectWise** | Pipeline stages, categories (from opp. types), sources (from marketing campaigns) |
| **HaloPSA** | Pipeline stages, categories (from ticket types), opportunity teams |

PSA-synced fields are read-only in Salesbuildr. To modify them, update in the PSA and re-sync via **Admin > Integrations > Synchronize**.

---

## Promax Implementation Notes (Sync-Forecasts.ps1)

Concrete endpoint usage and field mappings as implemented by the forecast sync script.

### Upsert an Opportunity from an AFAS Forecast

```
PUT /public-api/opportunity/ext/{externalIdentifier}
```

`{externalIdentifier}` is built as `afas-Forecast-{forecast}-{volgnummer}-{verkooprelatie}` from the AFAS `Salesbuildr_Forecasts` GetConnector record (e.g. `afas-Forecast-11310-42-10654`). Skipped (not upserted) if the existing Opportunity's `statusId` is already `"closed"`.

> **Three distinct fields — don't conflate them.** `forecast` is a globally-unique AFAS forecast id (e.g. `11310`), used as the `QuId` on the AFAS quotation (`KnQuotation`, voorcalculatie) — it is **not** the CmForecast key. `volgnummer` is the CmForecast `SqNo` (e.g. `42`). `verkooprelatie` is the AFAS debtor code = CmForecast `PrId` (e.g. `"10654"`), also used as `DbId` on the AFAS quotation. Encoding all three in the `externalIdentifier` lets Flows 3 and 4 each parse the CmForecast key straight from the identifier — via regex `^afas-Forecast-(?<fc>\d+)-(?<sqno>\d+)-(?<pr>.+)$` — with **no re-fetch** of the Forecast.

| AFAS field | Salesbuildr field | Notes |
|---|---|---|
| `forecast` | URL `externalIdentifier` (part 1) | Globally-unique AFAS forecast id, e.g. `11310` — also used as the AFAS quotation's `KnQuotation.QuId` |
| `volgnummer` | URL `externalIdentifier` (part 2) | CmForecast `SqNo`, e.g. `42` |
| `verkooprelatie` | URL `externalIdentifier` (part 3) | CmForecast `PrId` (AFAS debtor code), e.g. `"10654"`. **Not** the company key — that's `organisatie`. |
| `forecastOmschrijving` | `name` | |
| `organisatie` | `companyExtId` | AFAS organisatienummer → `afas-Organisatie-{organisatie}` (matches the org-sync key). Forecast is **skipped + logged** if no such Company exists in Salesbuildr. |
| `scoringkans` | `probability` | AFAS is 0–100; SB expects a **0–1 fraction** (`"probability must not be greater than 1"`), so the script sends `scoringkans / 100` |
| `bedragVerwacht` | `onetimeRevenue` | |
| `einddatumVerwacht` | `expectedCloseDate` | ISO `yyyy-MM-dd`; only set if not null |
| `verantwoordelijkeOwnerID` | `ownerId` | **Required** by the upsert (`"Either ownerId or ownerExtId is required"`). The GetConnector resolves the responsible AFAS employee to their internal Salesbuildr **user id** and returns it directly — sent as-is, no ext-id mapping. |
| `contactpersoonMail` | `contactId` (resolved) | Client contact e-mail. Looked up via `GET /public-api/contact?query={email}` and matched on exact `email`; the found contact's `id` is sent. **Required** — no e-mail or no matching contact logs a WARNING and the Forecast is **skipped** (same pattern as the missing-Company check; watermark held for retry). |
| `gewijzigd` | — | Delta sync filter field only (not mapped) |

> **Owner is not a Contact.** The responsible person (`ownerId`) is a Salesbuildr *user*, not a Contact — there is no public user endpoint, so it cannot be resolved by e-mail. The `Salesbuildr_Forecasts` GetConnector therefore supplies the SB user id directly in `verantwoordelijkeOwnerID`. (`verantwoordelijke` = AFAS employee code and `verantwoordelijkeMail` are also on the record but are not sent.) The client `contactId`, by contrast, *is* a Contact and is resolved by e-mail via `Get-SalesbuildrContactByEmail`.

### Fetch closed Opportunities

```
GET /public-api/opportunity?filters=statusId:closed&size={n}&from={offset}
```

Paginated via `size`/`from`. The `filters` parameter is **equality-only** (`field:value`, multiple values OR'd with `|`) — there are **no comparison/range operators**, so the close-date delta cannot be filtered server-side. The delta is therefore applied **client-side** on `closedAt > SinceDate` (not `updatedAt`, which moves on any edit); opportunities without a `closedAt` are skipped. Flows 2 (Items), 3 (Quotations) and 4 (PDF) each call this independently, with their own delta and their own watermark node — `Flow2`, `Flow3`, `Flow4` respectively — in the shared `configs/last-sync-dates.xml` state file (alongside Flow 1's `Flow1` node; see `Get-/Set-SyncWatermark` in `Sync-Forecasts.ps1`). An optional `<OverrideDays>N</OverrideDays>` element in `configs/config.xml` (`Get-SyncOverrideDays`) is a test override that makes all four flows sync from N days ago at local midnight for that run; ignored when empty/missing/non-numeric.

### Fetch the primary quote for a closed Opportunity

```
GET /public-api/quote?filters=opportunity.id:{id}&size=100
```

> ⚠️ **Filter key is `opportunity.id`, not `opportunityId`.** The documented example (`filters=statusId:approved,opportunityId:opp123`) is wrong for this field — `filters=opportunityId:{id}` returns `total: 0` on the Promax tenant even when a matching quote exists, and a bare `?opportunityId={id}` query param throws a 400 validation error. The correct filter key is the nested field name `opportunity.id` (colon URL-encoded as `%3A`, same as `statusId%3Aclosed` above), which fetches server-side per-opportunity — no bulk fetch or client-side cache needed. The quote→opportunity link lives in `QuoteResponseDto.opportunity` (`{ id, name, ... }`).

Among the returned quotes, the one with `primary: true` is used — **no fallback** to any other approved quote. A missing or non-`approved` primary quote is not treated as an error; it drives the Lost categorization below. Note: `primary` is **per-opportunity** — every quote reports `primary: true` for its own opportunity — so it only disambiguates once the set is already narrowed to a single opportunity.

### Quote line → AFAS `KnQuotationLine`

| Salesbuildr field (`QuoteItemResponseDto`) | AFAS field | Notes |
|---|---|---|
| `mpn` (artikel) / `internalProductId` via `Get-SalesbuildrProductInternalId` (Diensten) | `ItCd` | Item code, resolved per line by `Resolve-AfasLineItem` — see below. The old "AFAS werksoort" product custom field is **no longer read**. |
| — (derived from the resolution above) | `VaIt` | Line type: `"2"` (artikel) when resolved from `mpn`; `"1"` (werksoort) when a Diensten line's `internalProductId` already exists in AFAS; `"3"` (tekstregel/TXT) when a Diensten line's `internalProductId` is blank or not found in AFAS. |
| `name` | `Ds` (on article create) **or** a TXT line's `Ds` | Article create: capped at 100 chars for `FbItemArticle.Ds`. TXT line: composed into the info string `"{name} - aantal {qty}, prijs {price}, kostprijs {cost}"`, capped at 255 chars. |
| `quantity` | `QuUn` / `Qu` / `QuSa` | Set to the same value on artikel/werksoort lines; all three are **empty strings** on a TXT line (no quantity). |
| `price` | `Upri` | Per-unit sell price on artikel/werksoort lines. **Not** `unitPrice`; raw `price`, **discount is not applied** (see caveat below). **Empty string** on a TXT line. |
| `cost` | `AmCo` | Per-unit cost price on an artikel line. **Always `"0"`** on a werksoort line — Diensten lines never carry a real cost into AFAS. **Empty string** on a TXT line. |
| — | `UnId` | Not derived from a Salesbuildr field. `"St"` (stuks/pieces) on artikel lines; **empty string `""`** on werksoort and TXT lines. |
| `category` `{ id, name }` | `Grp` (article group) | See below — resolved via the line's **main category**, not the leaf `category.id` directly; set only when the article is **created** (`FbItemArticle`), not on the quote line; not applicable to werksoort/TXT lines. |

⚠️ **Caveat:** `Upri` uses the raw per-unit `price` and does not apply the item `discount`, whereas `CmForecast.OrAF` (see below) *does* apply discount. Known inconsistency, pending confirmation — not yet fixed in code.

### Resolving the line item (`ItCd` + `VaIt`) via `Resolve-AfasLineItem`

`QuoteItemResponseDto` (the quote **item**) has **no `customFields` of its own** — custom fields live on the item's nested **`product`** reference (`IdentifiedEntityResponseDto`: `id, name, externalIdentifier, labels, customFields`). `product` is nullable — free-form quote lines with no linked catalog product have none.

Each line is resolved by `Resolve-AfasLineItem -Line -CategoryParentMap -DienstenMainCategoryId` — called independently by Flow 2 (Items) and Flow 3 (Quotations), each on their own fetched batch of Won lines, in order:

1. **`mpn` present** → `ItemCode = mpn`, `VaIt = "2"` (artikel). Unchanged from before: used for both the "does the article exist?" lookup (`Salesbuildr_Artikelen.itemCode`, Flows 2 and 3) and creation (`FbItemArticle.ItCd`, Flow 2 only).
2. **No `mpn`, but the line's main category is "Diensten"** — resolved the same way as the artikelgroep main category below (`Get-SalesbuildrMainCategoryId` walks the leaf `category.id` up to its root, using the parent map built at startup) and compared against `configs/config.xml`'s `<salesbuildr><diensten_maincategory_id>` (SB main-category id `UyOpp42UPGy3LKgSOQGX` by default; also added to `configs/config.example.xml`) → `Kind = 'diensten'`, `ItemCode` = the line's **`internalProductId`** (or `''` if the product has none).
3. **Neither `mpn` nor Diensten** → the line is unmappable (`Resolve-AfasLineItem` returns `$null`).

The **old "AFAS werksoort" product custom-field branch is removed entirely.** A werksoort must now live under the Diensten main category, and its AFAS item code comes from the product's `internalProductId`, not a custom field.

Reading the `internalProductId` (`Get-SalesbuildrProductInternalId`):

- The inline quote-line `product` reference (`IdentifiedEntityResponseDto`: `id, name, externalIdentifier, labels, customFields`) does **not** carry `internalProductId` — it simply isn't one of that DTO's fields, unlike the werksoort custom field before it.
- The helper therefore **always** fetches the full product via `GET /public-api/product/{id}` (`Get-SalesbuildrProductById`, returns a [`ProductResponseDto`](../docs/api/openapi.json#/components/schemas/ProductResponseDto)) — cached per product id in `$Global:SbProductCache` so multiple lines referencing the same product cost only one extra API call.
- Returns the trimmed `internalProductId` string, or `$null` if there is no linked product or the field is empty.

**Diensten existence check** (Flow 3, Stap 3b): for each unique non-blank Diensten `internalProductId`, the script checks AFAS the same way as for articles — a per-code filtered `Salesbuildr_Artikelen.itemCode` lookup (`Get-AfasArtikelByItemCode`) — result stored in `$DienstenExists`. Diensten codes are **never** added to `$FailedItemCodes` and **never created** via `FbItemArticle` (that connector only creates articles, and only Flow 2 ever calls it).

**Line building** (Flow 3, Stap 3c / `New-AfasQuotation`): a Diensten line becomes one of two `KnQuotationLine` shapes, based on the existence check:

- **exists in AFAS → werksoort line**, `VaIt = "1"`: `ItCd = internalProductId`, `UnId = ""` (no unit), `QuUn`/`Qu`/`QuSa` = quantity, `Upri` = price, and `AmCo = "0"` **always** (werksoorten always have cost price 0).
- **not found, or blank `internalProductId` → TXT line**, `VaIt = "3"`: `ItCd = "SBO"` (fixed AFAS text-item code for Salesbuildr text lines), `Ds` = the composed info string `"{name} - aantal {qty}, prijs {price}, kostprijs {cost}"` capped at **255 chars**, and `UnId`/`QuUn`/`Qu`/`QuSa`/`Upri`/`AmCo` all **empty strings** (a text line carries no quantities or amounts).

Article lines are unaffected by any of this — they stay `VaIt = "2"` with `UnId = "St"` and `AmCo = cost`.

**Whole-opportunity enforcement:** in Flow 3's Stap 3c, if any line of a Won opportunity is unmappable (case 3 above) or resolves to an **article** unavailable in AFAS (not yet created by Flow 2), the **entire opportunity** is skipped — the AFAS quotation (`KnQuotation`) is not created and the originating Forecast is not closed (stays open), with the watermark held for retry. **Diensten lines never trigger this skip** — regardless of whether their `internalProductId` exists in AFAS, they always resolve to a werksoort or TXT line. See [AFAS_API_Guide.md](AFAS_API_Guide.md#promax-implementation-notes-sync-forecastsps1) for the resulting `KnQuotationLine` payload shapes.

### Article group (`Grp`) via `configs/mapping-artikelgroepen.xml`

When a missing article is created in AFAS (Flow 2 — Items), its **artikelgroep** (`FbItemArticle.Grp`) is required and is resolved in a **two-hop main-category lookup**: the line's leaf `category.id` is walked up to its main (root) category, and that main-category id is then looked up in the repo file `configs/mapping-artikelgroepen.xml`.

**Hop 1 — leaf category → main category.** At the **start of the run**, `Get-SalesbuildrCategoryParentMap` fetches all categories via `GET /public-api/category` (flat list, [`CategoryResponseDto[]`](../docs/api/openapi.json#/components/schemas/CategoryResponseDto)) and builds an in-memory map `category.id -> parentCategoryId` (empty `parentCategoryId` = root). For each quote line, `Get-SalesbuildrMainCategoryId -CategoryId -ParentMap` walks the line's `category.id` (`QuoteItemResponseDto.category.id`) up this parent chain to the topmost/root category id (cycle-protected; returns `$null` if the category id is unknown to the map).

**Hop 2 — main category → `Grp`.** The resulting main-category id is looked up in `configs/mapping-artikelgroepen.xml`:

```xml
<mapping-artikelgroepen>
  <categorie SB-maincat-id="..." SB-naam="..." AFAS-id="70" AFAS-naam="Hardware"/>
</mapping-artikelgroepen>
```

- `SB-maincat-id` = the SB **main (root) category** id — the result of hop 1, not the quote line's leaf `category.id`.
- `AFAS-id` = the AFAS artikelgroep code (`Grp`).
- `AFAS-naam` = the artikelgroep description, used only for logging.
- Only categories with a non-empty `AFAS-id` are loaded into the in-memory map. A main category absent from the file, or present with an empty `AFAS-id` — or a leaf category that cannot be resolved to a main category at all — is "not mapped": Flow 2 skips creating that article (WARNING, its watermark held for retry); the article then stays missing in AFAS, so Flow 3 subsequently detects it via its own existence check and skips the whole opportunities that reference it.

`GET /public-api/category` is fetched once per run (not obsolete/removed — it is back, needed to resolve main categories); `configs/config.xml`'s old `<afas><artikelgroepmapping><costcenter id grp>` block remains removed (superseded by `configs/mapping-artikelgroepen.xml`). See `Get-SalesbuildrCategoryParentMap`, `Get-SalesbuildrMainCategoryId`, `Get-AfasArtikelgroep` (now takes `-CategoryParentMap`).

### Won/Lost categorization

Each closed Opportunity is categorized strictly by its **primary quote** (`primary: true` — no fallback to any other approved quote):

| Outcome | Condition | Actions |
|---|---|---|
| **Won** (`ViOp = "G"`) | primary quote exists **and** `status == "approved"` | Flow 2 creates missing Articles (`FbItemArticle`); Flow 3 creates the AFAS quotation (`KnQuotation`, voorcalculatie) and closes the Forecast with `G` + `OrAF`; Flow 4 attaches the SB quote PDF (`KnSubject`) once the quotation exists |
| **Lost** (`ViOp = "N"`) | no primary quote, **or** primary quote `status != "approved"` | Flow 3 closes the Forecast with `N` only — no Articles, no AFAS quotation, no PDF |

Flows 2, 3 and 4 each run this categorization independently (on their own fetched batch, via the shared `Split-ClosedOpportunities` helper), so a missing/unapproved primary quote is **not** an error — it's a legitimate Lost outcome and still advances each flow's own watermark once its work for that opportunity is done. Only genuine API/network failures (and unmapped categories, missing Companies, unavailable articles, etc.) hold a watermark for retry.

> **Won idempotency ordering:** for a Won opportunity, "create the AFAS quotation" and "close the Forecast" are decoupled. If the `KnQuotation` already exists (idempotency check on `offerte`), only its **creation** is skipped — the Forecast is still closed with `G` + `OrAF` (the close is an idempotent `PUT`). This means a prior run that created the quotation but crashed/errored before closing the Forecast will complete the close on the next run, instead of retrying (and failing) the creation forever. The unmapped-category / unmappable-line whole-opportunity skip (see [AFAS_API_Guide.md](AFAS_API_Guide.md#promax-implementation-notes-sync-forecastsps1) and the [line resolution notes above](#resolving-the-line-item-itcd--vait-via-resolve-afaslineitem)) only applies when creation is attempted — a quotation that already exists necessarily had its articles/werksoorten resolved in a prior run.

### OrAF (total quote amount)

`OrAF` on the Forecast-close call is computed client-side from the primary quote's `items`, since `QuoteResponseDto` has no ready-made total field:

```
OrAF = Σ (price × quantity × (1 - discount))
```

`discount` is a decimal fraction (`0.12` = 12%, `0.5` = 50%); values near zero (e.g. `-1e-6`) are rounding noise and treated as no discount. `setupPrice` and the quote-level `discount` (always empty in practice) are ignored. `OrAF` is included only when closing as Won — omitted entirely for Lost.

### Close the originating Forecast (`OpportunityResponseDto` → AFAS)

Flow 3 never re-fetches the AFAS Forecast — the composite CmForecast key and the AFAS quotation id are all parsed directly from the Opportunity's `externalIdentifier` via `^afas-Forecast-(?<fc>\d+)-(?<sqno>\d+)-(?<pr>.+)$`:

- `SqNo` = `$Matches.sqno` (`volgnummer`)
- `PrId` = `$Matches.pr` (`verkooprelatie`)
- `QuId` (AFAS quotation / idempotency key) = `$Matches.fc` (the AFAS `forecast` id)

See [AFAS_API_Guide.md](AFAS_API_Guide.md) for the resulting `CmForecast`/`KnQuotation`/`FbItemArticle` payloads.

### Download the quote PDF and attach it in AFAS (Flow 4)

```
GET /public-api/quote/{id}/pdf
```

Returns the quote PDF as a **binary file** (not JSON) — a 404 means the quote has no PDF (e.g. not yet generated/approved). `Get-SalesbuildrQuotePdf -QuoteId` calls this via `Invoke-WebRequest` directly rather than the shared `Invoke-SalesbuildrRequest` wrapper, because that wrapper's `ConvertFrom-Json` would corrupt binary content; it reads the raw bytes off `RawContentStream.ToArray()` (works on both Windows PowerShell 5.1 and PowerShell 7) and returns them Base64-encoded, ready for `KnSubjectAttachment.FileStream`. HTTP 404 or an empty response body both return `$null` (logged WARNING, Flow 4 watermark held for retry).

Flow 4 only requests the PDF for **Won** opportunities — same primary-quote/`status == "approved"` check used by the shared Won/Lost categorization (`Split-ClosedOpportunities` / `Get-SalesbuildrPrimaryQuote`) — and only once the AFAS quotation for that opportunity already exists (`KnQuotation`, created by Flow 3) and no attachment is recorded yet for it in `Salesbuildr_Dossieritems` (see [AFAS_API_Guide.md](AFAS_API_Guide.md#salesbuildr_dossieritems--getconnector-read-attachment-records)). A Lost opportunity (no approved primary quote) is a legitimate no-op here too — no PDF, no error, watermark still advances. See [AFAS_API_Guide.md](AFAS_API_Guide.md#attach-the-sb-quote-pdf-as-a-dossieritem-knsubject-post-flow-4) for the resulting `KnSubject` payload.

---

## Further Reading

- [Salesbuildr Help Center — Public API](https://help.salesbuildr.com/articles/3446453-public-api)
- [Full API Reference (Redocly)](https://portal.salesbuildr.com/public-api#/)
- [OpenAPI Spec](../docs/api/openapi.json) — authoritative source for all request/response schemas
