# Zippy – Entwicklungsnotizen

Interne Notizen zur Weiterentwicklung (Deutsch). Für Nutzer siehe [README.md](../README.md).

Öffnet ZIP- und TAR-Archive als Volumes im Finder, wie eine .dmg. Ziel: gratis im Mac App Store.

## Projekt erzeugen

Das Xcode-Projekt wird aus `project.yml` generiert:

    brew install xcodegen
    xcodegen generate
    open Zippy.xcodeproj

## Sequoia-Prototyp testen

macOS 15 kann FSKit-Volumes nur aus Block-Geräten bauen. Zippy hängt das ZIP deshalb als
rohes Disk-Image an (APFS-Clone, auf 512 Byte aufgefüllt) und übergibt es an DiskImageMounter.
Die Erweiterung `ZippyFS` erkennt die ZIP-Signatur und hängt ein Volume mit `Zippy-Test.txt` ein.

1. In `project.yml` Team-ID und Bundle-ID eintragen, `xcodegen generate`.
2. In Xcode das Schema *Zippy* bauen und starten.
3. Systemeinstellungen → Allgemein → Anmeldeobjekte & Erweiterungen → Dateisystemerweiterungen → *Zippy* aktivieren.
4. In der App „ZIP mounten …“ wählen.
5. Logs beobachten:

       log stream --predicate 'subsystem == "dev.zippy.Zippy.ZippyFS"'

Erfolg = Volume „Zippy“ erscheint im Finder. Kommt kein `probe:` im Log, fragt FSKit
bei roh angehängten Images nicht nach: dann `FSMediaTypes` in `project.yml` anpassen.

### Bisher geprüft (ohne Xcode, macOS 15.8)

- `hdiutil attach` eines rohen ZIPs schneidet auf 512-Byte-Blöcke ab → ZIP-Inhaltsverzeichnis fehlt.
- Mit Clone und Auffüllen ist das ZIP vollständig auf dem Block-Gerät.
- DiskImageMounter hängt so ein Image an und lässt es angehängt, auch ohne erkanntes Dateisystem.

### Ergebnis 12.11.2026 (mit Xcode 26.3, ad hoc signiert, `./build.sh`)

- DiskArbitration findet ZippyFS und prüft das roh angehängte ZIP damit
  (`probed disk ... with zippy_fskit`). `FSMediaTypes` → `Partitionless` passt.
- fskit_agent startet die Erweiterung, AMFI beendet sie sofort:
  "Code has restricted entitlements, but the validation of its code signature failed."
  `com.apple.developer.fskit.fsmodule` braucht ein Provisioning-Profil (Apple-ID / Team).
- Logs lesen mit `/usr/bin/log` (in zsh kann `log` überdeckt sein).
- Kostenloses Personal Team (Apple-ID in Xcode) reicht nicht: "Personal development teams ...
  do not support the FSKit Module capability." → bezahlter Apple-Developer-Account nötig.

## ArchiveCore (Archiv-Kern)

Swift-Package mit libarchive: liest das Inhaltsverzeichnis (ZIP, TAR) in einen Ordnerbaum
und liefert Dateiinhalte an beliebigen Stellen (beim ersten Zugriff in einen Cache entpackt).

    ./scripts/build-libarchive.sh          # einmalig: libarchive bauen (Prüfsumme wird geprüft)
    cd ArchiveCore && swift test           # Tests
    swift run archivetool ls  datei.zip    # Inhalt anzeigen
    swift run archivetool cat datei.zip pfad/im/zip

Vorerst nicht unterstützt: LZMA/XZ-komprimierte Einträge (libarchive ist ohne liblzma gebaut).

### TAR

`.tar`, `.tgz`/`.tar.gz`, `.tbz`/`.tar.bz2` und `.tar.Z`. Das Format erkennt libarchive
am Inhalt (`Archive.format`), nicht an der Endung. Volume-Name ohne `.tar`, Symbol `tgz.icns`.

- Hardlinks im TAR zeigen auf die Daten ihres Ziels und bleiben beim Speichern Hardlinks.
  Wird eine der Dateien geändert, sind es danach zwei getrennte Dateien.
- Geräte, FIFOs und Sockets aus dem TAR werden ausgelassen.
- Ein TAR hat kein Inhaltsverzeichnis: Öffnen liest es einmal ganz, und jede Datei wird
  beim ersten Zugriff von vorne bis zu ihr entpackt. Bei großen `.tar.gz` mit vielen
  Dateien ist das spürbar langsamer als bei ZIP.
- `.tar.gz` und `.tar.bz2` meldet macOS nur als gzip- bzw. bzip2-Datei. Zippy ist dafür
  registriert; steckt kein TAR darin, kommt „Archiv lässt sich nicht öffnen“.
- `.tar.xz` geht noch nicht (fehlt liblzma, wie bei 7z).

## Zippy mit FUSE-T (aktuelle Variante)

Voraussetzung: FUSE-T (`brew install macos-fuse-t/cask/fuse-t`), kostenlos für
nicht-kommerzielle Nutzung. Bauen mit `./build.sh`, die FSKit-Variante mit `./build.sh fskit`.

Ablauf wie bei einer .dmg:
- Doppelklick auf ein ZIP (bzw. `open -a Zippy datei.zip`) → Zippy startet pro Archiv
  einen Hilfsprozess `Zippy --serve …`, öffnet ein Finder-Fenster und beendet sich.
- Der Hilfsprozess stellt das Volume bereit, bis es ausgeworfen wird, und beendet sich dann.
- Mountpunkte: über FSKit unter `/Volumes/Zippy/<Name>`, über NFS unter
  `/private/tmp/Zippy-<uid>/<Name>` (siehe „FUSE-T über FSKit“).

Erkenntnisse aus den Tests (FUSE-T 1.2.9):
- Ein Volume pro Prozess, Mounten und `fuse_loop` im Haupt-Thread. Mehrere Volumes in
  Hintergrund-Threads eines Prozesses → Aushängen wird nicht erkannt.
- `fuse_loop_mt` kehrt nach dem Aushängen nie zurück.
- SIGPIPE muss ignoriert werden.
- FUSE-T-Volumes sind NFS: macOS fragt Zippy einmalig nach „Zugriff auf Netzwerk-Volumes“
  (beim Öffnen des Finder-Fensters). Bis zur Antwort blockiert der Zugriff.
- Prozesse, die ein FUSE-T-Volume testen, nicht in einer Sandbox starten (lokale
  Netzwerkverbindung zum NFS-Server wird sonst blockiert → hängender Mount).
- Hängt doch einmal ein Mount: `umount -f <pfad>` (ggf. mit sudo).

## Zwei Varianten, eine App

Die App-Logik liegt in `Zippy/Shared` (Archive entgegennehmen, Finder-Fenster, beenden).
Dahinter steckt die Schnittstelle `ArchiveMounting` (`mount(archiv) → Mountpunkt`) mit zwei
austauschbaren Umsetzungen; welche, entscheidet allein das Target:

| Target | Ordner | Technik | Voraussetzung |
|---|---|---|---|
| `Zippy` | `Zippy/FUSE` | FUSE-T über FSKit (ab macOS 26) oder NFS, wahlweise macFUSE; ein Hilfsprozess pro Volume | FUSE-T installiert |
| `Zippy-FSKit` | `Zippy/FSKit` | eigene FSKit-Erweiterung `ZippyFS`, Sandbox, App-Store-tauglich | bezahlter Developer-Account |

Beide lesen ZIPs über `ArchiveCore`. Die FSKit-Variante hängt das ZIP als Zippy-Image an
(`ArchiveCore/ZippyImage.swift`: APFS-Clone + Auffüllen auf 4096 + Trailer mit ZIP-Länge und Name),
weil FSKit auf macOS 15 nur Block-Geräte kann. `ZippyFS` erkennt den Trailer und liest das
ZIP blockweise über `BlockSource`.

Stand FSKit-Variante (ohne Account geprüft): Image wird korrekt angelegt, macOS hängt es
nur lesend an und prüft es mit `zippy_fskit`; danach beendet der Signatur-Wächter die
ad hoc signierte Erweiterung. Mit Team-ID in `project.yml` sollte der Rest laufen (ungetestet).

Backend der FUSE-Variante einstellen (nicht `defaults write dev.zippy.Zippy …`: ein alter
Sandbox-Container des ersten Prototyps lenkt das sonst um):

    defaults write ~/Library/Preferences/dev.zippy.Zippy.plist Backend fuse-t         # FUSE-T über NFS
    defaults write ~/Library/Preferences/dev.zippy.Zippy.plist Backend fuse-t-fskit   # FUSE-T über FSKit
    defaults write ~/Library/Preferences/dev.zippy.Zippy.plist Backend macfuse        # macFUSE (FSKit)
    defaults delete ~/Library/Preferences/dev.zippy.Zippy.plist Backend               # automatisch

### FUSE-T über FSKit (Standard ab macOS 26; geprüft mit FUSE-T 1.2.9, macOS 27.2)

Ab macOS 26 kann FUSE-T statt NFS FSKit nutzen (`-o backend=fskit`). Zippy nimmt das
automatisch, wenn `/Applications/fuse-t.app` (FSKit-Modul `fuset`) da ist. Der Installer
legt sie nur an, wenn er schon unter macOS 26+ läuft; danach in den Systemeinstellungen
unter Dateisystemerweiterungen einschalten. Fehlt sie, scheitert `mount -t fuset` mit Exit 72.

- **Mountpunkt `/Volumes/Zippy/<Name>`:** Nur unter /Volumes zeigt der Finder FSKit-Volumes
  in der Seitenleiste, auf dem Schreibtisch und mit Auswerfen-Knopf (außerhalb, etwa in
  /tmp, fehlt alles drei). Dort darf nur root Ordner anlegen, und macOS räumt /Volumes beim
  Start auf. Darum richtet Zippy beim ersten Mal mit Admin-Passwort den LaunchDaemon
  `dev.zippy.volumes-folder` ein (`Zippy/FUSE/VolumesFolder.swift`), der `/Volumes/Zippy`
  bei jedem Start anlegt (Modus 1777 wie /tmp). Abgelehnt: NFS, ohne erneute Frage
  (`defaults delete ~/Library/Preferences/dev.zippy.Zippy.plist VolumesFolderDeclined`).
- **Rückfall:** Scheitert der FSKit-Mount (meist: Erweiterung aus), mountet Zippy über NFS.
  Vorher prüfen geht nicht, `FSClient` zeigt fremde FSKit-Module nicht an. Bis FUSE-T
  aufgibt, vergehen gut 20 Sekunden.
- **Volume-Symbol:** FSKit reicht erweiterte Attribute nicht durch, der Kernel legt sie als
  AppleDouble (`._name`) ins Volume. Zippy legt darum `._.` mit dem Flag „eigenes Symbol“
  in den Wurzelordner, im selben 4096-Byte-Format, das macOS schreibt (kürzere Varianten
  ignoriert der Kernel). Am Wurzelordner lassen sich keine Attribute setzen.
- Mehrere Volumes gleichzeitig, Lesen, Bearbeiten, `fsync`, `ftruncate`, atomares Speichern
  und Auswerfen im Finder gehen. Attribute an Dateien landen als `._`-Dateien und werden
  nicht ins Archiv gespeichert.
- Die Seitenleiste zeigt seit macOS 11 nur einfarbige Standardsymbole, auch für .dmg mit
  eigenem Symbol. Das eigene Symbol wirkt auf dem Schreibtisch und im Fenster.
- Beim Doppelklick zeigt der Finder kurz das alte Ordnersymbol aus `CoreTypes.bundle`
  (Sequoia-Stil), bei .dmg mit eigenem Symbol nur einen Augenblick. Zippy liefert kein
  Ordnersymbol, und die Symboldatei ist in rund 1 ms gelesen; vermutlich der Weg des
  Finders für Volumes ohne Gerät dahinter.

### Warum FUSE-T Standard ist und nicht macFUSE (Stand macFUSE 5.2, macOS 15.8)

macFUSE mountet über FSKit (ohne Kernel-Erweiterung) und die Volumes gelten als lokal, aber:
- Sie erscheinen nicht in der Finder-Seitenleiste (macFUSE mountet an DiskArbitration vorbei).
- Finder/`diskutil` können nicht auswerfen; Zippy hängt sich dafür selbst in DiskArbitration ein.
- Nur ein Volume gleichzeitig, auch mit macFUSE 5.5.0 noch (geprüft 13.11.2026): Beim
  zweiten meldet macFUSEs Dienst nach 10 s „Failed to advertise server for volume“, seine
  FSKit-Erweiterung übernimmt das Gerät nicht. Eindeutige `fsname` ändert nichts. Weitere
  Versuche können verwaiste Hilfs-Laufwerke hinterlassen. An FSKit selbst liegt es nicht:
  Apples exFAT-Erweiterung mountet auf derselben Maschine zwei Volumes gleichzeitig.
  Mehrere Volumes ginge mit macFUSEs Kernel-Erweiterung, die braucht aber gesenkte
  Sicherheit in der Wiederherstellungsumgebung.
- Leerzeichen und Umlaute im Mountpfad lassen den Mount scheitern.
- Unter /Volumes bleiben nach dem Aushängen leere Ordner, die nur root löschen kann.

FUSE-T dagegen: stabil, mehrere Volumes, Auswerfen im Finder; Nachteil: alle Volumes stehen
in der Seitenleiste unter dem Server „fuse-t“ und macOS fragt einmal nach „Netzwerk-Volumes“.
Das .dmg-Verhalten (eigener Eintrag pro ZIP) liefert realistisch nur die FSKit-Variante.

Volume-Symbol: Zippy legt eine versteckte `.VolumeIcon.icns` (das ZIP-Symbol) ins Volume
und setzt am Wurzelordner im Finder-Info das Flag für ein eigenes Symbol. Dafür mountet
FUSE-T mit `namedattr`, sonst kommen keine erweiterten Attribute im Finder an. Das Symbol
erscheint im Finder-Fenster und unter „Informationen“, die Seitenleiste zeigt weiter den
Server. FUSE-Ts eigene Option `volicon` taugt nicht: Damit bleibt der Mount hängen.

## Icons

Dokument-Icons pro Archivtyp im Stil der macOS-Dokumentsymbole, farbcodiert
(ZIP blau, RAR violett, 7Z grün, TGZ orange). Selbst gezeichnet mit CoreGraphics:

    swift scripts/make-icons.swift Zippy/Resources/Icons docs/icons.png

![Icons](icons.png)

Das App-Icon (weißes Z mit Reißverschluss als Diagonale) entsteht genauso. Die
Vorschau zeigt auch die verworfene Variante mit Schriftzug, `wort` als drittes
Argument erzeugt sie statt des Z:

    swift scripts/make-app-icon.swift Zippy/Resources/Icons/AppIcon.icns docs/app-icon.png

![App-Icon](app-icon.png)

Eingebunden sind `zip.icns` und `tgz.icns` (für alle TAR-Varianten). Der Finder zeigt sie,
wenn Zippy die Standard-App für den Typ ist.

## Passwortgeschützte ZIPs

Unterstützt: ZipCrypto (klassisch, z. B. `zip -e`) und WinZip-AES (128/192/256, über
CommonCrypto). Dateinamen sind bei ZIP nie verschlüsselt, Auflisten geht immer.

- Enthält ein ZIP verschlüsselte Dateien, fragt Zippy vor dem Mounten nach dem Passwort
  (`Zippy/Shared/PasswordPrompt.swift`), prüft es an der kleinsten verschlüsselten Datei und
  fragt bei falschem Passwort erneut. Option „Im Schlüsselbund sichern“ (Dienst „Zippy“).
- Umlaute: Das Passwort wird in mehreren Byte-Folgen probiert (UTF-8 NFC/NFD, Windows-1252,
  DOS 437), weil ZIP-Programme das unterschiedlich machen.
- FUSE-Variante: Passwort geht über stdin an den Hilfsprozess, nie über die Kommandozeile.
- FSKit-Variante: Übergabe über einen gemeinsamen Schlüsselbund (`ZippyKeychainGroup` in
  `project.yml`, dazu `keychain-access-groups` in beiden Entitlements). Im Image steht nur
  eine zufällige ID, die Erweiterung löscht den Eintrag nach dem Lesen. Braucht Team-ID;
  ohne lehnt die FSKit-Variante passwortgeschützte ZIPs mit einem Hinweis ab. Ungetestet.

## Bearbeiten

In der FUSE-Variante sind gemountete ZIPs und TARs beschreibbar: Dateien per Drag & Drop
hinzufügen, löschen, umbenennen, verschieben, Ordner anlegen und Dateien ändern.

- Änderungen sammelt `EditableArchive` (ArchiveCore). Neue und geänderte Dateien liegen
  in einem Arbeitsordner, Löschen und Umbenennen ändern nur den Baum im Speicher.
- Gespeichert wird erst beim Auswerfen: Der Hilfsprozess schreibt ein neues Archiv neben
  das Original und ersetzt es dann. Nur Ansehen schreibt nichts.
- Wurde das Original währenddessen von außen geändert, bleibt es stehen und die
  Änderungen landen in „<Name> (bearbeitet).zip“ (bzw. `.tar.gz` usw.).
- `.DS_Store`, `._*`, `.TemporaryItems` usw. sind im Volume sichtbar, zählen aber nicht
  als Änderung und kommen nicht ins ZIP. Erweiterte Attribute leben nur im Speicher.
- Gespeichert wird im Format des Originals. ZIP: alles neu komprimiert (Deflate). TAR: pax,
  mit derselben Kompression, Besitzer ist der aktuelle Benutzer. Namen als UTF-8 in NFC.
  Verschlüsselte Archive bleiben verschlüsselt, mit demselben Passwort, aber immer AES-256.
- Nur lesbar bleibt ein ZIP, wenn Datei oder Ordner nicht beschreibbar sind oder
  verschlüsselte Dateien ohne Passwort nicht umkopiert werden können.
- Scheitert das Speichern, landet eine Kopie mit den Änderungen auf dem Schreibtisch und
  eine Mitteilung erscheint (Klick zeigt die Datei im Finder; sind Mitteilungen aus, ein
  Dialog). Das gilt auch, wenn das Original zwischendurch geändert wurde. Details im Log:
  `log show --info --predicate 'subsystem == "dev.zippy.Zippy"'`.
- Grenzen: Ein ZIP-Kommentar geht verloren. Stürzt der Hilfsprozess ab, sind die
  Änderungen weg. Die FSKit-Variante ist weiterhin nur lesbar.
