"""AFAS Profit REST-client (GetConnectors + UpdateConnectors).

Mirror van de #region AFAS-functies in Sync-Forecasts.ps1. State (base-URL, headers)
en de request-sessie zitten in de client-instance i.p.v. globals.
"""

from __future__ import annotations

import base64
from datetime import datetime
from decimal import Decimal
from typing import Optional
from urllib.parse import quote

import requests

from .helpers import num_str, to_json


def _status_code(exc: requests.HTTPError) -> Optional[int]:
    return exc.response.status_code if exc.response is not None else None


class AfasClient:
    """Verbinding + calls naar AFAS. Mode '2' = TEST (resttest), anders LIVE (rest)."""

    def __init__(self, omgeving: str, api_token: str, mode: str, logger) -> None:
        subdomain = "resttest" if mode == "2" else "rest"
        self.rest_url = f"https://{omgeving}.{subdomain}.afas.online/profitrestservices"
        encoded = base64.b64encode(api_token.encode("ascii")).decode("ascii")
        self.session = requests.Session()
        self.session.headers.update({"Authorization": f"AfasToken {encoded}"})
        self.logger = logger

    # ── verbinding ────────────────────────────────────────────────────────────

    def test_connection(self) -> bool:
        """Valideert het token met een lichte GET op /metainfo. HTTP 401 -> False."""
        try:
            resp = self.session.get(f"{self.rest_url}/metainfo")
            resp.raise_for_status()
            return True
        except requests.HTTPError as exc:
            if _status_code(exc) == 401:
                return False
            raise

    # ── GetConnectors ───────────────────────────────────────────────────────────

    def get_connector_filtered(self, connector: str, since_date: datetime) -> list:
        """Records ophalen, server-side gefilterd op gewijzigd > since_date (operator 4 = '>').

        AFAS wil 'yyyy-MM-ddTHH:mm:ss' in LOKALE tijd — geen trailing 'Z', geen ToUniversalTime.
        """
        result: list = []
        skip = 0
        take = 100
        local = since_date.astimezone() if since_date.tzinfo else since_date
        since_str = local.strftime("%Y-%m-%dT%H:%M:%S")

        while True:
            url = (
                f"{self.rest_url}/connectors/{connector}?skip={skip}&take={take}"
                f"&filterfieldids=gewijzigd&filtervalues={quote(since_str, safe='')}&operatortypes=4"
            )
            resp = self.session.get(url)
            resp.raise_for_status()
            rows = resp.json().get("rows", [])
            result.extend(rows)
            skip += take
            if len(rows) != take:
                break
        return result

    def get_quotation(self, connector: str, offerte_nr: str):
        """Bestaat de AFAS-quotation al? Filtert Salesbuildr_Voorcalculatie op offerte.

        offerte = QuId = SB-offertenummer, bijv. "2026-00380".
        """
        url = (
            f"{self.rest_url}/connectors/{connector}"
            f"?skip=0&take=1&filterfieldids=offerte&filtervalues={quote(offerte_nr, safe='')}&operatortypes=1"
        )
        resp = self.session.get(url)
        resp.raise_for_status()
        rows = resp.json().get("rows", [])
        return rows[0] if rows else None

    def get_forecast(self, connector: str, forecast_id: str):
        """Eén Forecast via Salesbuildr_Forecasts, gefilterd op forecast (= uniek AFAS forecast-id).

        Flow 3 gebruikt de statusCode als idempotentiesleutel. Geeft de rij of None.
        """
        url = (
            f"{self.rest_url}/connectors/{connector}"
            f"?filterfieldids=forecast&filtervalues={quote(str(forecast_id), safe='')}&operatortypes=1&skip=0&take=1"
        )
        resp = self.session.get(url)
        resp.raise_for_status()
        rows = resp.json().get("rows", [])
        return rows[0] if rows else None

    def get_artikel_by_itemcode(self, connector: str, item_code: str):
        """Bestaat het artikel? Gefilterde lookup op itemCode (i.p.v. de hele catalogus)."""
        url = (
            f"{self.rest_url}/connectors/{connector}"
            f"?filterfieldids=itemCode&filtervalues={quote(item_code, safe='')}&operatortypes=1&skip=0&take=1"
        )
        resp = self.session.get(url)
        resp.raise_for_status()
        rows = resp.json().get("rows", [])
        return rows[0] if rows else None

    def get_quotation_attachment(self, connector: str, offerte_nr: str, subject_type: int) -> bool:
        """Hangt er al een PDF-bijlage (Type == subject_type én Ja_Nee == True) bij de offerte?"""
        url = (
            f"{self.rest_url}/connectors/{connector}"
            f"?filterfieldids=Offerte&filtervalues={quote(offerte_nr, safe='')}&operatortypes=1&skip=0&take=100"
        )
        resp = self.session.get(url)
        resp.raise_for_status()
        for row in resp.json().get("rows", []):
            try:
                row_type = int(row.get("Type"))
            except (TypeError, ValueError):
                continue
            if row_type == subject_type and row.get("Ja_Nee") is True:
                return True
        return False

    # ── UpdateConnectors ──────────────────────────────────────────────────────

    def update_connector(self, connector: str, body: dict, method: str = "POST"):
        """POST (insert) of PUT (update) naar een AFAS UpdateConnector."""
        url = f"{self.rest_url}/connectors/{connector}"
        resp = self.session.request(
            method,
            url,
            data=to_json(body),
            headers={"Content-Type": "application/json"},
        )
        resp.raise_for_status()
        if resp.content:
            try:
                return resp.json()
            except ValueError:
                return resp.text
        return None

    def new_artikel(
        self,
        connector: str,
        item_code: str,
        omschrijving: str,
        artikelgroep: str,
        voorraad: bool = False,
        serienummer: bool = False,
    ):
        """Maakt een minimaal Artikel aan (FbItemArticle). Ds afgekapt op 100 tekens.

        BiSt = voorraad bijhouden (per hoofdcategorie uit mapping-artikelgroepen.xml),
        AdSr = administratie serienummers (uit het SB-product: isSerialized).
        """
        if omschrijving and len(omschrijving) > 100:
            omschrijving = omschrijving[:100]

        body = {
            "FbItemArticle": {
                "Element": {
                    "Fields": {
                        "ItCd": item_code,
                        "AuId": False,
                        "Ds": omschrijving,
                        "Grp": artikelgroep,
                        "BiUn": "St",
                        "VaRc": "2",
                        "BiSt": voorraad,
                        "AdSr": serienummer,
                    }
                }
            }
        }
        self.logger.info(
            f"Artikel aanmaken in AFAS: {item_code} - {omschrijving} (artikelgroep {artikelgroep}, "
            f"voorraad {voorraad}, serienummer {serienummer})"
        )
        return self.update_connector(connector, body)

    def new_subject_attachment(
        self,
        connector: str,
        subject_type: int,
        user_id: str,
        offerte_nr: str,
        verkooprelatie: str,
        file_name: str,
        file_stream_base64: str,
    ):
        """Maakt een dossieritem (KnSubject) met de SB-offerte-PDF als bijlage (Flow 4).

        KnSubjectLink.QuId = voorcalculatie-/offertenummer (= SB-offertenummer), SfId = verkooprelatie.
        """
        body = {
            "KnSubject": {
                "Element": {
                    "Fields": {
                        "StId": subject_type,
                        "Ds": f"SB Offerte - {offerte_nr}",
                        "Da": datetime.now().strftime("%Y-%m-%dT%H:%M"),
                        "UsId": user_id,
                    },
                    "Objects": [
                        {
                            "KnSubjectLink": {
                                "Element": {
                                    "Fields": {
                                        "ToSR": True,
                                        "SfTp": 4,
                                        "SfId": verkooprelatie,
                                        "QuId": offerte_nr,
                                    }
                                }
                            }
                        },
                        {
                            "KnSubjectAttachment": {
                                "Element": {
                                    "Fields": {
                                        "FileName": file_name,
                                        "FileStream": file_stream_base64,
                                    }
                                }
                            }
                        },
                    ],
                }
            }
        }
        self.logger.info(
            f"Dossieritem (KnSubject) aanmaken in AFAS: '{file_name}' bij offerte "
            f"{offerte_nr} / verkooprelatie {verkooprelatie}"
        )
        return self.update_connector(connector, body)

    def close_forecast(
        self,
        connector: str,
        prid: str,
        sqno: int,
        viop: str,
        oraf: Decimal = Decimal(0),
    ):
        """Sluit een Forecast (PUT CmForecast) met verkoopstatus ViOp: G = Won, N = Lost.

        De samengestelde sleutel PrId + SqNo staat als @-attributen op Element-niveau,
        NIET in Fields. ViSt = "5" en ViRe = "00" altijd; OrAF (offertebedrag) alleen bij Won (G).
        """
        fields = {
            "ViSt": "5",
            "ViOp": viop,
            "ViRe": "00",
            "DaSc": datetime.now().strftime("%Y-%m-%d"),
        }
        if viop == "G":
            fields["OrAF"] = oraf

        body = {
            "CmForecast": {
                "Element": {
                    "@PrId": prid,
                    "@SqNo": sqno,
                    "Fields": fields,
                }
            }
        }
        extra = f", OrAF={oraf}" if viop == "G" else ""
        self.logger.info(f"Forecast sluiten in AFAS: {prid} / SqNo {sqno} (ViOp={viop}{extra})")
        return self.update_connector(connector, body, method="PUT")

    def update_quotation(
        self, connector: str, quid: str, ds: Optional[str], regels: list, po_number: Optional[str] = None
    ):
        """Werkt de BESTAANDE AFAS-quotation (KnQuotation, hoofd-voorcalculatie) bij en voegt
        de voorcalculatieregels toe — één PUT, één transactie.

        De hoofd-voorcalculatie wordt in AFAS zelf aangemaakt; deze integratie maakt hem NIET
        aan. LET OP: niet idempotent — elke aanroep voegt de regels opnieuw toe. Flow 3
        bewaakt dat via de Forecast-status.
        """
        body = build_quotation_body(quid, ds, regels, po_number)
        self.logger.info(f"AFAS-quotation bijwerken: {quid} ({len(regels)} regel(s) toevoegen)")
        return self.update_connector(connector, body, method="PUT")


def get_forecast_status_code(forecast: dict) -> str:
    """Genormaliseerde statusCode van een Forecast-rij (Salesbuildr_Forecasts).

    'O' = Open, 'G' = Gesloten en gescoord (gewonnen), 'N' = Gesloten, niet gescoord
    (verloren). Getrimd en in hoofdletters; '' als het veld leeg is of ontbreekt.
    """
    value = forecast.get("statusCode") if forecast else None
    return str(value if value is not None else "").strip().upper()


def afas_error_text(exc: Exception) -> str:
    """AFAS zet de foutomschrijving in de response-body; val terug op de exception-tekst."""
    resp = getattr(exc, "response", None)
    if resp is not None and resp.text:
        return resp.text
    return str(exc)


def build_quotation_body(quid: str, ds: Optional[str], regels: list, po_number: Optional[str] = None) -> dict:
    """Bouwt de KnQuotation-payload (kop + regels) — gedeeld door de echte write en de
    dry-run (ON HOLD), zodat beide exact dezelfde payload tonen.

    Kop: @QuId = SB-offertenummer (Element-attribuut), "@Action" = "update", Ds = SB-quote
    title (max 100), vrij veld U1D8B1C0045A26507C9B67995789BFF16 = "G", vrij veld
    UA766A69149986338FE462D83768E24DA = SB-quote poNumber (alleen als gevuld). QuDa/DbId/FcNo
    worden NIET meegestuurd — die staan al goed in AFAS. Elke regel krijgt
    "@Action" = "insert". Drie regeltypes via VaIt: "2" ARTIKEL, "1" WERKSOORT, "3" TXT.
    Het type komt per regel uit ``Kind`` ('txt') of ``Soort`` ("1"/"2", val terug op "2").
    Elke regel (ook TXT) met een gemapte leverancier (``CredCode``, uit
    mapping-leveranciers.xml) draagt U69BD7B0B402F2007FEC9E485BB4B59C9 = crediteurcode en
    UC61B5DF54390117579CF9AA289E985F0 = True; zonder CredCode worden beide weggelaten.
    Bedragen als string met punt-decimaal (invariant).
    """
    # Ds (omschrijving) is in AFAS beperkt tot 100 tekens.
    if ds and len(ds) > 100:
        ds = ds[:100]

    line_elements = []
    for regel in regels:
        if regel.get("Kind") == "txt":
            # === TXT-regel (VaIt=3): Diensten-item dat NIET in AFAS bestaat, of abonnement ===
            # ItCd = "SBO" (vaste AFAS text-item-code), of "SBA" voor abonnementen (ItemCode).
            # Abonnement (Termijn gezet): prijs en kostprijs zijn per periode.
            termijn = regel.get("Termijn")
            if not termijn or not str(termijn).strip():
                per = ""
            elif termijn == "month":
                per = " per maand"
            elif termijn == "year":
                per = " per jaar"
            else:
                per = f" per {termijn}"
            txt_ds = "{0} - aantal {1}, prijs {2}{4}, kostprijs {3}{4}".format(
                regel.get("Tekst"),
                num_str(regel.get("Aantal")),
                num_str(regel.get("Prijs")),
                num_str(regel.get("Kostprijs")),
                per,
            )
            if len(txt_ds) > 255:
                txt_ds = txt_ds[:255]
            txt_fields = {
                "@Action": "insert",
                "VaIt": "3",
                "ItCd": regel.get("ItemCode") or "SBO",
                "Ds": txt_ds,
                "UnId": "",
                "QuUn": "",
                "Qu": "",
                "QuSa": "",
                "Upri": "",
                "AmCo": "",
            }
            # Ook een TXT-regel met een gemapte leverancier draagt de crediteurvelden.
            _add_cred_fields(txt_fields, regel.get("CredCode"))
            line_elements.append({"Fields": txt_fields})
        else:
            soort = regel.get("Soort") or "2"  # 2=artikel, 1=werksoort
            is_werksoort = soort == "1"
            fields = {
                "@Action": "insert",
                "VaIt": soort,
                "ItCd": regel.get("ItemCode"),
                "UnId": "" if is_werksoort else "St",
                "QuUn": num_str(regel.get("Aantal")),
                "Qu": num_str(regel.get("Aantal")),
                "QuSa": num_str(regel.get("Aantal")),
                "Upri": num_str(regel.get("Prijs")),
                # Werksoorten hebben ALTIJD kostprijs 0; artikelen dragen hun eigen kostprijs.
                "AmCo": "0" if is_werksoort else num_str(regel.get("Kostprijs")),
            }
            # Ds = shortDescription van de SB-quoteregel, alleen als gevuld (max 255 tekens);
            # anders weglaten zodat AFAS de standaardomschrijving van het item gebruikt.
            omschrijving = regel.get("Omschrijving")
            if omschrijving is not None and str(omschrijving).strip():
                fields["Ds"] = str(omschrijving)[:255]
            if is_werksoort:
                # Werksoort-regel (VaIt=1) draagt een extra veld StId = "N".
                fields["StId"] = "N"
            # Regel met een gemapte leverancier: crediteurcode + true; anders beide weglaten.
            _add_cred_fields(fields, regel.get("CredCode"))
            line_elements.append({"Fields": fields})

    header_fields = {
        "@Action": "update",
        "Ds": ds,
        # Vrij veld (KnQuotation-kop): vaste waarde "G".
        "U1D8B1C0045A26507C9B67995789BFF16": "G",
    }
    # Vrij veld (KnQuotation-kop) = PO-nummer van de SB-quote; alleen meesturen als gevuld.
    if po_number is not None and str(po_number).strip():
        header_fields["UA766A69149986338FE462D83768E24DA"] = str(po_number)

    return {
        "KnQuotation": {
            "Element": {
                "@QuId": quid,
                "Fields": header_fields,
                "Objects": [{"KnQuotationLine": {"Element": line_elements}}],
            }
        }
    }


def _add_cred_fields(fields: dict, cred_code) -> None:
    """Crediteurvelden voor een regel met een gemapte leverancier (mapping-leveranciers.xml):
    U69BD7B0B402F2007FEC9E485BB4B59C9 = crediteurcode, UC61B5DF54390117579CF9AA289E985F0 = True.
    Zonder crediteurcode worden beide weggelaten.
    """
    if cred_code is not None and str(cred_code).strip():
        fields["U69BD7B0B402F2007FEC9E485BB4B59C9"] = cred_code
        fields["UC61B5DF54390117579CF9AA289E985F0"] = True
