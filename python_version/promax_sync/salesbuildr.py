"""Salesbuildr CPQ REST-client.

Mirror van de #region SalesBuildr-functies in Sync-Forecasts.ps1. Caches (product,
company) en de request-sessie zitten in de client-instance i.p.v. globals.
"""

from __future__ import annotations

import base64
from datetime import datetime
from decimal import Decimal
from typing import Optional
from urllib.parse import quote

import requests

from .helpers import (
    get_salesbuildr_main_category_id,
    to_json,
)


def _status_code(exc: requests.HTTPError) -> Optional[int]:
    return exc.response.status_code if exc.response is not None else None


class Outcome:
    """Resultaat van split_closed_opportunities (Won/Lost + quote-gegevens per Won-opp)."""

    def __init__(self) -> None:
        self.won: list = []
        self.lost: list = []
        self.lines: dict = {}    # opportunityId -> quote-items (alleen Won)
        self.titles: dict = {}   # opportunityId -> quote.title (alleen Won)
        self.quotes: dict = {}   # opportunityId -> primaire quote (alleen Won)
        self.all_ok: bool = True


class SalesbuildrClient:
    def __init__(self, uri: str, api_key: str, logger) -> None:
        # Uri = https://[tenant]...  (zonder trailing slash, zonder /public-api)
        self.uri = uri
        self.session = requests.Session()
        self.session.headers.update({"api-key": api_key})
        self.logger = logger
        self._company_cache: dict = {}
        self._product_cache: dict = {}

    # ── centrale request-wrapper ──────────────────────────────────────────────

    def request(self, uri: str, method: str = "GET", body=None):
        """Alle SB GET/PUT-calls. Waarschuwt als de rate limit bijna bereikt is."""
        kwargs = {}
        if body is not None:
            kwargs["data"] = to_json(body) if not isinstance(body, str) else body
            kwargs["headers"] = {"Content-Type": "application/json"}
        resp = self.session.request(method, uri, **kwargs)
        resp.raise_for_status()

        remaining = resp.headers.get("X-RateLimit-Remaining")
        if remaining is not None:
            try:
                if int(remaining) < 50:
                    self.logger.warning(
                        f"SalesBuildr rate limit bijna bereikt: {remaining} / 500 "
                        "requests resterend in huidig venster"
                    )
            except ValueError:
                pass

        if resp.content:
            return resp.json()
        return None

    def test_connection(self) -> bool:
        """Valideert de API-key met een lichte GET (één opportunity). HTTP 401 -> False."""
        try:
            self.request(f"{self.uri}/public-api/opportunity?size=1")
            return True
        except requests.HTTPError as exc:
            if _status_code(exc) == 401:
                return False
            raise

    # ── categorieën ─────────────────────────────────────────────────────────────

    def get_category_parent_map(self) -> dict:
        """Bouwt category.id -> parentCategoryId (leeg voor hoofdcategorieën)."""
        categories = self.request(f"{self.uri}/public-api/category") or []
        parent_map = {}
        for cat in categories:
            cid = cat.get("id")
            if cid and str(cid).strip():
                parent = cat.get("parentCategoryId")
                parent_map[cid] = str(parent) if parent is not None else ""
        return parent_map

    # ── opportunities ───────────────────────────────────────────────────────────

    def get_closed_opportunities(self, since_date: datetime, company_id_filter: Optional[str] = None) -> list:
        """Alle 'closed' en 'lost' Opportunities (server-side), client-side gefilterd op
        sluitingsdatum > since_date.

        De SB search-API kent geen >/< operatoren, vandaar het server-side
        statusId:closed|lost-filter + een client-side datumfilter. Voor 'closed' is dat
        'closedAt'; een 'lost'-Opportunity heeft GEEN closedAt — daar 'updatedAt'.
        Records zonder bruikbare datum worden overgeslagen.
        ``company_id_filter`` (alleen TEST/mode 2) beperkt tot één klant (company.id).
        """
        all_results: list = []
        size = 100
        from_ = 0
        total = 0

        while True:
            response = self.request(
                f"{self.uri}/public-api/opportunity?filters=statusId%3Aclosed%7Clost&size={size}&from={from_}"
            )
            all_results.extend(response.get("results", []))
            total = response.get("total", 0)
            from_ += size
            if len(all_results) >= total:
                break

        def _sluit_datum(opp):
            if opp.get("closedAt"):
                return opp["closedAt"]
            if opp.get("statusId") == "lost":
                return opp.get("updatedAt")
            return None

        filtered = [
            opp
            for opp in all_results
            if _sluit_datum(opp) and _parse_dt(_sluit_datum(opp)) > since_date
        ]

        if company_id_filter and company_id_filter.strip():
            filtered = [
                opp
                for opp in filtered
                if opp.get("company") and opp["company"].get("id") == company_id_filter
            ]
        return filtered

    def get_opportunity_by_ext_id(self, external_id: str):
        """Opportunity via external ID (voor de 'skip if Closed' check). 404 -> None."""
        try:
            return self.request(f"{self.uri}/public-api/opportunity/ext/{external_id}")
        except requests.HTTPError as exc:
            if _status_code(exc) == 404:
                return None
            raise

    def upsert_opportunity(self, external_id: str, body: dict):
        """Upsert een Opportunity via external ID (PUT /public-api/opportunity/ext/{id})."""
        return self.request(
            f"{self.uri}/public-api/opportunity/ext/{external_id}",
            method="PUT",
            body=body,
        )

    # ── companies ─────────────────────────────────────────────────────────────

    def get_company_by_name(self, name: str):
        """Zoekt een Company op naam (vrije-tekst query), exacte case-insensitieve match op 'name'."""
        if not name or not name.strip():
            return None
        encoded = quote(name, safe="")
        response = self.request(f"{self.uri}/public-api/company?query={encoded}&size=100")
        companies = response.get("results") if isinstance(response, dict) and response.get("results") else response
        for company in companies or []:
            if company.get("name") and company["name"].lower() == name.lower():
                return company
        return None

    def get_company_by_id(self, company_id: str):
        """Company via interne SB-id (gecachet). 404 -> None."""
        if not company_id or not str(company_id).strip():
            return None
        if company_id in self._company_cache:
            return self._company_cache[company_id]
        try:
            company = self.request(f"{self.uri}/public-api/company/{company_id}")
        except requests.HTTPError as exc:
            if _status_code(exc) == 404:
                company = None
            else:
                raise
        self._company_cache[company_id] = company
        return company

    def get_company_by_ext_id(self, external_id: str):
        """Company via external ID ('afas-Organisatie-{nr}'). 404 -> None (nog niet gesynct)."""
        try:
            return self.request(f"{self.uri}/public-api/company/ext/{external_id}")
        except requests.HTTPError as exc:
            if _status_code(exc) == 404:
                return None
            raise

    # ── contacts ──────────────────────────────────────────────────────────────

    def get_contact_by_email(self, email: str, company_id: Optional[str] = None):
        """Zoekt een Contact op e-mail (vrije-tekst query), exacte case-insensitieve match op 'email'.

        Met ``company_id`` worden alleen contacten van díe Company geaccepteerd: hetzelfde
        e-mailadres kan bij meerdere companies bestaan, en SB weigert een Opportunity-upsert
        waarvan het contact niet bij de opportunity-company hoort (HTTP 400).
        """
        if not email or not email.strip():
            return None
        encoded = quote(email, safe="")
        response = self.request(f"{self.uri}/public-api/contact?query={encoded}&size=100")
        contacts = response.get("results") if isinstance(response, dict) and response.get("results") else response
        for contact in contacts or []:
            if not (contact.get("email") and contact["email"].lower() == email.lower()):
                continue
            if company_id and company_id.strip() and contact.get("companyId") != company_id:
                continue
            return contact
        return None

    # ── quotes ──────────────────────────────────────────────────────────────────

    def get_primary_quote(self, opportunity_id: str):
        """De PRIMAIRE quote (primary:true) van een Opportunity, of None.

        Filtert de quote-endpoint op 'opportunity.id' (OpportunityResponseDto heeft geen
        quoteId). GEEN fallback naar een andere approved quote. De search-endpoint geeft
        GEEN 'items' mee, dus de primaire quote wordt altijd volledig opgehaald
        (GET /public-api/quote/{id}).
        """
        response = self.request(
            f"{self.uri}/public-api/quote?filters=opportunity.id%3A{opportunity_id}&size=100"
        )
        quotes = response.get("results", []) if response else []
        primary = next((q for q in quotes if q.get("primary") is True), None)
        if primary is None:
            return None
        return self.request(f"{self.uri}/public-api/quote/{primary['id']}")

    def get_quote_pdf(self, quote_id: str) -> Optional[str]:
        """PDF van een SB-quote als Base64-string (voor KnSubjectAttachment.FileStream).

        Binaire data -> rechtstreeks via de sessie (niet de JSON-wrapper). 404 of lege
        respons -> None (gelogd).
        """
        try:
            resp = self.session.get(f"{self.uri}/public-api/quote/{quote_id}/pdf")
            resp.raise_for_status()
        except requests.HTTPError as exc:
            if _status_code(exc) == 404:
                self.logger.warning(f"Geen PDF gevonden voor SB-quote {quote_id} (HTTP 404)")
                return None
            raise

        data = resp.content
        if not data:
            self.logger.warning(f"Lege PDF-respons voor SB-quote {quote_id}")
            return None
        return base64.b64encode(data).decode("ascii")

    def get_quote_total(self, items: list) -> Decimal:
        """Totale offertebedrag (CmForecast.OrAF): Σ price * quantity * (1 - discount)."""
        total = Decimal(0)
        for item in items or []:
            price = Decimal(str(item.get("price"))) if item.get("price") is not None else Decimal(0)
            quantity = Decimal(str(item.get("quantity"))) if item.get("quantity") is not None else Decimal(0)
            discount = Decimal(str(item.get("discount"))) if item.get("discount") is not None else Decimal(0)
            total += price * quantity * (Decimal(1) - discount)
        return total

    # ── products ──────────────────────────────────────────────────────────────

    def get_product_by_id(self, product_id: str):
        """Eén product via GET /public-api/product/{id} (gecachet). None bij fout."""
        if product_id in self._product_cache:
            return self._product_cache[product_id]
        try:
            product = self.request(f"{self.uri}/public-api/product/{product_id}")
        except requests.HTTPError as exc:
            self.logger.warning(f"Product [{product_id}] kon niet opgehaald worden: {exc}")
            product = None
        self._product_cache[product_id] = product
        return product

    def get_product_custom_field(self, line: dict, field_name: str) -> Optional[str]:
        """Leest een custom field van het aan de regel gekoppelde product (inline of via fetch)."""
        product_ref = line.get("product")
        if not product_ref or not str(product_ref.get("id") or "").strip():
            return None

        # 1) Inline op de regel meegeleverd?
        cf = product_ref.get("customFields")
        if isinstance(cf, dict) and field_name in cf:
            val = cf[field_name]
            if val is not None and str(val).strip():
                return str(val).strip()

        # 2) Fallback: pas hier het product ophalen (gecachet).
        product = self.get_product_by_id(product_ref["id"])
        cf = product.get("customFields") if product else None
        if isinstance(cf, dict) and field_name in cf:
            val = cf[field_name]
            if val is not None and str(val).strip():
                return str(val).strip()
        return None

    def get_product_internal_id(self, line: dict) -> Optional[str]:
        """Leest product.internalProductId (altijd via een volledige product-fetch, gecachet)."""
        product_ref = line.get("product")
        if not product_ref or not str(product_ref.get("id") or "").strip():
            return None
        product = self.get_product_by_id(product_ref["id"])
        if product:
            val = product.get("internalProductId")
            if val is not None and str(val).strip():
                return str(val).strip()
        return None

    def get_product_is_serialized(self, line: dict) -> bool:
        """Leest product.isSerialized (stuurt AdSr in Flow 2); altijd via een product-fetch.

        Geen product of veld leeg (nullable) -> False.
        """
        product_ref = line.get("product")
        if not product_ref or not str(product_ref.get("id") or "").strip():
            return False
        product = self.get_product_by_id(product_ref["id"])
        if not product or product.get("isSerialized") is None:
            return False
        return bool(product["isSerialized"])

    # ── gedeelde Won/Lost-categorisatie ───────────────────────────────────────

    def split_closed_opportunities(self, opportunities: list, log_prefix: str) -> Outcome:
        """Categoriseert gesloten Opportunities als Won of Lost o.b.v. UITSLUITEND de primaire quote.

        Won: closed + primaire quote status == 'approved'. Lost: closed + geen/niet-
        goedgekeurde primaire quote (GEEN fout), of opportunity statusId 'lost' (quote wordt
        dan niet opgehaald). Een écht mislukte quote-fetch zet all_ok = False; de aanroeper
        houdt dan zijn watermerk vast.
        """
        outcome = Outcome()

        for opportunity in opportunities:
            opportunity_id = opportunity.get("id")
            self.logger.info(
                f"[{log_prefix}] Opportunity {opportunity_id} | "
                f"externalId {opportunity.get('externalIdentifier')}"
            )

            # statusId 'lost' in SB = altijd Lost, ongeacht de quote — geen quote-fetch nodig.
            if opportunity.get("statusId") == "lost":
                outcome.lost.append(opportunity)
                self.logger.info(f"[{opportunity_id}] LOST — Opportunity-status 'lost' in SalesBuildr")
                continue

            try:
                quote_obj = self.get_primary_quote(opportunity_id)
            except Exception as exc:  # noqa: BLE001 - netwerken/API-fout -> batch vasthouden
                self.logger.error(f"[{opportunity_id}] Fout bij ophalen primaire quote: {exc}")
                outcome.all_ok = False
                continue

            if quote_obj is not None:
                company = quote_obj.get("company") or {}
                self.logger.info(
                    f"[{log_prefix}] Quote {quote_obj.get('id')} (SB-offertenummer {quote_obj.get('number')}) | "
                    f"status '{quote_obj.get('status')}' | klant '{company.get('name')}'"
                )

            if quote_obj is not None and quote_obj.get("status") == "approved":
                items = quote_obj.get("items") or []
                outcome.lines[opportunity_id] = items
                outcome.titles[opportunity_id] = quote_obj.get("title")
                outcome.quotes[opportunity_id] = quote_obj
                outcome.won.append(opportunity)
                self.logger.info(
                    f"[{opportunity_id}] WON — primaire quote 'approved' ({len(items)} regel(s))"
                )
            else:
                reason = "geen primaire quote" if quote_obj is None else f"primaire quote status = '{quote_obj.get('status')}'"
                outcome.lost.append(opportunity)
                self.logger.info(f"[{opportunity_id}] LOST — {reason}")

        return outcome


def resolve_afas_line_item(line: dict, sb: SalesbuildrClient, category_parent_map: dict, diensten_main_category_id: str):
    """Bepaalt per SB-quote-regel de AFAS-itemcode (ItCd) én het regeltype (VaIt).

    - abonnement (term <> 'one-time')       -> {Kind='abonnement', VaIt='3', ItemCode='',
      Term}: ALTIJD een TXT-regel, ook als er een mpn is; nooit als artikel aangemaakt
    - mpn aanwezig                          -> {ItemCode=mpn, VaIt='2', Kind='artikel'}
    - geen mpn, hoofdcategorie = 'Diensten' -> {Kind='diensten', ItemCode=internalProductId
      (mag leeg zijn), VaIt='1'}
    - geen van beide                        -> None (regel niet naar AFAS te mappen)
    """
    # Abonnement: QuoteItemResponseDto.term is 'one-time' (eenmalig) of een periode
    # ('month', 'year'). Elke terugkerende regel wordt een TXT-regel, vóór de mpn-check.
    term = str(line.get("term") or "").strip().lower()
    if term and term != "one-time":
        return {"ItemCode": "", "VaIt": "3", "Kind": "abonnement", "Name": line.get("name"), "Term": term}

    mpn = line.get("mpn")
    if mpn is not None and str(mpn).strip():
        return {"ItemCode": str(mpn).strip(), "VaIt": "2", "Kind": "artikel", "Name": line.get("name")}

    category = line.get("category") or {}
    main_cat_id = get_salesbuildr_main_category_id(category.get("id"), category_parent_map)
    if main_cat_id and main_cat_id == diensten_main_category_id:
        internal_id = sb.get_product_internal_id(line)
        item_code = internal_id if internal_id else ""
        return {"ItemCode": item_code, "VaIt": "1", "Kind": "diensten", "Name": line.get("name")}

    return None


def get_line_supplier_name(line: dict) -> Optional[str]:
    """Leveranciersnaam van een quote-regel (supplier.name), getrimd; None als er geen is.

    Wordt via mapping-leveranciers.xml naar de AFAS-crediteurcode vertaald (Flow 3).
    """
    supplier = line.get("supplier") or {}
    name = supplier.get("name")
    if name is None or not str(name).strip():
        return None
    return str(name).strip()


def get_afas_artikelgroep(category: Optional[dict], artikelgroep_map: dict, category_parent_map: dict):
    """Vertaalt een SB-productcategorie naar een AFAS artikelgroep (Grp) via de hoofdcategorie."""
    if not category or not str(category.get("id") or "").strip():
        return None
    main_cat_id = get_salesbuildr_main_category_id(category["id"], category_parent_map)
    if main_cat_id and main_cat_id in artikelgroep_map:
        return artikelgroep_map[main_cat_id]
    return None


def _parse_dt(text: str) -> datetime:
    """Parseert een ISO-datetime van SB; maakt een naive resultaat aware in lokale tijd."""
    dt = datetime.fromisoformat(text.replace("Z", "+00:00") if isinstance(text, str) else text)
    if dt.tzinfo is None:
        dt = dt.astimezone()
    return dt
