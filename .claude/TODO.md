# TODO / Roadmap — Promax AFAS ↔ Salesbuildr

Verzamellijst van openstaande taken. Vervangt de oude `docs/Roadmap.txt` en de
losse `TODO`-opmerkingen die verspreid in de code stonden (zie *Herkomst* per item).

## Algemeen / later toevoegen

- [ ] **Logging** verder uitbouwen
- [ ] **Notificatie-email**
  - [ ] Flow 1: "organisatie niet gevonden in SalesBuildr"-waarschuwingen opnemen in de notificatie-email
  - [ ] Flow 2: de artikel-/categorie-waarschuwingen ook in de notificatie-email opnemen — *herkomst: `Sync-Forecasts.ps1:865`*
- [ ] **Mapping artikelgroepen** afronden (hoofdcategorieën → AFAS `Grp`, zie `configs/mapping-artikelgroepen.xml`)
- [ ] **Mapping werksoorten**
- [ ] **Categorie "Diensten"**: voor items met **Diensten** als hoofdcategorie komt er later een volledig nieuwe categorie — mapping dan bijwerken (nu tijdelijk `AFAS-id="W"` → Werksoorten in `configs/mapping-artikelgroepen.xml`)
- [ ] **Offerte als PDF** in het dossier van de klant plaatsen
- [ ] **Status-combinaties** voor opportunities

## Forecasts (Flow 1)

- _(nog geen open punten)_

## Voorcalculatie (Flow 2)

- [x] Voorcalculatie pas aanmaken als álle items aanwezig zijn
- [x] Text-item voor ontbrekende artikelen
- [x] Werksoort: `mpn` is leeg en intern product-id gebruiken
- [x] Cost center-id mappen aan cost center-naam en AFAS-artikelgroep
- [ ] Uitbesteden aan ( VRIJ VELD)op de voorcalculatieregel. Dit is de inkooprelatie. Check SB api
- [ ] Werkmaatschappy (VRIJ VELD) op de voorcalculatieregel vanuit de Forecast. Tabel heet Groeperingsoort
- [ ] Adminsitratie vanuit voorcalc kopplen. Is dit mogelijk?
- [x] Status offerte op voorcalc ook vullen
## AFAS

- [ ] Productieomgeving voorbereiden
- [ ] TXT artiekel aanmaken
- [ ] Dossieritem inrichten
- [x] **Offerte-PDF uploaden naar AFAS** — wacht op payload van de gebruiker. De base64
  zit in `$Pdf.Base64`, met de AFAS-sleutels `$Item.PrId` (verkooprelatie) en
  `$Item.QuId` (quotation-id). Bouw de aangeleverde payload en POST die naar de juiste
  AFAS UpdateConnector (bv. via een `Send-AfasQuotationPdf`-helper). — *herkomst: `SB_PDF.ps1:402`*

## Bekende issues

- [ ] `KnQuotation.Upri` gebruikt de ruwe eenheidsprijs (`price`) zónder regelkorting,
  terwijl `CmForecast.OrAF` de korting wél toepast — bekende inconsistentie, wacht op
  bevestiging, nog niet in code opgelost. — *herkomst: `.claude/AFAS_API_Guide.md`,
  `.claude/Salesbuildr_API_Guide.md`*
