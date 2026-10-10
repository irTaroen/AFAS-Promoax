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

from promax_sync.afas import AfasClient  # noqa: E402
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
    parse_forecast_external_id,
)
from promax_sync.logging_util import FLOW_LABELS, Logger, RunLog  # noqa: E402
from promax_sync.salesbuildr import (  # noqa: E402
    SalesbuildrClient,
    get_afas_artikelgroep,
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
LOG_FILE = os.path.join(PROJECT_ROOT, "logs", "log.txt")

# Dry-run-schakelaars per flow (hardcoded, net als in de PowerShell-versie). Op True
# gezet fetch/categoriseert de flow wél, maar slaat elke AFAS-write over en houdt het
# watermerk vast — zo kun je een flow inspecteren zonder AFAS te muteren.
AFAS_WRITES_ON_HOLD_2 = False
AFAS_WRITES_ON_HOLD_3 = False
AFAS_WRITES_ON_HOLD_4 = False


def _load_artikelgroep_mapping(logger):
    """Laadt mapping-artikelgroepen.xml -> (Grp-map, naam-map) op SB-hoofdcategorie.id."""
    import xml.etree.ElementTree as ET

    artikelgroep_map = {}      # SB hoofdcategorie.id -> AFAS artikelgroep-code (Grp)
    artikelgroep_naam_map = {}  # SB hoofdcategorie.id -> AFAS artikelgroep-omschrijving (logging)
    root = ET.parse(MAPPING_FILE).getroot()
    for cat in root.findall("categorie"):
        main_cat_id = cat.get("SB-maincat-id")
        afas_id = cat.get("AFAS-id")
        if main_cat_id and afas_id and afas_id.strip():
            artikelgroep_map[main_cat_id] = afas_id
            artikelgroep_naam_map[main_cat_id] = cat.get("AFAS-naam")
    logger.info(
        f"{len(artikelgroep_map)} artikelgroep-mapping(s) (SB-hoofdcategorie -> Grp) "
        "geladen uit mapping-artikelgroepen.xml"
    )
    return artikelgroep_map, artikelgroep_naam_map


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
    conn_debcred_get = find_text(config, "afas/connectors/debcred_get").strip() or "Salesbuildr_DebiteurenCrediteuren"

    # Mapping SB-hoofdcategorie -> AFAS artikelgroep (Grp).
    artikelgroep_map, artikelgroep_naam_map = _load_artikelgroep_mapping(logger)

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
            if existing_opportunity is not None and existing_opportunity.get("statusId") == "closed":
                logger.info(
                    f"[Flow 1] Opportunity al gesloten in SalesBuildr ({external_id}) — overgeslagen"
                )
                continue

            # Klant-contactpersoon: opzoeken op e-mail. Contact is VERPLICHT.
            contact_id = None
            mail = forecast.get("contactpersoonMail")
            if mail and str(mail).strip():
                contact = sb.get_contact_by_email(mail)
                if contact is not None:
                    contact_id = contact.get("id")
                    logger.info(f"[Flow 1] Contact gevonden op {mail} (id: {contact_id})")
            if contact_id is None:
                logger.warning(
                    f"[Flow 1] Geen SalesBuildr-contact gevonden voor Forecast "
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
            from promax_sync.helpers import get_salesbuildr_main_category_id

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

            try:
                afas.new_artikel(
                    conn_artikelen_update, item_code, bron_regel.get("name"), artikelgroep
                )
                runlog.add_created(
                    f"Artikel: {item_code} ('{bron_regel.get('name')}', artikelgroep {artikelgroep})"
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

        # Leverancier -> AFAS-inkooprelatie (vrij veld op artikelregels).
        line_vendor_ext_id = {}
        for line in all_won_lines:
            res = line_resolution[line["id"]]
            if res and res["Kind"] == "artikel":
                line_vendor_ext_id[line["id"]] = sb.get_line_vendor_external_id(line)

        inkooprelatie_map = {}
        vendor_ext_ids = sorted(
            {v for v in line_vendor_ext_id.values() if v and str(v).strip()}
        )
        for vendor_ext_id in vendor_ext_ids:
            inkooprelatie = afas.get_inkooprelatie(conn_debcred_get, vendor_ext_id)
            inkooprelatie_map[vendor_ext_id] = inkooprelatie
            if inkooprelatie is None:
                logger.warning(
                    f"[Flow 3] Leverancier (Nummer {vendor_ext_id}) niet gevonden in "
                    f"{conn_debcred_get} of zonder inkooprelatie — vrij veld inkooprelatie wordt "
                    "weggelaten op regels met deze leverancier"
                )
            else:
                logger.info(f"[Flow 3] Leverancier (Nummer {vendor_ext_id}) -> inkooprelatie {inkooprelatie}")

        # Stap 3c: AFAS-quotation aanmaken per Won-Opportunity.
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

            quotation_exists = afas.get_quotation(conn_voorcalc_get, forecast_key.forecast_id) is not None

            if quotation_exists:
                logger.info(
                    f"[{opportunity_id}] AFAS-quotation al aanwezig ({forecast_key.forecast_id}) — "
                    "aanmaken overgeslagen, Forecast wordt wel gesloten"
                )
            else:
                probleemregels = []
                for line in lines:
                    res = line_resolution[line["id"]]
                    if res is None:
                        probleemregels.append(
                            f"regel '{line.get('name')}' (geen mpn en niet in hoofdcategorie Diensten)"
                        )
                    elif res["Kind"] != "diensten" and res["ItemCode"] in failed_item_codes:
                        probleemregels.append(
                            f"{res['Kind']} '{res['ItemCode']}' (niet beschikbaar in AFAS)"
                        )
                if probleemregels:
                    logger.warning(
                        f"[{opportunity_id}] Overgeslagen (quotation niet aangemaakt, Forecast "
                        f"blijft open): {'; '.join(probleemregels)}"
                    )
                    flow3_complete = False
                    continue

                regels = []
                for line in lines:
                    res = line_resolution[line["id"]]

                    if res["Kind"] == "diensten":
                        code_bestaat = bool(res["ItemCode"] and res["ItemCode"].strip()) and diensten_exists.get(res["ItemCode"], False)
                        if code_bestaat:
                            # === Werksoort-regel ===
                            regels.append(
                                {
                                    "ItemCode": res["ItemCode"],
                                    "Soort": "1",
                                    "Aantal": line.get("quantity"),
                                    "Prijs": line.get("price"),
                                    "Kostprijs": line.get("cost"),
                                }
                            )
                        else:
                            # === TXT-regel ===
                            regels.append(
                                {
                                    "Kind": "txt",
                                    "Tekst": line.get("name"),
                                    "Aantal": line.get("quantity"),
                                    "Prijs": line.get("price"),
                                    "Kostprijs": line.get("cost"),
                                }
                            )
                    else:
                        # Artikel (mpn, VaIt=2).
                        vendor_ext_id = line_vendor_ext_id.get(line["id"])
                        inkooprelatie = (
                            inkooprelatie_map.get(vendor_ext_id)
                            if vendor_ext_id and str(vendor_ext_id).strip()
                            else None
                        )
                        regels.append(
                            {
                                "ItemCode": res["ItemCode"],
                                "Soort": res["VaIt"],
                                "Aantal": line.get("quantity"),
                                "Prijs": line.get("price"),
                                "Kostprijs": line.get("cost"),
                                "Inkooprelatie": inkooprelatie,
                            }
                        )

                if AFAS_WRITES_ON_HOLD_3:
                    logger.warning(
                        f"[ON HOLD] [{opportunity_id}] AFAS-quotation ({forecast_key.forecast_id}, "
                        f"{len(regels)} regel(s)) zou aangemaakt worden — niet aangemaakt"
                    )
                else:
                    try:
                        afas.new_quotation(
                            conn_voorcalc_update,
                            forecast_key.forecast_id,
                            forecast_key.prid,
                            forecast_key.sqno,
                            won_quote_titles[opportunity_id],
                            regels,
                        )
                        runlog.add_created(
                            f"AFAS-quotation: offerte {forecast_key.forecast_id} "
                            f"(Forecast SqNo {forecast_key.sqno}, {len(regels)} regel(s))"
                        )
                    except Exception as exc:  # noqa: BLE001
                        logger.error(f"[{opportunity_id}] Fout bij aanmaken AFAS-quotation: {exc}")
                        flow3_complete = False
                        continue

            # Sluiten van de Won-Forecast (ViOp=G).
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
        for opportunity in lost_opportunities:
            opportunity_id = opportunity.get("id")

            forecast_key = parse_forecast_external_id(opportunity.get("externalIdentifier"))
            if forecast_key is None:
                logger.error(
                    f"[{opportunity_id}] Onverwacht externalIdentifier-formaat "
                    f"'{opportunity.get('externalIdentifier')}' — kan PrId/SqNo niet parsen, overgeslagen"
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

            # Precondiitie: de AFAS-quotation moet al bestaan (Flow 3).
            if afas.get_quotation(conn_voorcalc_get, forecast_key.forecast_id) is None:
                logger.warning(
                    f"[{opportunity_id}] AFAS-quotation ({forecast_key.forecast_id}) bestaat nog niet "
                    "— PDF nog niet gekoppeld, watermerk vastgehouden voor herkansing"
                )
                flow4_complete = False
                continue

            # Idempotentie: hangt de PDF er al?
            if afas.get_quotation_attachment(conn_dossier_get, forecast_key.forecast_id, kn_subject_stid):
                logger.info(
                    f"[{opportunity_id}] PDF-bijlage al aanwezig bij offerte {forecast_key.forecast_id} — overgeslagen"
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

            file_name = f"SB-Offerte-{forecast_key.forecast_id}.pdf"

            if AFAS_WRITES_ON_HOLD_4:
                logger.warning(
                    f"[ON HOLD] [{opportunity_id}] Dossieritem '{file_name}' zou aangemaakt worden bij "
                    f"offerte {forecast_key.forecast_id} — niet aangemaakt"
                )
                continue

            try:
                afas.new_subject_attachment(
                    conn_subject_update,
                    kn_subject_stid,
                    kn_subject_usid,
                    forecast_key.forecast_id,
                    forecast_key.prid,
                    file_name,
                    pdf_base64,
                )
                runlog.add_created(
                    f"PDF-bijlage: '{file_name}' bij offerte {forecast_key.forecast_id} "
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
