<img src="media/icon-128.png" alt="DispelSound" width="96" align="right">

# DispelSound

A dispel alert for **WoW Forever**: plays a sound the moment you, a party member or a raid member gets a debuff you can dispel. It works in combat, and it does not care which unit frames you use (EllesmereUI, the default frames, anything else).

*Deutsche Beschreibung [weiter unten](#deutsch).*

## Why another dispel addon

WoW Forever runs on the 12.1 engine, and there addons can no longer read auras while you are in combat. A classic debuff scanner sees nothing in a fight. The game itself can still attach a sound to an aura (`C_UnitAuras.AddAuraSound`), but only per unit and exact spell ID. DispelSound registers every debuff of the types your character can dispel for every unit it watches, out of combat, and the game plays the sound itself when one lands.

## Features

- Sound for dispellable debuffs on yourself, your party and your raid, each switchable.
- Debuff types follow the dispel spells your character knows. A paladin with Cleanse gets Magic, Poison and Disease; with only Purify, Poison and Disease. Priest, druid, shaman and mage are detected the same way; every other class can pick the types by hand.
- 13 built-in sounds, plus every sound other addons share through LibSharedMedia, plus your own file.
- Options in the game's settings window, German and English.

## Install

Download the latest ZIP from [Releases](../../releases/latest), unpack it and copy the folder to `World of Warcraft/_forever_/Interface/AddOns/DispelSound/`. The folder has to be named `DispelSound`, or the game will not find the sound files.

## Commands

| Command | Effect |
| --- | --- |
| `/dsound` | Open the options |
| `/dsound test` | Play the current sound |
| `/dsound status` | Show debuff types, number of debuffs and registered units |
| `/dsound on` / `off` | Enable or disable |
| `/dsound sounds` | List all available sounds |
| `/dsound sound Gong` | Pick a sound by name, file path or file ID |
| `/dsound ignore 12345` | Leave one debuff (spell ID) out; repeat to undo |
| `/dsound add 12345` | Add one debuff that is missing from the list |

## Good to know

- Changes only take effect out of combat. Someone who joins the group mid-fight is watched from the end of that fight.
- The sound means "a dispellable debuff landed", not "in range" or "your dispel is ready".
- The debuff list (`Data.lua`) comes from the game data of client 1.60.1.70291. A debuff added by a later patch is silent until the list is updated or you add it with `/dsound add`.
- The game stops an aura sound after five seconds, so keep custom sound files short.

## Development

`luajit tests/run.lua` runs the tests without the game: a small stand-in for WoW loads the addon as the client would and checks what it registers. The same tests run before every release.

To publish a new version, raise `## Version:` in `DispelSound.toc` and push to `main`. The GitHub Action builds the ZIP, creates the release and uploads it to CurseForge and Wago.

## License and credits

GPL v2, see [LICENSE](LICENSE). The debuff list was generated with `tools/gen_dispel_data.py` from [EverAuras](https://github.com/Hackblarvest/EverAuras) (GPL v2). An addon by the guild [Elternabend](https://www.gilde-elternabend.de).

---

## Deutsch

Ein Bann-Alarm für **WoW Forever**: spielt einen Sound, sobald du, ein Gruppen- oder ein Schlachtzugsmitglied einen Debuff bekommt, den du bannen kannst. Funktioniert im Kampf und unabhängig von den Raidframes (EllesmereUI, Standard-Frames oder andere).

### Warum ein eigenes Addon

WoW Forever nutzt die 12.1-Engine, und dort dürfen Addons im Kampf keine Auren mehr lesen. Das Spiel selbst kann aber Sounds an Auren hängen, allerdings nur pro Einheit und exakter Zauber-ID. DispelSound meldet deshalb außerhalb des Kampfes für jede beobachtete Einheit alle Debuffs der Arten an, die dein Charakter bannen kann, und das Spiel spielt den Sound dann selbst ab.

### Funktionen

- Sound bei bannbaren Debuffs auf dir, in der Gruppe und im Schlachtzug, einzeln abschaltbar.
- Die Debuff-Arten richten sich nach deinen Bannzaubern. Ein Paladin mit Reinigung des Glaubens bekommt Magie, Gift und Krankheit, mit Läutern nur Gift und Krankheit. Priester, Druide, Schamane und Magier werden genauso erkannt; alle anderen Klassen wählen die Arten von Hand.
- 13 eingebaute Sounds, dazu alle Sounds, die andere Addons über LibSharedMedia bereitstellen, und eigene Dateien.
- Optionen im Einstellungsfenster des Spiels, auf Deutsch und Englisch.

### Installation

Die neueste ZIP-Datei unter [Releases](../../releases/latest) herunterladen, entpacken und den Ordner nach `World of Warcraft/_forever_/Interface/AddOns/DispelSound/` kopieren. Der Ordner muss `DispelSound` heißen, sonst findet das Spiel die Sounddateien nicht.

### Befehle

| Befehl | Wirkung |
| --- | --- |
| `/dsound` | Optionen öffnen |
| `/dsound test` | Aktuellen Sound abspielen |
| `/dsound status` | Debuff-Arten, Anzahl der Debuffs und registrierte Einheiten zeigen |
| `/dsound on` / `off` | Ein- und ausschalten |
| `/dsound sounds` | Alle verfügbaren Sounds auflisten |
| `/dsound sound Gong` | Sound wählen: Name, Dateipfad oder Datei-ID |
| `/dsound ignore 12345` | Einen Debuff (Zauber-ID) ausnehmen, nochmal eingeben macht es rückgängig |
| `/dsound add 12345` | Einen Debuff ergänzen, der in der Liste fehlt |

### Gut zu wissen

- Änderungen greifen erst außerhalb des Kampfes. Wer mitten im Kampf der Gruppe beitritt, wird ab dem Ende dieses Kampfes beobachtet.
- Der Sound bedeutet „ein bannbarer Debuff ist gelandet“, nicht „in Reichweite“ oder „dein Bannzauber ist bereit“.
- Die Debuff-Liste (`Data.lua`) stammt aus den Spieldaten von Client 1.60.1.70291. Ein Debuff aus einem späteren Patch bleibt stumm, bis die Liste aktualisiert ist oder du ihn mit `/dsound add` ergänzt.
- Das Spiel bricht einen Aura-Sound nach fünf Sekunden ab, eigene Sounddateien also kurz halten.

### Neue Version veröffentlichen

Versionsnummer in `DispelSound.toc` (`## Version:`) erhöhen und auf den Branch `main` hochladen. Die GitHub-Action baut die ZIP-Datei, legt das Release an und lädt es zu CurseForge und Wago hoch. Vorher laufen die Tests; schlägt einer fehl, entsteht kein Release.
