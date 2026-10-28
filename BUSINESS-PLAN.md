# Formwerk: Businessplan und Marketing

Stand: 28. Oktober 2026

## 1. Kurz gesagt
- **Gratis laden, einmal 10 CHF für Pro, kein Abo.**
- Shapr3D kostet rund 300 USD pro Jahr. Formwerk macht 80 % davon gratis und den Rest für 10 CHF auf Lebenszeit.
- Die Geschichte, die wir erzählen: «Fairer Preis, Open Source, deine Daten bleiben auf deinem Gerät.»
- Die Zielgruppe sind Leute mit einem 3D-Drucker, nicht Ingenieure.

## 2. Preis: warum «gratis + 10 CHF einmal»
| Modell | Vorteil | Nachteil | Entscheid |
|---|---|---|---|
| 10 CHF beim Kauf (bezahlte App) | einfach | 90–95 % weniger Downloads, kaum Chancen auf Charts und Featuring, die Version 1.0 ist schon gratis eingereicht | nein |
| Abo | wiederkehrender Umsatz | genau das, was alle an Shapr3D hassen; zerstört die Fairness-Geschichte | nein |
| **Gratis + Pro für 10 CHF einmal** | viele Downloads (Charts, Bewertungen), wer mehr will, zahlt fair | nur 2–5 % zahlen | **ja** |

**Was gratis bleibt:**
- alles zum Konstruieren: Skizze, Extrudieren, Drehen, Runden, Fasen, Bohrung, Text, Spiegeln, Verschieben, Vereinen, Messen
- alle Vorlagen, das Tutorial und der Druck-Check
- Export als STL

Damit kann jeder einen Teil drucken, ohne zu bezahlen.

**Was Pro freischaltet:**
- Export als 3MF, STEP, OBJ und USDZ
- STEP-Import
- AR-Ansicht
- automatisches Ausrichten
- die Werkzeuge Muster, Aushöhlen und Teilen

Das sind die Werkzeuge der Leute, die viel drucken.

**Was ein Kauf bringt:**
- 10.00 CHF inkl. 8.1 % MwSt. ergeben 9.25 CHF.
- Davon behält Apple 15 % (Small Business Program).
- **Es bleiben ≈ 7.85 CHF pro Kauf.**
- Andere Länder: Apple rechnet den Preis automatisch um (≈ 10 EUR / 10 USD).

**Kosten:** Apple Developer 99 USD pro Jahr. Keine Server, keine Werbung, keine bezahlten APIs.

**Launch-Angebot:** In den ersten 2 Wochen kostet Pro **5 CHF** («Launch-Preis»). Danach 10 CHF. Das schafft Dringlichkeit, ohne unfair zu sein. Apple erlaubt dafür einen geplanten Preiswechsel.

## 3. Einnahmen, realistisch gerechnet
Annahme: 3 % der Nutzer kaufen Pro.

| Downloads pro Monat | Käufe | Einnahmen pro Monat |
|---|---|---|
| 2'000 (ohne Featuring) | 60 | ≈ 470 CHF |
| 10'000 (gute Mundpropaganda) | 300 | ≈ 2'350 CHF |
| 50'000 (Apple-Featuring oder ein viraler Clip) | 1'500 | ≈ 11'800 CHF |

**Später möglich, ohne Abo:**
- Schullizenzen: Apple School Manager gibt automatisch 50 % Rabatt bei Volumenkauf.
- Formwerk 2 als neuer Einmalkauf in 1–2 Jahren.

## 4. Kunden: wer und wo
1. **Besitzer von Bambu-Lab- und Prusa-Druckern:** die grösste Gruppe, die stark wächst. Sie sind auf MakerWorld, Printables, r/BambuLab, r/3Dprinting und r/functionalprint.
2. **iPad-Kreative und Leute mit Apple Pencil**, die sonst Nomad Sculpt oder Procreate nutzen.
3. **Schulen und Lehrpersonen** (Fach Technisches Gestalten, Makerspaces): gratis, ohne Konto und datenschutzfreundlich. In der Schweiz ist das ein starkes Argument.
4. **Besitzer eines iPhone Duo:** neues Gerät, kaum passende Apps, und Apple sucht Vorzeige-Apps.

## 5. Marketing ohne Budget
**Vor dem Launch (2–3 Wochen):**
- **Featuring-Nominierung bei Apple einreichen** (App Store Connect → Featuring → Nominations). Der Entwurf liegt in `deploy/appstore/iphone-duo.md`. Apple will das mindestens 2 Wochen vor dem Datum, besser früher. Die Aufhänger sind iPhone Duo, Apple Pencil Pro, Open Source und 15 Sprachen.
- **Öffentliche TestFlight-Beta** mit einem Link für r/BambuLab und r/3Dprinting. Gibt erste Fans und Fehlermeldungen.
- **MakerWorld und Printables:** jede Woche 2–3 nützliche Teile hochladen, die mit Formwerk konstruiert wurden, mit dem Satz «Made with Formwerk, free on iPad». Das ist der wichtigste Kanal, weil die Zielgruppe dort jeden Tag sucht.
- **Videos** (über den Marketing-Hub im Ordner `Marketing/`): 15–30-Sekunden-Clips im Hochformat, zum Beispiel «Handyständer in 60 Sekunden auf dem iPad konstruiert → gedruckt». Für TikTok, Reels und YouTube Shorts.

**Launch-Woche:**
- Montag: Product Hunt
- Dienstag: «Show HN: Free, open-source CAD for iPad built on OpenCascade» (das Open-Source-Thema zieht auf Hacker News stark)
- Mittwoch: Reddit-Posts mit Video, nicht als Werbung, sondern «I built this, feedback?»
- **Presse** mit kurzer Mail und Presse-Kit:
  - 9to5Mac, MacStories, MacRumors (Thema iPhone Duo)
  - All3DP, Tom's Hardware (3D-Druck)
  - Watson und Digitec-Galaxus-Magazin (Schweiz)
- **YouTuber aus der 3D-Druck-Szene:** Angebotscodes für Pro verschenken (Apple-«Offer Codes» für Einmalkäufe).
- **In-App-Event** im App Store, zum Beispiel «Design-Challenge: Dein bester Halter». Events erscheinen in der App-Store-Suche.

**Dauernd:**
- **Eigene Produktseiten** im App Store, je eine für Bambu-Besitzer, Schulen und das iPhone Duo, mit passenden Screenshots.
- **15 Sprachen:** die meisten CAD-Apps gibt es nur auf Englisch. In Japan, Korea, Brasilien, der Türkei und Indonesien ist die Konkurrenz klein.
- **Bewertungen:** die App fragt erst nach dem ersten erfolgreichen Export (`requestReview`), dann wenn die Leute zufrieden sind.
- **Version 1.1 mit KI-Assistent** (eigener Account, BAUPLAN §12b) als zweite Launch-Welle mit neuer Presse.

## 6. Ziel für die erste Woche (ehrlich)
«Meistgeladene Kreativ-App weltweit in einer Woche» kann niemand versprechen. Dafür braucht es ein Apple-Featuring **und** einen viralen Clip, und beides entscheiden andere.

**Realistisch und messbar:**
- Top 10 «Grafik und Design» in der Schweiz, Deutschland und Österreich
- 5'000 Downloads in Woche 1
- Bewertung ≥ 4.6
- 100 Pro-Käufe
- 10 Modelle auf MakerWorld

Mit Featuring sind 50'000+ möglich.

## 7. Zeitplan
| Wann | Was | Wer |
|---|---|---|
| jetzt | Bezahl-Vertrag («Paid Apps Agreement»), Bank- und Steuerangaben in App Store Connect, Small Business Program beantragen | **du** (Bank- und Steuerdaten darf nur du eingeben) |
| jetzt | In-App-Kauf «Formwerk Pro» in App Store Connect anlegen (10 CHF, Familienfreigabe an) | ich, sobald du Ja sagst |
| Woche 1 | Build 1.1 mit Pro, iCloud, Pencil- und Tastatur-Steuerung und iPhone Duo auf TestFlight. Dein Bruder testet am Wochenende. | ich |
| Woche 1 | Featuring-Nominierung abschicken | du (der Entwurf ist fertig) |
| Woche 2 | Öffentliche Beta, erste 10 MakerWorld-Modelle, 5 Videos | du + ich |
| Woche 3 | Zur Prüfung einreichen («Senden an Apple») | **du** |
| Launch-Woche | Product Hunt, HN, Reddit, Presse, Launch-Preis 5 CHF | du + ich |
| +1 Monat | Version 1.1: KI-Assistent | ich |

## 8. Risiken
- **Jemand veröffentlicht einen Klon des offenen Codes:** Apple lehnt reine Kopien meist ab. Die Marke, die Bewertungen und die Updates bleiben bei dir.
- **Apple lehnt ab:** Die Pro-Grenze ist fair und sauber umgesetzt (StoreKit 2, «Käufe wiederherstellen» vorhanden). Normale iPhones zeigen einen Hinweis plus «Trotzdem öffnen».
- **Viele Support-Anfragen:** GitHub Issues plus eine FAQ im Hilfe-Menü.
- **OCCT-Lizenz (LGPL):** Weil der Code offen ist, ist sie erfüllt. Ein Hinweis steht in NOTICE.md.
