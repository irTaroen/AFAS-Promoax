# Promax — AFAS ↔ Salesbuildr sync (Python-versie)

Python-herschrijving van [`Sync-Forecasts.ps1`](../Sync-Forecasts.ps1). Functioneel
gelijk aan de PowerShell-versie: dezelfde vier flows, dezelfde config, mapping, state
en het samenvattende run-logboek.

## Wat het doet

| Flow | Van → naar | Kort |
|---|---|---|
| **1** | AFAS Forecasts → SB Opportunities | delta-sync, upsert via `externalIdentifier` |
| **2** | Gewonnen SB-quotations → AFAS-artikelen | maakt ontbrekende `FbItemArticle`'s aan; nieuwe artikelen krijgen ook `BiSt` (Voorraad, uit `mapping-artikelgroepen.xml`) en `AdSr` (uit `isSerialized` van het SB-product) |
| **3** | Gewonnen SB-quotations → AFAS-quotation | werkt de **bestaande** AFAS-quotation (`KnQuotation`, door AFAS zelf aangemaakt) bij via `PUT` (header `@Action=update`, regels `@Action=insert`) en sluit daarna de Forecast (G/N); idempotent via de `statusCode` van de AFAS-Forecast (O/G/N). Voorcalculatienummer (`QuId`) = SB-offertenummer (quote `number`, bv. `2026-00380`) |
| **4** | SB quote-PDF → AFAS dossieritem | `KnSubject`-bijlage bij de AFAS-quotation, geïdentificeerd via het SB-offertenummer |

Elke flow heeft een eigen config-toggle en een eigen watermerk; ze draaien
achtereenvolgens in één run maar zijn onderling onafhankelijk. Zie
[`../CLAUDE.md`](../CLAUDE.md) voor de volledige beschrijving van de businesslogica —
die geldt ongewijzigd voor deze Python-versie (o.a. abonnementsregels → TXT-regel `SBA`,
lost opportunities, contact gescoped op het bedrijf).

## Projectstructuur

```
python_version/
├── sync_forecasts.py          # entry point + hoofd-logica (de vier flows + state)
├── requirements.txt           # requests
└── promax_sync/
    ├── config.py              # config.xml lezen, watermerken, OverrideDays
    ├── logging_util.py        # console-logging (Write-Log) + run-logboek (logs/log.txt)
    ├── helpers.py             # parsing, getalformattering, JSON-encoder
    ├── afas.py                # AfasClient (GetConnectors + UpdateConnectors)
    └── salesbuildr.py         # SalesbuildrClient + Won/Lost-categorisatie + regel-resolutie
```

## Gedeelde config, mapping, state en logs

Deze versie leest en schrijft **dezelfde bestanden** als de PowerShell-versie, in de
repo-root (één niveau boven `python_version/`) — het is een drop-in vervanging:

- `../configs/config.xml` — runtime-config, plaintext, gitignored
- `../configs/mapping-artikelgroepen.xml` — SB-hoofdcategorie → AFAS artikelgroep
- `../configs/last-sync-dates.xml` — de vier flow-watermerken
- `../logs/log.txt` — samenvattend run-logboek (nieuwste run bovenaan)

De watermerken worden in exact hetzelfde `.NET round-trip ('o')`-formaat weggeschreven,
dus de PowerShell- en Python-versie kunnen op dezelfde state-file wisselen.

## Draaien

```bash
cd python_version
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python sync_forecasts.py
```

Vereist Python 3.11+ (voor de `datetime.fromisoformat`-parsing van de watermerken).

## Dry-run (AFAS writes ON HOLD)

Bovenin `sync_forecasts.py` staan drie schakelaars (net als in de PowerShell-versie):

```python
AFAS_WRITES_ON_HOLD_2 = False
AFAS_WRITES_ON_HOLD_3 = False
AFAS_WRITES_ON_HOLD_4 = False
```

Op `True` fetch/categoriseert de betreffende flow wél, maar slaat elke AFAS-write over
en houdt het watermerk vast — zo kun je een flow inspecteren zonder AFAS te muteren.

## Verschillen met de PowerShell-versie

- Geen globals: AFAS/Salesbuildr-state en de product/company-caches leven in
  `AfasClient` / `SalesbuildrClient`-instances.
- HTTP via `requests` i.p.v. `Invoke-RestMethod`/`Invoke-WebRequest`.
- Getallen in de AFAS-payload worden invariant geformatteerd (`num_str`, punt-decimaal,
  gehele waarden zonder `.0`); `CmForecast.OrAF` gaat als JSON-getal mee via een
  `Decimal`-bewuste JSON-encoder.

De veldnamen, payload-structuren, idempotentie-checks, skip-/watermerk-regels en
loggemeldingen zijn 1-op-1 overgenomen.
