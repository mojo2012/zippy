# Zippy

Öffnet ZIP-Archive als Volumes im Finder, wie eine .dmg. Ziel: gratis im Mac App Store.

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
