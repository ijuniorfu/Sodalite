# App Store Screenshot Pipeline

Rendert die Marketing-Screenshots (Clean/Minimal, Sodalith-Look) fuer iPhone, iPad und Apple TV
in 26 Sprachen aus den rohen Geraete-Screenshots. Kein KI-generiertes UI, nur echte Screenshots
auf gestaltetem Hintergrund mit lokalisierter Headline.

## Setup (einmalig)

    cd Tools/appstore-shots
    npm install
    npx playwright install chromium

## Inputs bereitstellen

Rohe Screenshots (1:1 Geraetemasse) nach `input/<platform>/<shot>.png` legen. Platforms: `iphone`,
`ipad`, `tvos`. Shots: home, detail, catalog, livetv, music, search, settings. Aus `AppStore Bilder/`
kopieren (der Detail-Shot heisst in der Quelle `detailview`):

    SRC="../../AppStore Bilder"; DST="input"
    mkdir -p "$DST/iphone" "$DST/ipad" "$DST/tvos"
    for s in home catalog livetv music search settings; do
      cp "$SRC/sodalite ios /ios $s.png"      "$DST/iphone/$s.png"
      cp "$SRC/sodalite ipados/ipados $s.png" "$DST/ipad/$s.png"
      cp "$SRC/sodalite tvos/tvos $s.png"     "$DST/tvos/$s.png"
    done
    cp "$SRC/sodalite ios /ios detailview.png"      "$DST/iphone/detail.png"
    cp "$SRC/sodalite ipados/ipados detailview.png" "$DST/ipad/detail.png"
    cp "$SRC/sodalite tvos/tvos detailview.png"     "$DST/tvos/detail.png"

## Rendern

    node render.mjs

Schreibt 546 PNGs nach `out/<locale>/<platform>/<shot>.png` (26 Sprachen x 3 Plattformen x 7 Shots),
jede in exakter App-Store-Slot-Groesse (iPhone 1320x2868, iPad 2064x2752, tvOS 3840x2160). Die letzte
Zeile meldet Anzahl, en-Fallbacks und gekuerzte Headlines.

## Anpassen

- Copy: `headlines.json` (copySets `portrait` fuer iPhone/iPad, `tv` fuer Apple TV; je Shot je Locale
  ein `kicker` + `headline`). Fehlt ein Locale, faellt der Renderer sichtbar auf `en` zurueck.
- Layout/Farben: `styles.css` (Design-Tokens oben, prozentbasiertes Layout, Modi `portrait`/`tv`).
- Targets/Masse/Reihenfolge: `manifest.json`.

Lange Headlines (z.B. Deutsch, Finnisch) werden automatisch verkleinert, falls sie die feste
Kopfzone ueberlaufen wuerden (`renderOne` in `render.mjs`).

## Upload

`out/` ist nach Locale und Plattform strukturiert, passend fuer den App-Store-Connect-Upload
(z.B. via asc). `input/`, `out/` und `node_modules/` sind gitignored und werden lokal regeneriert.
