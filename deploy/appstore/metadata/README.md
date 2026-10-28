# Formwerk: localized App Store metadata (version 1.1)

One file per App Store Connect locale. Each file has six copy-ready blocks: Name, Subtitle, Promotional text, Description, Keywords and What's New in 1.1.
The numbers below were counted by script. Names and subtitles count as characters; keywords are counted in UTF-8 bytes (strict reading of Apple's 100 limit, so CJK, Hindi and Arabic lists are shorter).

| Locale | Language | Name | Subtitle | Name chars | Subtitle chars | Promo | Description | Keywords | What's New |
|---|---|---|---|---|---|---|---|---|---|
| [en-US](en-US.md) | English (U.S.) | Formwerk: 3D CAD & Print | Design parts for 3D printing | 24/30 | 28/30 | 166/170 | 1629/4000 | 98/100 B | 489/4000 |
| [de-DE](de-DE.md) | Deutsch | Formwerk: 3D-CAD & 3D-Druck | Teile konstruieren & drucken | 27/30 | 28/30 | 170/170 | 1874/4000 | 93/100 B | 546/4000 |
| [fr-FR](fr-FR.md) | Français | Formwerk : CAO & impression 3D | Créez vos pièces à imprimer | 30/30 | 27/30 | 158/170 | 1940/4000 | 94/100 B | 606/4000 |
| [it](it.md) | Italiano | Formwerk: CAD e stampa 3D | Progetta pezzi da stampare | 25/30 | 26/30 | 150/170 | 1880/4000 | 97/100 B | 582/4000 |
| [es-ES](es-ES.md) | Español (España) | Formwerk: CAD e impresión 3D | Diseña piezas para imprimir | 28/30 | 27/30 | 168/170 | 1875/4000 | 94/100 B | 580/4000 |
| [pt-BR](pt-BR.md) | Português (Brasil) | Formwerk: CAD e Impressão 3D | Crie peças para imprimir | 28/30 | 24/30 | 164/170 | 1792/4000 | 98/100 B | 561/4000 |
| [nl-NL](nl-NL.md) | Nederlands | Formwerk: 3D CAD & printen | Ontwerp eigen printonderdelen | 26/30 | 29/30 | 152/170 | 1832/4000 | 95/100 B | 540/4000 |
| [tr](tr.md) | Türkçe | Formwerk: 3D CAD ve Baskı | 3D yazıcı için parça tasarla | 25/30 | 28/30 | 153/170 | 1774/4000 | 95/100 B | 530/4000 |
| [pl](pl.md) | Polski | Formwerk: CAD i druk 3D | Projektuj części do drukarki | 23/30 | 28/30 | 144/170 | 1792/4000 | 94/100 B | 542/4000 |
| [ja](ja.md) | 日本語 | Formwerk: 3D CAD・3Dプリント | 3Dプリンター用のパーツを設計 | 23/30 | 15/30 | 86/170 | 963/4000 | 95/100 B | 295/4000 |
| [ko](ko.md) | 한국어 | Formwerk: 3D CAD & 프린팅 | 3D 프린터용 부품 디자인 | 22/30 | 14/30 | 104/170 | 1011/4000 | 96/100 B | 310/4000 |
| [zh-Hans](zh-Hans.md) | 简体中文 | Formwerk：3D CAD 建模与打印 | 为3D打印机设计专属零件 | 21/30 | 12/30 | 89/170 | 752/4000 | 92/100 B | 229/4000 |
| [zh-Hant](zh-Hant.md) | 繁體中文 | Formwerk：3D CAD 建模與列印 | 為 3D 印表機設計專屬零件 | 21/30 | 14/30 | 90/170 | 755/4000 | 95/100 B | 228/4000 |
| [hi](hi.md) | हिन्दी | Formwerk: 3D CAD और प्रिंटिंग | 3D प्रिंटर के लिए पार्ट बनाएँ | 29/30 | 29/30 | 139/170 | 1712/4000 | 91/100 B | 501/4000 |
| [ar-SA](ar-SA.md) | العربية | Formwerk: تصميم CAD وطباعة 3D | صمّم قطعًا لطابعتك المجسّمة | 29/30 | 27/30 | 156/170 | 1547/4000 | 99/100 B | 478/4000 |
| [id](id.md) | Bahasa Indonesia | Formwerk: CAD & Cetak 3D | Desain part untuk printer 3D | 24/30 | 28/30 | 170/170 | 1749/4000 | 90/100 B | 512/4000 |

## How to paste
1. App Store Connect → Formwerk → **App Information**: pick the language at the top right (add it with "+" if missing), paste **Name** and **Subtitle**.
2. **Version 1.1** page, same language: paste **Promotional text**, **Description**, **Keywords** and **What's New**.
3. Promotional text can change any time without review; everything else goes with the 1.1 submission.

## Notes
- **Keywords never repeat a word from the name or subtitle** of the same locale (Apple already indexes those). They are comma-separated with no spaces.
- **Printer brands:** "bambu" (and "prusa" in some locales) are in the keywords because hobbyists search for them. App Review can reject third-party trademarks in keywords (guideline 2.3.7). If that happens, swap them for "filament" or "printer".
- **German** uses Swiss spelling (ss, no ß) and words that also work in Germany ("Abmessungen" instead of "Masse").
- **Price:** the Pro price is named only where it is CHF, € or $ (en, de, fr, it, es, nl). Other locales say "one-time purchase" because Apple converts the price per country.
- **iPhone Duo** is mentioned everywhere. If 1.1 ships before the Xcode 27.1 build for iPhone, remove the Duo lines from the description and What's New.
- **What's New** says modelling, templates, print check and STL export stay free, because 3MF/STEP/OBJ were free in 1.0 and move to Pro in 1.1.
