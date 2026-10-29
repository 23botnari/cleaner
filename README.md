# Cleaner

Aplicație nativă macOS (SwiftUI) care arată ce ocupă loc pe disc și curăță prin câteva click-uri: cache-uri, resturi de aplicații dezinstalate, duplicate, servicii pornite automat. Totul rulează local, nimic nu pleacă de pe Mac.

Necesită **macOS 15 (Sequoia) sau mai nou**.

## Instalare

1. Descarcă `Cleaner.dmg` din [Releases](../../releases/latest).
2. Deschide DMG-ul și trage **Cleaner** în **Applications**.
3. Prima pornire: aplicația nu e notarizată la Apple, așa că macOS o blochează. Dă **click dreapta pe Cleaner → Deschide → Deschide**. Dacă tot refuză: *System Settings → Privacy & Security → Open Anyway*.
4. Acordă **Full Disk Access** (recomandat, vezi mai jos).

### Full Disk Access

Fără el, macOS nu lasă aplicația să citească unele foldere (Containers, cache-ul Safari, profilurile browserelor, backup-urile iPhone, Coșul), iar mărimile afișate pot fi mai mici decât în realitate. Aplicația arată un banner cu buton direct spre setare.

*System Settings → Privacy & Security → Full Disk Access → +* → alege `Cleaner.app` → pornește comutatorul → repornește aplicația.

## Cum se folosește

Fereastra are cinci taburi. Sus vezi mereu spațiul liber și cât se poate elibera.

### Recomandări

Lista cu ce se poate curăța în siguranță, fiecare cu mărimea și un nivel de risc:

| Nivel | Înseamnă |
|---|---|
| **Sigur** (verde) | Se regenerează singur (cache-uri, loguri). |
| **Atenție** (portocaliu) | Verifică înainte (backup-uri iPhone, arhive descărcate, duplicate). |
| **Suspect** (mov) | Posibil rest, dar aplicația nu e sigură. Doar la cerere. |

Ce găsește, printre altele:

- cache-uri de sistem și ale aplicațiilor, loguri;
- Xcode (DerivedData, simulatoare, arhive), Docker;
- Homebrew (`brew cleanup`), Yarn, Bun, CocoaPods, pip/uv, cache-ul Metro / Expo;
- cache-urile browserelor (Chrome, Brave, Edge, Firefox, Safari) — doar cache, nu istoric sau parole;
- backup-uri iPhone vechi și fișiere `.ipsw`;
- kit-uri de instalare (`.dmg`, `.pkg`) și arhive din Descărcări mai vechi de 5 zile;
- snapshot-uri locale Time Machine;
- `node_modules` din proiecte neatinse de mult;
- fișiere duplicate în Descărcări, Desktop și Documente (păstrează copia cea mai veche).

Bifează ce vrei și apasă **Curăță**. Dacă o aplicație folosește încă fișierele (de ex. browserul e deschis), îți spune să o închizi întâi. Descărcările și duplicatele merg la **Coș**, nu se șterg definitiv — spațiul se eliberează după golirea Coșului.

### Explorator

Navighezi prin foldere sortate după mărime, ca să vezi unde s-a dus spațiul. Poți arăta orice în Finder sau muta la Coș.

### Aplicații

Aplicațiile instalate, cu mărimea fiecăreia și a datelor ei din `~/Library`. Dezinstalarea mută aplicația și resturile ei la Coș.

### Resturi

Ce au lăsat în urmă aplicațiile dezinstalate:

- LaunchAgents / LaunchDaemons care pornesc programe care nu mai există;
- fișiere de lansare goale;
- aplicații dezinstalate pe jumătate;
- resturi de antivirus / „cleanere”;
- containere ale aplicațiilor care nu mai sunt instalate (marcate *Suspect*);
- programe care se instalează cu servicii în fundal (de ex. CCleaner) — butonul deschide dezinstalatorul lor oficial.

**Curăță…** deschide o previzualizare cu **comenzile exacte** care vor rula. Serviciile sunt oprite (`launchctl bootout`) înainte ca fișierele să fie mutate la Coș. Pentru ce nu e *Sigur* trebuie să bifezi „Am verificat”. Fișierele de sistem cer parola de administrator.

Aplicația nu atinge niciodată: Docker, Karabiner, Steam, GoogleUpdater, EdgeUpdater. Poți adăuga excluderi proprii în `~/Library/Application Support/Cleaner/exclude.txt` — un cuvânt pe linie (din numele fișierului sau bundle ID), `#` pentru comentarii:

```
# niciun rest care conține aceste cuvinte nu e propus
virtualbox
parallels
```

### Pornire

Toate serviciile care pornesc automat, cu statusul lor:

- 🟢 rulează · 🟠 activ, dar neîncărcat acum · ⚪ dezactivat

**Dezactivează** / **Activează** arată comenzile `launchctl` înainte să ruleze. Dezactivarea e persistentă (rămâne și după restart) și reversibilă. Login Items obișnuite se gestionează din System Settings (buton direct în tab).

### Iconița din bara de meniu

Cleaner stă în bara de meniu cu un **C** și un punct colorat după spațiul liber:

| Punct | Spațiu liber |
|---|---|
| 🟢 verde | ≥ 50 GB |
| 🟡 galben | 25–50 GB |
| 🟠 portocaliu | 10–25 GB |
| 🔴 roșu | < 10 GB — primești și o notificare |

Click pe iconiță: spațiu liber, cât se poate elibera, resturi găsite, buton de rescanare și opțiunea **Pornește la deschiderea Mac-ului**. Închiderea ferestrei nu oprește aplicația; folosește **Ieșire** din meniu. Scanarea se reface automat la fiecare 6 ore.

## Siguranță

- Nimic nu se șterge fără confirmarea ta; vezi mereu ce și cât.
- Resturile și descărcările merg la Coș, nu `rm`.
- Comenzile cu drepturi de administrator trec prin dialogul standard macOS; parola nu ajunge la aplicație.
- Nu se trimite nimic pe internet.

## Compilare din sursă

Cerințe: Xcode sau Command Line Tools cu Swift 6.

```bash
git clone https://github.com/23botnari/cleaner.git
cd cleaner
./build.sh            # build/Cleaner.app
./build.sh --install  # instalează în ~/Applications
./build.sh --dmg      # build/Cleaner.dmg
```

Semnare: scriptul refolosește certificatul aplicației deja instalate în `~/Applications`, altfel primul „Apple Development” din Keychain (sau `SIGN_ID`, dacă e setat). Fără certificat semnează ad-hoc — merge, dar Full Disk Access trebuie reacordat după fiecare build. Ca să alegi alt certificat:

```bash
SIGN_ID="Apple Development: Numele Tău (TEAMID)" ./build.sh --install
```

Pe macOS 27 cu doar Command Line Tools, scriptul compilează automat cu SDK-ul macOS 26 (lipsește pluginul SwiftUIMacros pentru SDK-ul 27).

### Diagnostic

Variabile de mediu utile la dezvoltare:

| Variabilă | Efect |
|---|---|
| `CURATENIE_TAB=exp\|apps\|left\|start` | Deschide direct tabul respectiv |
| `CURATENIE_TARGETS=1` | Scrie într-un fișier lista recomandărilor găsite |
| `CURATENIE_LEFTOVERS=1` | Scrie într-un fișier lista resturilor găsite |
| `CURATENIE_FORCE_NO_FDA=1` | Simulează lipsa Full Disk Access |

```bash
CURATENIE_TAB=left ~/Applications/Cleaner.app/Contents/MacOS/Cleaner
```

## Structură

```
Sources/CuratenieMac/
  Views.swift        fereastra, bara de meniu, notificări
  Targets.swift      ținte de curățare de bază
  MoreTargets.swift  Homebrew, cache-uri dev, browsere, duplicate, Time Machine…
  Leftovers.swift    detecția și curățarea resturilor
  Startup.swift      tabul Pornire
  Apps.swift         tabul Aplicații
  Explorer.swift     tabul Explorator
  Stores.swift       starea scanărilor și execuția curățării
  System.swift       utilitare (shell, căi, Full Disk Access)
scripts/make_icon.swift  generează iconița
reference/               prototipul inițial în Python
```
