#!/usr/bin/env python3
"""Synchroniseert AFAS Profit Forecasts naar Salesbuildr als Opportunities, en verwerkt
gesloten Opportunities terug naar AFAS als voorcalculatie + dossieritem.

Python-herschrijving van Sync-Forecasts.ps1. Vier onafhankelijke flows, elk met een
eigen config-toggle en watermerk, die achtereenvolgens in één run draaien:

    Flow 1: Gewijzigde Forecasts in AFAS  -> Upsert als Opportunity in Salesbuildr
    Flow 2: Gewonnen SB-quotations        -> ontbrekende Items (artikelen) in AFAS
    Flow 3: Gewonnen SB-quotations        -> AFAS-quotation (voorcalculatie) + Forecast sluiten
    Flow 4: SB quote-PDF                  -> AFAS dossieritem (KnSubject)

Config/mapping/state staan plaintext in ../configs/ (gedeeld met de PowerShell-versie);
het samenvattende run-logboek in ../logs/log.txt.
"""

from __future__ import annotations

import os
import sys

# Zorg dat het pakket importeerbaar is ongeacht vanwaar het script gestart wordt.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from promax_sync.afas import (  # noqa: E402
    AfasClient,
    afas_error_text,
    build_quotation_body,
    get_forecast_status_code,
)
from promax_sync.config import (  # noqa: E402
    find_text,
    get_sync_override_days,
    get_sync_watermark,
    override_date,
    read_xml_config,
    set_sync_watermark,
)
from promax_sync.helpers import (  # noqa: E402
    convert_to_config_bool,
    get_salesbuildr_main_category_id,
    parse_forecast_external_id,
    to_json,
)
from promax_sync.logging_util import FLOW_LABELS, Logger, RunLog  # noqa: E402
from promax_sync.salesbuildr import (  # noqa: E402
    SalesbuildrClient,
    get_afas_artikelgroep,
    get_line_supplier_name,
    resolve_afas_line_item,
)

# ── project-locaties ──────────────────────────────────────────────────────────
# De config/mapping/state en logs staan één niveau boven deze map (de repo-root),
# net als $PSScriptRoot\configs bij de PowerShell-versie die in de repo-root leeft.
PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONFIG_DIR = os.path.join(PROJECT_ROOT, "configs")
CONFIG_FILE = os.path.join(CONFIG_DIR, "config.xml")
MAPPING_FILE = os.path.join(CONFIG_DIR, "mapping-artikelgroepen.xml")
SYNC_STATE_FILE = os.path.join(CONFIG_DIR, "last-sync-dates.xml")
LEVERANCIERS_FILE = os.path.join(CONFIG_DIR, "mapping-leveranciers.xml")
LOG_FILE = os.path.join(PROJECT_ROOT, "logs", "log.txt")

# Dry-run-schakelaars per flow (hardcoded, net als in de PowerShell-versie). Op True
# gezet fetch/categoriseert de flow wél, maar slaat elke AFAS-write over en houdt het
# watermerk vast — zo kun je een flow inspecteren zonder AFAS te muteren.
AFAS_WRITES_ON_HOLD_2 = False
AFAS_WRITES_ON_HOLD_3 = False
AFAS_WRITES_ON_HOLD_4 = False


def _load_artikelgroep_mapping(logger):
    """Laadt mapping-artikelgroepen.xml -> (Grp-map, naam-map, vlaggen-map) op SB-hoofdcategorie.id.

    Per hoofdcategorie ook de artikel-vlag voor FbItemArticle: Voorraad -> BiSt
    (ontbrekend/leeg/onbekend -> False). AdSr komt uit het SB-product (isSerialized).
    """
    import xml.etree.ElementTree as ET

    artikelgroep_map = {}      # SB hoofdcategorie.id -> AFAS artikelgroep-code (Grp)
    artikelgroep_naam_map = {}  # SB hoofdcategorie.id -> AFAS artikelgroep-omschrijving (logging)
    artikel_vlaggen_map = {}    # SB hoofdcategorie.id -> {"Voorraad": bool}
    root = ET.parse(MAPPING_FILE).getroot()
    for cat in root.findall("categorie"):
        main_cat_id = cat.get("SB-maincat-id")
        afas_id = cat.get("AFAS-id")
        if main_cat_id and afas_id and afas_id.strip():
            artikelgroep_map[main_cat_id] = afas_id
            artikelgroep_naam_map[main_cat_id] = cat.get("AFAS-naam")
            artikel_vlaggen_map[main_cat_id] = {
                "Voorraad": convert_to_config_bool(cat.get("Voorraad"), default=False),
            }
    logger.info(
        f"{len(artikelgroep_map)} artikelgroep-mapping(s) (SB-hoofdcategorie -> Grp) "
        "geladen uit mapping-artikelgroepen.xml"
    )
    return artikelgroep_map, artikelgroep_naam_map, artikel_vlaggen_map


def _load_leverancier_mapping(logger) -> dict:
    """Laadt mapping-leveranciers.xml -> SB supplier.name -> AFAS-crediteurcode.

    Sleutels in kleine letters (hoofdletterongevoelig, net als de PowerShell-hashtable);
    alleen leveranciers met een ingevulde AFAS-cred worden opgenomen.
    """
    import xml.etree.ElementTree as ET

    leverancier_map = {}
    root = ET.parse(LEVERANCIERS_FILE).getroot()
    for lev in root.findall("leverancier"):
        naam = (lev.get("SB-naam") or "").strip()
        cred = (lev.get("AFAS-cred") or "").strip()
        if naam and cred:
            leverancier_map[naam.lower()] = cred
    logger.info(
        f"{len(leverancier_map)} leverancier-mapping(s) (SB-leverancier -> AFAS-crediteur) "
        "geladen uit mapping-leveranciers.xml"
    )
    return leverancier_map


def run(logger: Logger, runlog: RunLog) -> None:
    """De volledige sync-run (vier flows) — mirror van het #region Hoofd-logica-blok."""

    if not os.path.isdir(CONFIG_DIR):
        os.makedirs(CONFIG_DIR, exist_ok=True)

    config = read_xml_config(CONFIG_FILE)

    # State: alle vier flow-watermerken staan als aparte knopen in één bestand.
    last_forecast_sync = get_sync_watermark(SYNC_STATE_FILE, "Flow1")
    last_items_sync = get_sync_watermark(SYNC_STATE_FILE, "Flow2")
    last_quotations_sync = get_sync_watermark(SYNC_STATE_FILE, "Flow3")
    last_attachment_sync = get_sync_watermark(SYNC_STATE_FILE, "Flow4")

    # Test-override: <OverrideDays>N</OverrideDays> laat alle flows syncen vanaf N dagen geleden.
    override_days = get_sync_override_days(find_text(config, "OverrideDays"), logger)
    if override_days is not None:
        override = override_date(override_days)
        last_forecast_sync = override
        last_items_sync = override
        last_quotations_sync = override
        last_attachment_sync = override
        logger.warning(
            f"OverrideDays actief ({override_days}): alle flows syncen vanaf {override.isoformat()}"
        )

    # Credentials, omgeving en MODE (plaintext uit config.xml).
    mode = find_text(config, "mode")
    afas_omgeving = find_text(config, "afas/omgeving")
    afas_token_live = find_text(config, "afas/token_live")
    afas_token_test = find_text(config, "afas/token_test")
    afas_api_token = afas_token_test if mode == "2" else afas_token_live
    salesbuildr_api_key = find_text(config, "salesbuildr/apikey")
    salesbuildr_url = find_text(config, "salesbuildr/url")

    # SB-hoofdcategorie 'Diensten' (regels zonder mpn). Ontbreekt -> bekende default.
    diensten_main_cat_id = find_text(config, "salesbuildr/diensten_maincategory_id").strip()
    if not diensten_main_cat_id:
        diensten_main_cat_id = "UyOpp42UPGy3LKgSOQGX"

    # Flow 4: dossieritemtype (StId) + AFAS-gebruiker (UsId) uit config; ontbrekend -> defaults.
    kn_subject_stid_raw = find_text(config, "afas/kn_subject_stid").strip()
    kn_subject_stid = int(kn_subject_stid_raw) if kn_subject_stid_raw else 46
    kn_subject_usid = find_text(config, "afas/kn_subject_usid").strip() or "53307._sa_salesbldr"

    # Test-klantfilter (mode 2): pas ná de credential-check bepaald.
    test_company_id_filter = None

    # Flow-schakelaars (<flows><flow1>..<flow4>). Ontbrekend -> aan.
    flow1_enabled = convert_to_config_bool(find_text(config, "flows/flow1") or None)
    flow2_enabled = convert_to_config_bool(find_text(config, "flows/flow2") or None)
    flow3_enabled = convert_to_config_bool(find_text(config, "flows/flow3") or None)
    flow4_enabled = convert_to_config_bool(find_text(config, "flows/flow4") or None)

    active_token_key = "afas.token_test" if mode == "2" else "afas.token_live"
    for key, value in (
        ("afas.omgeving", afas_omgeving),
        (active_token_key, afas_api_token),
        ("salesbuildr.apikey", salesbuildr_api_key),
        ("salesbuildr.url", salesbuildr_url),
    ):
        if not value or not value.strip():
            raise ValueError(f"Vereiste config.xml-waarde ontbreekt of is leeg: {key}")

    afas = AfasClient(afas_omgeving, afas_api_token, mode, logger)
    sb = SalesbuildrClient(salesbuildr_url, salesbuildr_api_key, logger)

    # Credential-check: lichte GET tegen beide API's. Beide worden gecontroleerd zodat je
    # in één run beide fouten ziet; een HTTP 401 breekt de run af (watermerken blijven staan).
    credentials_ok = True
    if not afas.test_connection():
        logger.warning(
            f"AFAS-token ongeldig (HTTP 401) — controleer {active_token_key} in config.xml; sync afgebroken"
        )
        credentials_ok = False
    if not sb.test_connection():
        logger.warning(
            "SalesBuildr API-key ongeldig (HTTP 401) — controleer salesbuildr/apikey in config.xml; sync afgebroken"
        )
        credentials_ok = False
    if not credentials_ok:
        return

    # Test-klant-id bepalen (mode 2): direct uit config, of één keer herleid uit de naam.
    if mode == "2":
        test_klant_id = find_text(config, "salesbuildr/test_klant_id").strip()
        if test_klant_id:
            test_company_id_filter = test_klant_id
            test_klant = sb.get_company_by_id(test_company_id_filter)
            test_klant_naam = test_klant.get("name") if test_klant else test_company_id_filter
            logger.warning(
                f"TEST-modus (mode 2): Flow 2/3/4 verwerken uitsluitend SB-klant '{test_klant_naam}'"
            )
        else:
            test_klant_naam = find_text(config, "salesbuildr/test_klant").strip() or "Big Pepper B.V."
            test_klant = sb.get_company_by_name(test_klant_naam)
            if test_klant is None:
                raise ValueError(
                    f"TEST-modus (mode 2): SB-klant '{test_klant_naam}' niet gevonden — kan "
                    "test-klantfilter niet bepalen. Zet <salesbuildr><test_klant_id> of "
                    "corrigeer <test_klant> in config.xml."
                )
            test_company_id_filter = test_klant.get("id")
            logger.warning(
                f"TEST-modus (mode 2): Flow 2/3/4 verwerken uitsluitend SB-klant '{test_klant_naam}'"
            )

    # AFAS connector-namen uit config (met fallback op de bekende namen).
    conn_forecast_get = find_text(config, "afas/connectors/forecasts_get")
    conn_forecast_update = find_text(config, "afas/connectors/forecasts_update")
    conn_artikelen_get = find_text(config, "afas/connectors/artikelen_get")
    conn_artikelen_update = find_text(config, "afas/connectors/artikelen_update")
    conn_voorcalc_get = find_text(config, "afas/connectors/voorcalculatie_get")
    conn_voorcalc_update = find_text(config, "afas/connectors/voorcalculatie_update")
    conn_dossier_get = find_text(config, "afas/connectors/dossieritems_get").strip() or "Salesbuildr_Dossieritems"
    conn_subject_update = find_text(config, "afas/connectors/subject_update").strip() or "KnSubject"

    # Mapping SB-hoofdcategorie -> AFAS artikelgroep (Grp).
    artikelgroep_map, artikelgroep_naam_map, artikel_vlaggen_map = _load_artikelgroep_mapping(logger)

    # Mapping SB leveranciersnaam (quote-regel supplier.name) -> AFAS-crediteurcode (Flow 3).
    leverancier_map = _load_leverancier_mapping(logger)

    # SB-categorieboom (voor hoofdcategorie-herleiding). Eén keer per run opgehaald.
    category_parent_map = sb.get_category_parent_map()
    logger.info(
        f"{len(category_parent_map)} SB-categorie(ën) opgehaald voor hoofdcategorie-herleiding"
    )

    # Zorg dat de vier flow-blokken in vaste volgorde (F1..F4) in log.txt komen.
    for key in ("F1", "F2", "F3", "F4"):
        runlog.bucket(FLOW_LABELS[key])

    flow1_complete = True
    flow2_complete = True
    flow3_complete = True
    flow4_complete = True

    # ────────────────────────────────────────────────────────────────────────
    # FLOW 1 — AFAS Forecasts -> Salesbuildr Opportunities
    # ────────────────────────────────────────────────────────────────────────
    runlog.current_flow = FLOW_LABELS["F1"]
    if not flow1_enabled:
        logger.info("=== Flow 1 is uitgeschakeld in config.xml (flows/flow1) — overgeslagen ===")
    else:
        logger.info("=== Flow 1: AFAS Forecasts → SalesBuildr Opportunities ===")
        logger.info(f"Delta sinds: {last_forecast_sync.isoformat()}")

        forecasts = afas.get_connector_filtered(conn_forecast_get, last_forecast_sync)
        logger.info(f"{len(forecasts)} gewijzigde Forecasts gevonden")

        for forecast in forecasts:
            logger.info(
                f"[Flow 1] Forecast {forecast.get('forecast')} | "
                f"'{forecast.get('forecastOmschrijving')}' | "
                f"verkooprelatie {forecast.get('verkooprelatie')} | "
                f"volgnummer {forecast.get('volgnummer')}"
            )

            external_id = (
                f"afas-Forecast-{forecast.get('forecast')}-"
                f"{forecast.get('volgnummer')}-{forecast.get('verkooprelatie')}"
            )
            company_ext_id = f"afas-Organisatie-{forecast.get('organisatie')}"

            company = sb.get_company_by_ext_id(company_ext_id)
            if company is None:
                logger.warning(
                    f"[Flow 1] Organisatie {forecast.get('organisatie')} niet gevonden in "
                    f"SalesBuildr ({company_ext_id}) — Forecast "
                    f"'{forecast.get('forecastOmschrijving')}' overgeslagen"
                )
                flow1_complete = False
                continue

            existing_opportunity = sb.get_opportunity_by_ext_id(external_id)
            if existing_opportunity is not None and existing_opportunity.get("statusId") in ("closed", "lost"):
                logger.info(
                    f"[Flow 1] Opportunity al gesloten in SalesBuildr ({external_id}) — overgeslagen"
                )
                continue

            # Klant-contactpersoon: opzoeken op e-mail. Contact is VERPLICHT.
            contact_id = None
            mail = forecast.get("contactpersoonMail")
            if mail and str(mail).strip():
                contact = sb.get_contact_by_email(mail, company.get("id"))
                if contact is not None:
                    contact_id = contact.get("id")
                    logger.info(f"[Flow 1] Contact gevonden op {mail} (id: {contact_id})")
            if contact_id is None:
                logger.warning(
                    f"[Flow 1] Geen SalesBuildr-contact gevonden bij organisatie "
                    f"{forecast.get('organisatie')} ({company_ext_id}) voor Forecast "
                    f"'{forecast.get('forecastOmschrijving')}' (e-mail '{mail}') — overgeslagen"
                )
                flow1_complete = False
                continue

            opportunity_body = {
                "name": forecast.get("forecastOmschrijving"),
                "companyExtId": company_ext_id,
                # AFAS scoringkans is 0–100; SB probability is een fractie 0–1.
                "probability": float(forecast.get("scoringkans") or 0) / 100,
                "onetimeRevenue": forecast.get("bedragVerwacht"),
                # Owner is VERPLICHT; de GetConnector levert de SB user-id direct aan.
                "ownerId": forecast.get("verantwoordelijkeOwnerID"),
                "contactId": contact_id,
            }
            einddatum = forecast.get("einddatumVerwacht")
            if einddatum is not None:
                from datetime import datetime as _dt

                opportunity_body["expectedCloseDate"] = _dt.fromisoformat(str(einddatum)).strftime("%Y-%m-%d")

            logger.info(
                f"[Flow 1] Opportunity upsert in SalesBuildr: {external_id} "
                f"('{forecast.get('forecastOmschrijving')}')"
            )
            try:
                sb.upsert_opportunity(external_id, opportunity_body)
                runlog.add_created(
                    f"Opportunity upsert: {external_id} ('{forecast.get('forecastOmschrijving')}')"
                )
            except Exception as exc:  # noqa: BLE001
                logger.error(
                    f"[Flow 1] Fout bij upsert Opportunity '{forecast.get('forecastOmschrijving')}': {exc}"
                )
                flow1_complete = False

    # ────────────────────────────────────────────────────────────────────────
    # FLOW 2 — Items: gewonnen SB-quotations -> ontbrekende artikelen in AFAS
    # ────────────────────────────────────────────────────────────────────────
    runlog.current_flow = FLOW_LABELS["F2"]
    if not flow2_enabled:
        logger.info("=== Flow 2 is uitgeschakeld in config.xml (flows/flow2) — overgeslagen ===")
    else:
        logger.info("=== Flow 2: Items — gewonnen SB-quotations → AFAS-artikelen ===")
        logger.info(f"Delta sinds: {last_items_sync.isoformat()}")

        closed_opportunities = sb.get_closed_opportunities(last_items_sync, test_company_id_filter)
        logger.info(f"{len(closed_opportunities)} gesloten Opportunities gevonden")

        if AFAS_WRITES_ON_HOLD_2:
            logger.warning(
                "Flow 2: AFAS-schrijfacties staan ON HOLD — geen artikelen aangemaakt. "
                "Watermerk wordt niet opgeschoven."
            )
            flow2_complete = False

        outcome = sb.split_closed_opportunities(closed_opportunities, "Flow 2")
        if not outcome.all_ok:
            flow2_complete = False
        logger.info(f"Categorisatie: {len(outcome.won)} Won, {len(outcome.lost)} Lost")

        all_won_lines = [line for lines in outcome.lines.values() for line in lines]
        line_resolution = {
            line["id"]: resolve_afas_line_item(line, sb, category_parent_map, diensten_main_cat_id)
            for line in all_won_lines
        }

        all_item_codes = sorted(
            {res["ItemCode"] for res in line_resolution.values() if res and res["Kind"] == "artikel"}
        )
        logger.info(
            f"{len(all_item_codes)} unieke artikelcode(s) (mpn) gevonden in de gewonnen quotations"
        )

        for item_code in all_item_codes:
            bron_regel = next((line for line in all_won_lines if line.get("mpn") == item_code), None)

            category = bron_regel.get("category") or {} if bron_regel else {}
            sb_cat_id = category.get("id")
            sb_cat_naam = category.get("name")
            main_cat_id = get_salesbuildr_main_category_id(sb_cat_id, category_parent_map)
            artikelgroep = get_afas_artikelgroep(
                bron_regel.get("category") if bron_regel else None, artikelgroep_map, category_parent_map
            )

            bestaat_in_afas = afas.get_artikel_by_itemcode(conn_artikelen_get, item_code) is not None
            if bestaat_in_afas:
                logger.info(f"Artikel [{item_code}] bestaat al in AFAS — overgeslagen")
                continue

            if not artikelgroep or not str(artikelgroep).strip():
                logger.warning(
                    f"Artikel [{item_code}] overgeslagen: categorie '{sb_cat_naam}' (id {sb_cat_id}, "
                    f"hoofdcategorie {main_cat_id if main_cat_id else 'onbekend'}) niet gemapt in "
                    "mapping-artikelgroepen.xml"
                )
                flow2_complete = False
                continue

            if AFAS_WRITES_ON_HOLD_2:
                logger.warning(
                    f"[ON HOLD] Artikel [{item_code}] zou aangemaakt worden (groep {artikelgroep}) — niet aangemaakt"
                )
                continue

            # Grp is hierboven gevonden, dus main_cat_id staat in de mapping.
            voorraad = artikel_vlaggen_map[main_cat_id]["Voorraad"]

            try:
                # AdSr volgt het SB-product (isSerialized), niet de categorie-mapping.
                serienummer = sb.get_product_is_serialized(bron_regel)
                afas.new_artikel(
                    conn_artikelen_update, item_code, bron_regel.get("name"), artikelgroep,
                    voorraad, serienummer,
                )
                runlog.add_created(
                    f"Artikel: {item_code} ('{bron_regel.get('name')}', artikelgroep {artikelgroep}, "
                    f"voorraad {voorraad}, serienummer {serienummer})"
                )
            except Exception as exc:  # noqa: BLE001
                logger.error(f"Fout bij aanmaken Artikel [{item_code}]: {exc}")
                flow2_complete = False

    # ────────────────────────────────────────────────────────────────────────
    # FLOW 3 — Quotations: gewonnen SB-quotations -> AFAS-quotation (voorcalculatie)
    # ────────────────────────────────────────────────────────────────────────
    runlog.current_flow = FLOW_LABELS["F3"]
    if not flow3_enabled:
        logger.info("=== Flow 3 is uitgeschakeld in config.xml (flows/flow3) — overgeslagen ===")
    else:
        logger.info("=== Flow 3: Quotations — gewonnen SB-quotations → AFAS-quotation ===")
        logger.info(f"Delta sinds: {last_quotations_sync.isoformat()}")

        closed_opportunities = sb.get_closed_opportunities(last_quotations_sync, test_company_id_filter)
        logger.info(f"{len(closed_opportunities)} gesloten Opportunities gevonden")

        if AFAS_WRITES_ON_HOLD_3:
            logger.warning(
                "Flow 3: AFAS-schrijfacties staan ON HOLD — geen quotations/Forecast-updates. "
                "Watermerk wordt niet opgeschoven."
            )
            flow3_complete = False

        # Stap 3a: categoriseren.
        outcome = sb.split_closed_opportunities(closed_opportunities, "Flow 3")
        if not outcome.all_ok:
            flow3_complete = False

        won_opportunities = outcome.won
        lost_opportunities = outcome.lost
        won_quote_lines = outcome.lines
        won_quote_titles = outcome.titles
        won_quotes = outcome.quotes
        logger.info(
            f"Categorisatie: {len(won_opportunities)} Won (G), {len(lost_opportunities)} Lost (N)"
        )

        # Stap 3b: regels resolven + AFAS-beschikbaarheid bepalen (alleen Won).
        all_won_lines = [line for lines in won_quote_lines.values() for line in lines]
        line_resolution = {
            line["id"]: resolve_afas_line_item(line, sb, category_parent_map, diensten_main_cat_id)
            for line in all_won_lines
        }

        # Diensten: NOOIT aanmaken; per unieke, niet-lege internalProductId bestaanscontrole.
        diensten_exists = {}
        diensten_codes = sorted(
            {
                res["ItemCode"]
                for res in line_resolution.values()
                if res and res["Kind"] == "diensten" and res["ItemCode"] and res["ItemCode"].strip()
            }
        )
        for code in diensten_codes:
            bestaat = afas.get_artikel_by_itemcode(conn_artikelen_get, code) is not None
            diensten_exists[code] = bestaat
            kind = "werksoort-regel (VaIt=1)" if bestaat else "TXT-regel"
            logger.info(
                f"[Flow 3] Dienst [internalProductId {code}] | bestaat in AFAS: {bestaat} -> {kind}"
            )

        # Artikelen: elk uniek mpn MOET in AFAS bestaan (aangemaakt door Flow 2).
        failed_item_codes = []
        all_item_codes = sorted(
            {res["ItemCode"] for res in line_resolution.values() if res and res["Kind"] == "artikel"}
        )
        for item_code in all_item_codes:
            if afas.get_artikel_by_itemcode(conn_artikelen_get, item_code) is None:
                logger.warning(
                    f"[Flow 3] Artikel [{item_code}] bestaat niet in AFAS (nog niet aangemaakt "
                    "door Flow 2?) — opportunities met dit artikel worden overgeslagen"
                )
                failed_item_codes.append(item_code)

        # Leverancier -> AFAS-crediteurcode (vrije velden op ELKE regel met een leverancier,
        # ook TXT-regels), via supplier.name en mapping-leveranciers.xml. Een niet-gemapte
        # leverancier is GEEN fout: WARNING (één keer per naam), beide velden worden op die
        # regels weggelaten (geen skip, geen watermerk-hold).
        supplier_names = {}
        for line in all_won_lines:
            naam = get_line_supplier_name(line)
            if naam:
                supplier_names.setdefault(naam.lower(), naam)
        for key in sorted(supplier_names):
            naam = supplier_names[key]
            if key in leverancier_map:
                logger.info(f"[Flow 3] Leverancier '{naam}' -> AFAS-crediteur {leverancier_map[key]}")
            else:
                logger.warning(
                    f"[Flow 3] Leverancier '{naam}' niet gemapt in mapping-leveranciers.xml — "
                    "crediteurvelden worden weggelaten op regels met deze leverancier"
                )

        # Stap 3c: bestaande AFAS-quotation (KnQuotation, voorcalculatie) bijwerken per Won-Opportunity.
        for opportunity in won_opportunities:
            opportunity_id = opportunity.get("id")

            forecast_key = parse_forecast_external_id(opportunity.get("externalIdentifier"))
            if forecast_key is None:
                logger.error(
                    f"[{opportunity_id}] Onverwacht externalIdentifier-formaat "
                    f"'{opportunity.get('externalIdentifier')}' — kan forecast-id/PrId/SqNo niet "
                    "parsen, overgeslagen"
                )
                flow3_complete = False
                continue

            lines = won_quote_lines[opportunity_id]

            # Idempotentie via de Forecast-status: het toevoegen van voorcalculatieregels
            # (PUT met @Action=insert) is NIET idempotent. G/N = al gesloten -> overslaan.
            afas_forecast = afas.get_forecast(conn_forecast_get, forecast_key.forecast_id)
            if afas_forecast is None:
                logger.warning(
                    f"[{opportunity_id}] Forecast {forecast_key.forecast_id} niet gevonden in "
                    f"{conn_forecast_get} — overgeslagen, watermerk vastgehouden"
                )
                flow3_complete = False
                continue
            # O = open -> doorgaan. Elke andere (of lege) waarde is onverwacht: overslaan +
            # watermerk vasthouden i.p.v. gokken (doorgaan kan dubbele regels opleveren).
            status_code = get_forecast_status_code(afas_forecast)
            logger.info(
                f"[{opportunity_id}] Forecast {forecast_key.forecast_id} | statusCode "
                f"'{status_code}' ({afas_forecast.get('status')})"
            )
            if status_code in ("G", "N"):
                logger.info(
                    f"[{opportunity_id}] Forecast {forecast_key.forecast_id} is al gesloten "
                    f"(statusCode {status_code}) — geen voorcalculatieregels toegevoegd, overgeslagen"
                )
                continue
            if status_code != "O":
                logger.warning(
                    f"[{opportunity_id}] Forecast {forecast_key.forecast_id} heeft onverwachte "
                    f"statusCode '{status_code}' (verwacht O/G/N) — overgeslagen, watermerk vastgehouden"
                )
                flow3_complete = False
                continue

            # Voorcalculatienummer in AFAS = SB-offertenummer (QuoteResponseDto.number),
            # bijv. "2026-00380".
            voorcalc_id = str(won_quotes[opportunity_id].get("number") or "").strip()
            if not voorcalc_id:
                logger.warning(
                    f"[{opportunity_id}] Primaire SB-quote heeft geen offertenummer — "
                    "voorcalculatienummer onbekend, overgeslagen, watermerk vastgehouden"
                )
                flow3_complete = False
                continue

            # De hoofd-voorcalculatie wordt in AFAS aangemaakt. We controleren NIET vooraf of
            # hij bestaat: de PUT KnQuotation hieronder werkt hem "blind" bij. Faalt die PUT,
            # dan wordt PAS DAN gecontroleerd of hij bestaat.

            # Onmapbare regel of artikel dat niet in AFAS bestaat -> HELE opportunity
            # overslaan. Diensten- en abonnementsregels veroorzaken NOOIT een skip.
            probleemregels = []
            for line in lines:
                res = line_resolution[line["id"]]
                if res is None:
                    probleemregels.append(
                        f"regel '{line.get('name')}' (geen mpn en niet in hoofdcategorie Diensten)"
                    )
                elif res["Kind"] == "artikel" and res["ItemCode"] in failed_item_codes:
                    probleemregels.append(
                        f"{res['Kind']} '{res['ItemCode']}' (niet beschikbaar in AFAS)"
                    )
            if probleemregels:
                logger.warning(
                    f"[{opportunity_id}] Overgeslagen (quotation niet bijgewerkt, Forecast "
                    f"blijft open): {'; '.join(probleemregels)}"
                )
                flow3_complete = False
                continue

            regels = []
            for line in lines:
                res = line_resolution[line["id"]]
                # shortDescription (omschrijving op de SB-quoteregel) gaat — indien gevuld —
                # als Ds mee op de voorcalculatieregel; anders de regelnaam (TXT) of de
                # AFAS-standaardomschrijving van het item (werksoort/artikel, Ds weggelaten).
                korte_omschrijving = (line.get("shortDescription") or "").strip() or None
                regel_tekst = korte_omschrijving or line.get("name")
                # AFAS-crediteurcode van de leverancier (mapping-leveranciers.xml), of None ->
                # crediteurvelden weggelaten. Geldt voor ELKE regelsoort (artikel, werksoort, TXT).
                supplier_name = get_line_supplier_name(line)
                regel_cred_code = leverancier_map.get(supplier_name.lower()) if supplier_name else None

                if res["Kind"] == "abonnement":
                    # === Abonnement -> ALTIJD TXT-regel, met de termijn in de omschrijving ===
                    regels.append(
                        {
                            "Kind": "txt",
                            "ItemCode": "SBA",
                            "Tekst": regel_tekst,
                            "Aantal": line.get("quantity"),
                            "Prijs": line.get("price"),
                            "Kostprijs": line.get("cost"),
                            "Termijn": res["Term"],
                            "CredCode": regel_cred_code,
                        }
                    )
                elif res["Kind"] == "diensten":
                    code_bestaat = bool(res["ItemCode"] and res["ItemCode"].strip()) and diensten_exists.get(res["ItemCode"], False)
                    if code_bestaat:
                        # === Werksoort-regel ===
                        regels.append(
                            {
                                "ItemCode": res["ItemCode"],
                                "Soort": "1",
                                "Omschrijving": korte_omschrijving,
                                "Aantal": line.get("quantity"),
                                "Prijs": line.get("price"),
                                "Kostprijs": line.get("cost"),
                                "CredCode": regel_cred_code,
                            }
                        )
                    else:
                        # === TXT-regel ===
                        regels.append(
                            {
                                "Kind": "txt",
                                "Tekst": regel_tekst,
                                "Aantal": line.get("quantity"),
                                "Prijs": line.get("price"),
                                "Kostprijs": line.get("cost"),
                                "CredCode": regel_cred_code,
                            }
                        )
                else:
                    # Artikel (mpn, VaIt=2).
                    regels.append(
                        {
                            "ItemCode": res["ItemCode"],
                            "Soort": res["VaIt"],
                            "Omschrijving": korte_omschrijving,
                            "Aantal": line.get("quantity"),
                            "Prijs": line.get("price"),
                            "Kostprijs": line.get("cost"),
                            "CredCode": regel_cred_code,
                        }
                    )

            if AFAS_WRITES_ON_HOLD_3:
                payload = to_json(
                    build_quotation_body(
                        voorcalc_id,
                        won_quote_titles[opportunity_id],
                        regels,
                        won_quotes[opportunity_id].get("poNumber"),
                    )
                )
                logger.warning(
                    f"[ON HOLD] [{opportunity_id}] AFAS-quotation ({voorcalc_id}) zou bijgewerkt "
                    f"worden met {len(regels)} regel(s) — niet bijgewerkt. Payload: {payload}"
                )
            else:
                try:
                    afas.update_quotation(
                        conn_voorcalc_update,
                        voorcalc_id,
                        won_quote_titles[opportunity_id],
                        regels,
                        won_quotes[opportunity_id].get("poNumber"),
                    )
                    runlog.add_created(
                        f"AFAS-quotation bijgewerkt: offerte {voorcalc_id} (Forecast "
                        f"{forecast_key.forecast_id}, SqNo {forecast_key.sqno}, {len(regels)} "
                        "regel(s) toegevoegd)"
                    )
                except Exception as exc:  # noqa: BLE001
                    afas_error = afas_error_text(exc)
                    # De AFAS-foutmelding zegt niet eenduidig WAT er niet bestaat ("bestaat niet"
                    # kan ook over een Itemcode op een regel gaan). Daarom pas NA een mislukte
                    # PUT controleren of de hoofd-voorcalculatie zelf bestaat.
                    voorcalc_bestaat = None
                    try:
                        voorcalc_bestaat = afas.get_quotation(conn_voorcalc_get, voorcalc_id) is not None
                    except Exception:  # noqa: BLE001
                        pass
                    regel_codes = ", ".join(
                        f"{r.get('ItemCode') or 'SBO'} (VaIt 3)"
                        if r.get("Kind") == "txt"
                        else f"{r.get('ItemCode')} (VaIt {r.get('Soort')})"
                        for r in regels
                    )
                    if voorcalc_bestaat is False:
                        logger.warning(
                            f"[{opportunity_id}] Hoofd-voorcalculatie ({voorcalc_id}) bestaat niet in "
                            "AFAS — overgeslagen (Forecast blijft open), watermerk vastgehouden"
                        )
                    else:
                        logger.error(
                            f"[{opportunity_id}] Fout bij bijwerken AFAS-quotation ({voorcalc_id}), "
                            f"regels: {regel_codes} — AFAS-melding: {afas_error}"
                        )
                    flow3_complete = False
                    continue

            # Sluiten van de Won-Forecast (ViOp=G).
            # LET OP: de regels zijn nu toegevoegd. Faalt het sluiten hieronder, dan voegt de
            # volgende run de regels OPNIEUW toe (dubbele regels) — handmatig nakijken.
            if AFAS_WRITES_ON_HOLD_3:
                logger.warning(
                    f"[ON HOLD] [{opportunity_id}] Forecast [SqNo {forecast_key.sqno}] zou als Won (G) "
                    f"gesloten worden (OrAF {sb.get_quote_total(lines)}) — niet gesloten"
                )
                continue

            oraf = sb.get_quote_total(lines)
            try:
                afas.close_forecast(
                    conn_forecast_update, forecast_key.prid, forecast_key.sqno, "G", oraf
                )
                runlog.add_created(
                    f"Forecast gesloten WON (G): PrId {forecast_key.prid} / SqNo {forecast_key.sqno} (OrAF {oraf})"
                )
            except Exception as exc:  # noqa: BLE001
                logger.error(
                    f"[{opportunity_id}] Fout bij sluiten Forecast [SqNo {forecast_key.sqno}] als Won (G) in AFAS: {exc}"
                )
                flow3_complete = False
                continue

        # Stap 3d: Lost-Opportunities — alleen de AFAS Forecast op N sluiten.
        # Zonder externalIdentifier komt de Opportunity niet uit AFAS -> INFO, geen hold.
        # Idempotentie via de Forecast-status: een 'lost'-Opportunity wordt opnieuw opgehaald
        # zodra zijn updatedAt verspringt, dus een al gesloten Forecast (G/N) slaan we over.
        for opportunity in lost_opportunities:
            opportunity_id = opportunity.get("id")

            if not str(opportunity.get("externalIdentifier") or "").strip():
                logger.info(
                    f"[{opportunity_id}] Lost-Opportunity zonder externalIdentifier (niet uit AFAS) — "
                    "geen Forecast te sluiten, overgeslagen"
                )
                continue

            forecast_key = parse_forecast_external_id(opportunity.get("externalIdentifier"))
            if forecast_key is None:
                logger.error(
                    f"[{opportunity_id}] Onverwacht externalIdentifier-formaat "
                    f"'{opportunity.get('externalIdentifier')}' — kan PrId/SqNo niet parsen, overgeslagen"
                )
                flow3_complete = False
                continue

            try:
                afas_forecast = afas.get_forecast(conn_forecast_get, forecast_key.forecast_id)
            except Exception as exc:  # noqa: BLE001
                logger.error(
                    f"[{opportunity_id}] Fout bij ophalen Forecast {forecast_key.forecast_id} uit AFAS: {exc}"
                )
                flow3_complete = False
                continue
            if afas_forecast is None:
                logger.warning(
                    f"[{opportunity_id}] Forecast {forecast_key.forecast_id} niet gevonden in "
                    f"{conn_forecast_get} — overgeslagen, watermerk vastgehouden"
                )
                flow3_complete = False
                continue
            status_code = get_forecast_status_code(afas_forecast)
            if status_code in ("G", "N"):
                logger.info(
                    f"[{opportunity_id}] Forecast {forecast_key.forecast_id} is al gesloten "
                    f"(statusCode {status_code}) — overgeslagen"
                )
                continue
            if status_code != "O":
                logger.warning(
                    f"[{opportunity_id}] Forecast {forecast_key.forecast_id} heeft onverwachte "
                    f"statusCode '{status_code}' (verwacht O/G/N) — overgeslagen, watermerk vastgehouden"
                )
                flow3_complete = False
                continue

            if AFAS_WRITES_ON_HOLD_3:
                logger.warning(
                    f"[ON HOLD] [{opportunity_id}] Forecast [SqNo {forecast_key.sqno}] zou als Lost (N) "
                    "gesloten worden — niet gesloten"
                )
                continue

            try:
                afas.close_forecast(conn_forecast_update, forecast_key.prid, forecast_key.sqno, "N")
                runlog.add_created(
                    f"Forecast gesloten LOST (N): PrId {forecast_key.prid} / SqNo {forecast_key.sqno}"
                )
            except Exception as exc:  # noqa: BLE001
                logger.error(
                    f"[{opportunity_id}] Fout bij sluiten Forecast [SqNo {forecast_key.sqno}] als Lost (N) in AFAS: {exc}"
                )
                flow3_complete = False

    # ────────────────────────────────────────────────────────────────────────
    # FLOW 4 — Salesbuildr quote-PDF -> AFAS dossieritem (KnSubject)
    # ────────────────────────────────────────────────────────────────────────
    runlog.current_flow = FLOW_LABELS["F4"]
    if not flow4_enabled:
        logger.info("=== Flow 4 is uitgeschakeld in config.xml (flows/flow4) — overgeslagen ===")
    else:
        logger.info("=== Flow 4: SalesBuildr quote-PDF → AFAS dossieritem ===")
        logger.info(f"Delta sinds: {last_attachment_sync.isoformat()}")

        closed_opportunities = sb.get_closed_opportunities(last_attachment_sync, test_company_id_filter)
        logger.info(f"{len(closed_opportunities)} gesloten Opportunities gevonden")

        if AFAS_WRITES_ON_HOLD_4:
            logger.warning(
                "Flow 4: AFAS-schrijfacties staan ON HOLD — geen dossieritems; alleen ophalen + "
                "inspectie. Watermerk wordt niet opgeschoven."
            )
            flow4_complete = False

        outcome = sb.split_closed_opportunities(closed_opportunities, "Flow 4")
        if not outcome.all_ok:
            flow4_complete = False
        logger.info(
            f"Categorisatie: {len(outcome.won)} Won (PDF), {len(outcome.lost)} Lost (geen PDF)"
        )

        for opportunity in outcome.won:
            opportunity_id = opportunity.get("id")
            quote_obj = outcome.quotes[opportunity_id]

            forecast_key = parse_forecast_external_id(opportunity.get("externalIdentifier"))
            if forecast_key is None:
                logger.error(
                    f"[{opportunity_id}] Onverwacht externalIdentifier-formaat "
                    f"'{opportunity.get('externalIdentifier')}' — overgeslagen"
                )
                flow4_complete = False
                continue

            # Voorcalculatienummer in AFAS = SB-offertenummer (QuoteResponseDto.number).
            voorcalc_id = str(quote_obj.get("number") or "").strip()
            if not voorcalc_id:
                logger.warning(
                    f"[{opportunity_id}] Primaire SB-quote heeft geen offertenummer — "
                    "voorcalculatienummer onbekend, overgeslagen, watermerk vastgehouden"
                )
                flow4_complete = False
                continue

            # Precondiitie: de AFAS-quotation moet al bestaan.
            if afas.get_quotation(conn_voorcalc_get, voorcalc_id) is None:
                logger.warning(
                    f"[{opportunity_id}] AFAS-quotation ({voorcalc_id}) bestaat nog niet "
                    "— PDF nog niet gekoppeld, watermerk vastgehouden voor herkansing"
                )
                flow4_complete = False
                continue

            # Idempotentie: hangt de PDF er al?
            if afas.get_quotation_attachment(conn_dossier_get, voorcalc_id, kn_subject_stid):
                logger.info(
                    f"[{opportunity_id}] PDF-bijlage al aanwezig bij offerte {voorcalc_id} — overgeslagen"
                )
                continue

            # PDF ophalen (Base64).
            try:
                pdf_base64 = sb.get_quote_pdf(quote_obj.get("id"))
            except Exception as exc:  # noqa: BLE001
                logger.error(
                    f"[{opportunity_id}] Fout bij ophalen SB-quote-PDF ({quote_obj.get('id')}): {exc}"
                )
                flow4_complete = False
                continue
            if pdf_base64 is None:
                logger.warning(
                    f"[{opportunity_id}] Geen PDF beschikbaar voor SB-quote {quote_obj.get('id')} — "
                    "overgeslagen, watermerk vastgehouden"
                )
                flow4_complete = False
                continue

            file_name = f"SB-Offerte-{voorcalc_id}.pdf"

            if AFAS_WRITES_ON_HOLD_4:
                logger.warning(
                    f"[ON HOLD] [{opportunity_id}] Dossieritem '{file_name}' zou aangemaakt worden bij "
                    f"offerte {voorcalc_id} — niet aangemaakt"
                )
                continue

            try:
                afas.new_subject_attachment(
                    conn_subject_update,
                    kn_subject_stid,
                    kn_subject_usid,
                    voorcalc_id,
                    forecast_key.prid,
                    file_name,
                    pdf_base64,
                )
                runlog.add_created(
                    f"PDF-bijlage: '{file_name}' bij offerte {voorcalc_id} "
                    f"(verkooprelatie {forecast_key.prid})"
                )
            except Exception as exc:  # noqa: BLE001
                logger.error(f"[{opportunity_id}] Fout bij aanmaken dossieritem (KnSubject): {exc}")
                flow4_complete = False
                continue

    # ────────────────────────────────────────────────────────────────────────
    # State bijwerken (per flow: alleen opschuiven als aan én volledig verwerkt)
    # ────────────────────────────────────────────────────────────────────────
    from datetime import datetime as _dt

    def _update_state(name, enabled, complete, flow_key, ok_msg, incomplete_msg):
        if not enabled:
            logger.info(f"{name} uitgeschakeld — state ongewijzigd")
        elif complete:
            set_sync_watermark(SYNC_STATE_FILE, flow_key, _dt.now().astimezone())
            logger.info(f"{name} state bijgewerkt")
        else:
            logger.warning(incomplete_msg)

    _update_state(
        "Flow 1", flow1_enabled, flow1_complete, "Flow1", None,
        "Flow 1 state NIET bijgewerkt — niet alle Forecasts verwerkt; wordt opnieuw geprobeerd bij volgende run",
    )
    runlog.set_flow_status(FLOW_LABELS["F1"], flow1_enabled, flow1_enabled and flow1_complete)

    _update_state(
        "Flow 2", flow2_enabled, flow2_complete, "Flow2", None,
        "Flow 2 state NIET bijgewerkt — niet alle artikelen aangemaakt; wordt opnieuw geprobeerd bij volgende run",
    )
    runlog.set_flow_status(FLOW_LABELS["F2"], flow2_enabled, flow2_enabled and flow2_complete)

    _update_state(
        "Flow 3", flow3_enabled, flow3_complete, "Flow3", None,
        "Flow 3 state NIET bijgewerkt — niet alle quotations verwerkt; wordt opnieuw geprobeerd bij volgende run",
    )
    runlog.set_flow_status(FLOW_LABELS["F3"], flow3_enabled, flow3_enabled and flow3_complete)

    _update_state(
        "Flow 4", flow4_enabled, flow4_complete, "Flow4", None,
        "Flow 4 state NIET bijgewerkt — niet alle PDF's gekoppeld; wordt opnieuw geprobeerd bij volgende run",
    )
    runlog.set_flow_status(FLOW_LABELS["F4"], flow4_enabled, flow4_enabled and flow4_complete)


def main() -> int:
    runlog = RunLog()
    logger = Logger(runlog)
    try:
        run(logger, runlog)
    except Exception as exc:  # noqa: BLE001 - fatale fout niet laten crashen vóór het logboek
        logger.error(f"Fatale fout: {exc}")
    finally:
        # Samenvattend run-logblok wegschrijven (nieuwste bovenaan). In een finally zodat
        # ook een fatale fout of een afgebroken credential-check nog een blok oplevert.
        runlog.write_file(LOG_FILE)
    return 0


if __name__ == "__main__":
    sys.exit(main())
