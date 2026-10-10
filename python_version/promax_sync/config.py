"""Config (config.xml), sync-watermerken (last-sync-dates.xml) en de OverrideDays-test.

Alles plaintext XML, net als de PowerShell-versie. De config is gitignored.
"""

from __future__ import annotations

import os
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta
from typing import Optional

# Eerste-run-datum als er (nog) geen watermerk is: 2026-01-01 lokale tijd (aware),
# zodat een eerste run vanaf die datum ophaalt (niet vanaf de Unix-epoch).
DEFAULT_WATERMARK = datetime(2026, 1, 1).astimezone()


def read_xml_config(path: str) -> ET.Element:
    """Leest config.xml en geeft het <configuration>-root-element terug."""
    return ET.parse(path).getroot()


def find_text(root: ET.Element, path: str, default: str = "") -> str:
    """Leest de tekst van een genest element (bv. 'afas/omgeving'); ontbrekend -> default.

    Werkt zowel met CDATA als met ge-escapete tekst (net als SelectSingleNode.InnerText).
    """
    node = root.find(path)
    if node is None or node.text is None:
        return default
    return node.text


def get_sync_watermark(path: str, name: str) -> datetime:
    """Leest één sync-watermerk uit het gezamenlijke state-bestand.

    Ontbrekend bestand/knoop -> DEFAULT_WATERMARK. ``name`` is de flow-sleutel,
    bv. 'Flow1' / 'Flow2'.
    """
    if not os.path.isfile(path):
        return DEFAULT_WATERMARK
    root = ET.parse(path).getroot()
    node = root.find(name)
    if node is None or node.text is None or not node.text.strip():
        return DEFAULT_WATERMARK
    return _parse_aware(node.text.strip())


def set_sync_watermark(path: str, name: str, date: datetime) -> None:
    """Schrijft één sync-watermerk en laat de andere flow-waarden ongemoeid.

    Datum wordt round-trip ('o'-formaat, 7 fractie-cijfers + offset) opgeslagen.
    """
    if os.path.isfile(path):
        tree = ET.parse(path)
        root = tree.getroot()
    else:
        root = ET.Element("SyncDates")
        tree = ET.ElementTree(root)

    node = root.find(name)
    if node is None:
        node = ET.SubElement(root, name)
    node.text = _to_o_format(date)

    _indent(root)
    tree.write(path, encoding="utf-8", xml_declaration=False)


def get_sync_override_days(value: Optional[str], logger) -> Optional[int]:
    """Leest de test-override <OverrideDays> uit config.xml.

    Een geheel getal N betekent: alle flows syncen vanaf N dagen geleden (middernacht
    lokale tijd). Leeg/ontbrekend -> None; niet-numeriek -> None met een WARNING.
    """
    if value is None or not value.strip():
        return None
    try:
        return int(value.strip())
    except ValueError:
        logger.warning(f"OverrideDays bevat geen geldig getal ('{value}') — override genegeerd")
        return None


def override_date(days: int) -> datetime:
    """Middernacht lokale tijd, N dagen geleden (aware)."""
    midnight_today = datetime.now().astimezone().replace(
        hour=0, minute=0, second=0, microsecond=0
    )
    return midnight_today - timedelta(days=days)


# ── interne helpers ───────────────────────────────────────────────────────────


def _parse_aware(text: str) -> datetime:
    """Parseert een ISO-datetime; maakt een naive resultaat aware in de lokale tijdzone."""
    dt = datetime.fromisoformat(text)
    if dt.tzinfo is None:
        dt = dt.astimezone()
    return dt


def _to_o_format(dt: datetime) -> str:
    """Formatteert als .NET round-trip ('o'): yyyy-MM-ddTHH:mm:ss.fffffff±hh:mm."""
    if dt.tzinfo is None:
        dt = dt.astimezone()
    base = dt.strftime("%Y-%m-%dT%H:%M:%S")
    frac = f".{dt.microsecond:06d}0"  # 7 cijfers (µs * 10)
    off = dt.strftime("%z")  # +0100
    off = off[:3] + ":" + off[3:] if off else "+00:00"
    return base + frac + off


def _indent(elem: ET.Element, level: int = 0) -> None:
    """Zorgt voor nette inspringing bij het wegschrijven (2 spaties per niveau)."""
    pad = "\n" + "  " * level
    if len(elem):
        if not elem.text or not elem.text.strip():
            elem.text = pad + "  "
        for child in elem:
            _indent(child, level + 1)
            if not child.tail or not child.tail.strip():
                child.tail = pad + "  "
        if not elem[-1].tail or not elem[-1].tail.strip():
            elem[-1].tail = pad
    else:
        if level and (not elem.tail or not elem.tail.strip()):
            elem.tail = pad
