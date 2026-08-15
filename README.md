# nova-infra

Reproduzierbarer Aufbau des Raspberry-Pi-Infrastruktur-Nodes Nova gemäß
[`SPECIFICATION.md`](SPECIFICATION.md).

## Implementierungsstand

Aktuell ist ausschließlich Phase 1 implementiert:

- zerstörungsfreie Prüfung auf Raspberry Pi 5, ARM64 und Debian 13/trixie
- Prüfung von Root-Rechten, benötigten Befehlen, sicheren Zielpfaden sowie
  grundlegender DNS-/HTTPS-Erreichbarkeit ohne Änderung der DNS-Konfiguration
- optionale Erkennung des ext4-Mediums `INFRA-RECOVERY` per Dateisystem-Label und
  UUID
- ausschließlich lesender Zugriff auf das Recovery-Medium
- konservatives, idempotentes Zusammenführen der vier Bootstrap-Secrets nach
  `/opt/nova-bootstrap/secrets.env`

Phase 1 installiert oder konfiguriert noch keine späteren Nova-Dienste. Der
endgültige curl-Einstieg wird erst mit der weiteren Installer-Orchestrierung
bereitgestellt; Phase 1 wird derzeit aus einem Repository-Checkout gestartet:

```shell
sudo ./install.sh
```

Fehlt `INFRA-RECOVERY` oder ein einzelner Wert, wird ein eindeutiger
`CHANGE_ME_*`-Platzhalter geschrieben und nur der ungelöste Variablenname
gemeldet. Ein vorhandener echter lokaler Wert wird nie durch einen Platzhalter
ersetzt. Unterschiedliche echte Werte in lokaler Datei und Recovery-Datei führen
zu einem sicheren Abbruch, ohne einen der Werte auszugeben oder die lokale Datei
zu verändern.

Die Secret-Datei verwendet genau eine Zuweisung `NAME=Wert` pro Zeile. Der Wert
wird als Dateninhalt gelesen und nie mit `source` oder `eval` ausgeführt; dadurch
bleiben Shell-Sonderzeichen literal erhalten. Optional dürfen Werte von einem
Paar einfacher oder doppelter Anführungszeichen umschlossen sein. Zeilenumbrüche
innerhalb eines Werts werden nicht unterstützt. Die erwarteten Namen und sicheren
Platzhalter stehen in [`secrets.env.example`](secrets.env.example).

## Tests

Die Phase-1-Tests verwenden ausschließlich temporäre Verzeichnisse und simulierte
Recovery-Quellen. Sie greifen weder auf produktive Systeme noch auf echte
Recovery-Medien zu:

```shell
./tests/phase1_test.sh
```

Zusätzlich sollte vor einem Commit die Shell-Syntax geprüft werden:

```shell
bash -n install.sh lib/phase1.sh tests/phase1_test.sh
```
