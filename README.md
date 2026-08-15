# nova-infra

Reproduzierbarer Aufbau des Raspberry-Pi-Infrastruktur-Nodes Nova gemäß
[`SPECIFICATION.md`](SPECIFICATION.md).

## Implementierungsstand

Aktuell sind Phase 1 und Phase 2 implementiert. Phase 1 umfasst:

- zerstörungsfreie Prüfung auf Raspberry Pi 5, ARM64 und Debian 13/trixie
- Prüfung von Root-Rechten, benötigten Befehlen, sicheren Zielpfaden sowie
  grundlegender DNS-/HTTPS-Erreichbarkeit ohne Änderung der DNS-Konfiguration
- optionale Erkennung des ext4-Mediums `INFRA-RECOVERY` per Dateisystem-Label und
  UUID
- ausschließlich lesender Zugriff auf das Recovery-Medium
- konservatives, idempotentes Zusammenführen der vier Bootstrap-Secrets nach
  `/opt/nova-bootstrap/secrets.env`

Phase 2 startet ausschließlich nach erfolgreicher Phase 1 und führt anschließend
folgende Schritte aus:

- APT-Metadaten mit sicherer Freigabe von Release-Metadatenübergängen aktualisieren
- ein nicht interaktives vollständiges System-Upgrade durchführen
- die deterministische Basis-Paketmenge in einem konsolidierten Schritt installieren
- die offiziellen APT-Repositories für Docker und Syncthing mit separaten
  Keyring-Dateien vorbereiten, aber die Anwendungen noch nicht installieren
- Paket-, Befehls- und systemd-Unit-Verfügbarkeit prüfen
- `/etc/resolv.conf` auf unveränderten Inhalt prüfen
- Unbound während der Erstinstallation vor automatischem Start schützen und
  anschließend inaktiv sowie deaktiviert lassen
- den vorherigen Aktivierungszustand von `nftables.service` erhalten

Die Basis-Paketmenge lautet:

```text
bind9-dnsutils ca-certificates curl git gnupg iproute2 iptables iputils-ping
jq nftables procps rsync sudo unattended-upgrades unbound unzip wireguard-tools
xz-utils
```

Phase 2 legt keine DNS-Konfiguration an, ändert weder Resolver noch
Firewall-Regeln und aktiviert keine Dienste späterer Phasen. Insbesondere werden
noch keine Docker- oder Syncthing-Anwendungen installiert und kein Unbound-
Laufzeitbetrieb eingerichtet.

Der endgültige curl-Einstieg wird erst mit der weiteren Installer-Orchestrierung
bereitgestellt; die implementierten Phasen werden derzeit aus einem
Repository-Checkout gestartet:

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

Die Tests verwenden ausschließlich temporäre Verzeichnisse und simulierte
Recovery-, APT-, Download- und systemd-Quellen. Sie greifen weder auf produktive
Systeme noch auf echte Recovery-Medien zu und installieren keine Pakete:

```shell
./tests/phase1_test.sh
./tests/phase2_test.sh
```

Zusätzlich sollte vor einem Commit die Shell-Syntax geprüft werden:

```shell
bash -n install.sh lib/phase1.sh lib/phase2.sh tests/phase1_test.sh \
  tests/phase2_test.sh tests/mocks/* tests/phase2-mocks/*
```
