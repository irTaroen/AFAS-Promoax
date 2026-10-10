"""Console-logging (Write-Log) + samenvattend run-logboek (logs/log.txt).

Naast de uitgebreide console-logging houden we per flow een beknopte samenvatting
bij: de belangrijke WARNING/ERROR-gebeurtenissen en de succesvol aangemaakte/
verwerkte objecten. Aan het einde van de run schrijft `RunLog.write_file` per flow
een blok BOVENAAN logs/log.txt (nieuwste run bovenaan; oudere runs schuiven omlaag).
"""

from __future__ import annotations

import os
from collections import OrderedDict
from datetime import datetime

# ANSI-kleuren voor de console (WARNING=geel, ERROR=rood), net als de PowerShell-kleuren.
_YELLOW = "\033[33m"
_RED = "\033[31m"
_RESET = "\033[0m"

# Vaste labels + volgorde van de flow-blokken in log.txt.
FLOW_LABELS = OrderedDict(
    [
        ("General", "Algemeen (setup & credentials)"),
        ("F1", "Flow 1 — Forecasts -> Opportunities"),
        ("F2", "Flow 2 — Items (artikelen)"),
        ("F3", "Flow 3 — Quotations (voorcalculatie)"),
        ("F4", "Flow 4 — PDF (dossieritems)"),
    ]
)


class RunLog:
    """Verzamelt per flow de WARNING/ERROR-gebeurtenissen en aangemaakte objecten."""

    def __init__(self) -> None:
        # welke flow loopt nu (voor de groepering van WARNING/ERROR in write_file)
        self.current_flow = FLOW_LABELS["General"]
        # flow-label -> {"events": [...], "created": [...]}
        self.buckets: "OrderedDict[str, dict]" = OrderedDict()
        # flow-label -> statusregel (SUCCES/ONVOLLEDIG/UITGESCHAKELD)
        self.statuses: "OrderedDict[str, str]" = OrderedDict()

    def bucket(self, flow: str | None = None) -> dict:
        """Geeft (en maakt zo nodig) het verzamel-object voor een flow."""
        flow = flow or self.current_flow
        if flow not in self.buckets:
            self.buckets[flow] = {"events": [], "created": []}
        return self.buckets[flow]

    def add_event(self, message: str, flow: str | None = None) -> None:
        self.bucket(flow)["events"].append(message)

    def add_created(self, message: str, flow: str | None = None) -> None:
        """Legt een succesvol aangemaakt/verwerkt object vast (met tijdstempel)."""
        ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        self.bucket(flow)["created"].append(f"[{ts}] {message}")

    def set_flow_status(self, flow: str, enabled: bool, complete: bool) -> None:
        """Zet de statusregel van een flow en zorgt dat het blok bestaat."""
        self.bucket(flow)
        if not enabled:
            status = "UITGESCHAKELD — state ongewijzigd"
        elif complete:
            status = "SUCCES — state bijgewerkt"
        else:
            status = "ONVOLLEDIG — state NIET bijgewerkt, herkansing volgende run"
        self.statuses[flow] = status

    def write_file(self, path: str) -> None:
        """Schrijft de samenvatting van deze run BOVENAAN het opgegeven bestand."""
        ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        sep = "=" * 80
        lines = [sep, f"RUN {ts}", sep]

        for flow, bucket in self.buckets.items():
            status = self.statuses.get(flow)
            lines.append("")
            lines.append(f"--- {flow} ---")
            if status:
                lines.append(f"Status : {status}")

            created = bucket["created"]
            events = bucket["events"]
            if created:
                lines.append(f"Aangemaakt/verwerkt ({len(created)}):")
                lines.extend(f"  + {c}" for c in created)
            if events:
                lines.append(f"Waarschuwingen/fouten ({len(events)}):")
                lines.extend(f"  ! {e}" for e in events)
            if not created and not events:
                lines.append("  (geen bijzonderheden)")

        lines.append("")
        new_block = "\n".join(lines) + "\n"

        try:
            directory = os.path.dirname(path)
            if directory and not os.path.isdir(directory):
                os.makedirs(directory, exist_ok=True)

            existing = ""
            if os.path.isfile(path):
                with open(path, "r", encoding="utf-8") as fh:
                    existing = fh.read()
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(new_block + existing)
        except OSError as exc:  # pragma: no cover - logging mag zelf niet fataal zijn
            print(f"{_RED}[write_file] Kon {path} niet schrijven: {exc}{_RESET}")


class Logger:
    """Write-Log-equivalent: console-output + routing van WARNING/ERROR naar de RunLog."""

    def __init__(self, runlog: RunLog) -> None:
        self.runlog = runlog

    def log(self, level: str, message: str) -> None:
        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        line = f"[{timestamp}] [{level}] {message}"
        if level == "WARNING":
            print(f"{_YELLOW}{line}{_RESET}")
        elif level == "ERROR":
            print(f"{_RED}{line}{_RESET}")
        else:
            print(line)

        # Belangrijke gebeurtenissen (WARNING/ERROR) meenemen in het run-logblok,
        # gegroepeerd onder de flow die op dit moment loopt. INFO blijft console-only.
        if level in ("WARNING", "ERROR"):
            self.runlog.add_event(f"[{timestamp}] [{level}] {message}")

    def info(self, message: str) -> None:
        self.log("INFO", message)

    def warning(self, message: str) -> None:
        self.log("WARNING", message)

    def error(self, message: str) -> None:
        self.log("ERROR", message)
