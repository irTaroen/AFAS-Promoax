"""Losse hulpfuncties: parsing, datum-conversie, config-bool, getalformattering."""

from __future__ import annotations

import json
import re
from datetime import datetime
from decimal import Decimal
from typing import Optional

# externalIdentifier-formaat dat Flow 1 zet: afas-Forecast-{fc}-{sqno}-{pr}
_EXT_ID_RE = re.compile(r"^afas-Forecast-(?P<fc>\d+)-(?P<sqno>\d+)-(?P<pr>.+)$")

_TRUE_VALUES = {"true", "1", "yes", "ja", "on"}
_FALSE_VALUES = {"false", "0", "no", "nee", "off"}


def convert_to_config_bool(value: Optional[str], default: bool = True) -> bool:
    """Parseert een config.xml-waarde naar bool.

    Herkent true/1/yes/ja/on en false/0/no/nee/off (hoofdletterongevoelig). Leeg,
    ontbrekend of onbekend -> ``default`` (zodat een oudere config zonder <flows>
    alle flows aan laat).
    """
    if value is None or not value.strip():
        return default
    lowered = value.strip().lower()
    if lowered in _TRUE_VALUES:
        return True
    if lowered in _FALSE_VALUES:
        return False
    return default


class ForecastKey:
    """Geparste Opportunity-externalIdentifier (zie parse_forecast_external_id)."""

    __slots__ = ("forecast_id", "sqno", "prid")

    def __init__(self, forecast_id: str, sqno: int, prid: str) -> None:
        self.forecast_id = forecast_id  # uniek AFAS forecast-id -> QuId (voorcalc-offertenr)
        self.sqno = sqno                # volgnummer -> CmForecast @SqNo / KnQuotation FcNo
        self.prid = prid                # verkooprelatie -> CmForecast @PrId / KnQuotation DbId


def parse_forecast_external_id(external_identifier: Optional[str]) -> Optional[ForecastKey]:
    """Parseert de door Flow 1 gezette Opportunity-externalIdentifier.

    ``afas-Forecast-{forecast}-{volgnummer}-{verkooprelatie}`` codeert alles wat de
    latere flows nodig hebben om ZONDER re-fetch van de AFAS-Forecast verder te kunnen.
    Geeft ``None`` bij een onverwacht formaat — de aanroeper slaat het record dan over
    en houdt het watermerk vast.
    """
    if not external_identifier:
        return None
    match = _EXT_ID_RE.match(external_identifier)
    if not match:
        return None
    return ForecastKey(
        forecast_id=match.group("fc"),
        sqno=int(match.group("sqno")),
        prid=match.group("pr"),
    )


def get_salesbuildr_main_category_id(category_id, parent_map):
    """Herleidt een SB-(sub)categorie naar zijn HOOFDcategorie (de wortel).

    Loopt via parentCategoryId omhoog. ``parent_map`` = category.id -> parentCategoryId
    (leeg = wortel). Geeft ``None`` als de categorie onbekend is (met cyclusbescherming).
    """
    if not category_id or category_id not in parent_map:
        return None

    current = category_id
    seen = set()
    while current not in seen:
        seen.add(current)
        parent = parent_map.get(current)
        # Geen (bekende) parent meer -> current is de hoofdcategorie.
        if not parent or parent not in parent_map:
            return current
        current = parent
    return current  # cyclusbescherming: hoogst bereikte categorie


def num_str(value) -> str:
    """Formatteert een getal als string met punt-decimaal, zoals .NET ``double.ToString()``.

    Gehele waarden zonder decimalen ("5" i.p.v. "5.0"), anders de kortste
    round-trip-representatie — nodig voor de AFAS-quotation-payload.
    """
    if value is None or value == "":
        value = 0
    d = float(value)
    if d != d:  # NaN
        return "0"
    if d.is_integer():
        return str(int(d))
    return repr(d)


class AfasJSONEncoder(json.JSONEncoder):
    """JSON-encoder die Decimal als getal (niet als string) serialiseert.

    Zo gaat CmForecast.OrAF als JSON-number mee, net als bij PowerShells ConvertTo-Json.
    """

    def default(self, o):  # noqa: D102
        if isinstance(o, Decimal):
            # Als geheel getal: zonder decimalen; anders als float.
            return int(o) if o == o.to_integral_value() else float(o)
        return super().default(o)


def to_json(body) -> str:
    """Serialiseert een AFAS/SB-payload naar JSON (Decimal-bewust)."""
    return json.dumps(body, cls=AfasJSONEncoder)
