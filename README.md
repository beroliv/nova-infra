# nova-infra

Reproduzierbarer Aufbau des Raspberry-Pi-Infrastruktur-Nodes Nova gemäß
[`SPECIFICATION.md`](SPECIFICATION.md).

## Implementierungsstand

Aktuell sind Phase 1, Phase 2, Phase 3, Phase 4a und Phase 4b implementiert. Phase 1
umfasst:

- zerstörungsfreie Prüfung auf Raspberry Pi 5, ARM64 und Debian 13/trixie
- Prüfung von Root-Rechten, benötigten Befehlen, sicheren Zielpfaden sowie
  grundlegender DNS-/HTTPS-Erreichbarkeit ohne Änderung der DNS-Konfiguration
- optionale Erkennung des ext4-Mediums `INFRA-RECOVERY` per Dateisystem-Label und
  UUID
- ausschließlich lesender Zugriff auf das Recovery-Medium
- konservatives, idempotentes Zusammenführen der fünf Bootstrap-Secrets nach
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

Phase 3 installiert Docker ausschließlich aus dem bereits von Phase 2
vorbereiteten offiziellen Docker-Repository. Sie umfasst:

- Prüfung aller Paketkandidaten auf das offizielle Docker-Repository
- kontrollierten Abbruch bei inkompatiblen Paketen wie `docker.io`, statt diese
  automatisch zu entfernen oder zu ersetzen
- Installation von Docker Engine, CLI, containerd, Buildx und Compose-Plugin
- Aktivierung und Start von `containerd.service` und `docker.service`
- idempotente Aufnahme von `admin` in die Gruppe `docker`, einschließlich des
  Hinweises auf eine erforderliche neue Login-Sitzung
- Prüfung von Docker CLI, Compose, Daemon-Kommunikation, `docker ps` sowie den
  enabled-/active-Zuständen der beiden Dienste
- Schutz vorhandener Docker-Daten und Kontrolle, dass Phase 3 keine Container
  erzeugt oder einen vorhandenen Containerbestand verändert

Die installierte Docker-Paketmenge lautet:

```text
containerd.io docker-buildx-plugin docker-ce docker-ce-cli
docker-compose-plugin
```

Phase 3 schreibt keine `daemon.json`, führt keine Docker-Bereinigung durch und
lädt oder startet keinen Test- beziehungsweise Anwendungscontainer. Docker darf
beim normalen Start seine eigenen Netzwerkregeln verwalten; der Installer legt
keine zusätzlichen Firewall- oder DNS-Regeln an.

Phase 4a übernimmt anschließend ausschließlich den bereits in Phase 2 aus Debian
installierten Unbound-Dienst:

- genau eine versionierte Konfiguration wird als
  `/etc/unbound/unbound.conf.d/nova.conf` installiert
- die Debian-Hauptkonfiguration und die paketierte DNSSEC-Trust-Anchor-
  Integration bleiben unverändert
- `/var/lib/unbound/root.hints` wird reproduzierbar aus den Root-Hints des
  Debian-Pakets `dns-root-data` bereitgestellt
- vor der vollständigen Konfigurationsprüfung initialisiert beziehungsweise
  aktualisiert Debians paketierter `unbound-helper` den ebenfalls paketverwalteten
  Trust Anchor `/var/lib/unbound/root.key`
- die Konfiguration wird vor Installation sowie anschließend im vollständigen
  Debian-Include-Kontext mit `unbound-checkconf` geprüft
- bei einer fehlgeschlagenen vollständigen Prüfung wird eine vorhandene frühere
  `nova.conf` wiederhergestellt, bevor der Dienst aktiviert wird
- Unbound wird als `unbound.service` aktiviert und lauscht ausschließlich über
  IPv4 auf TCP/UDP-Port 5335, nicht auf Port 53
- eine unveränderte Wiederholung hält den Dienst aktiv, vermeidet aber einen
  unnötigen Neustart

Der dokumentierte Resolverpfad verwendet die beiden spezifizierten
Quad9-Forwarder bevorzugt und fällt mit `forward-first: yes` auf rekursive
Auflösung zurück; es werden keine weiteren Forwarder ergänzt. Die unabhängige
Validierung fragt Unbound direkt über `127.0.0.1:5335` ab und prüft normale,
wiederholte, DNSSEC-authentifizierte sowie absichtlich DNSSEC-fehlerhafte
Antworten. `/etc/resolv.conf`, Port 53, AdGuard und die Firewall-Konfiguration
bleiben unverändert.

Phase 4b installiert anschließend die einfache FreeDNS-DynDNS-Integration:

- `/usr/local/bin/dyndns-update.sh` liest ausschließlich `DYNDNS_URL` aus der
  root-only Datei `/etc/nova-infra/dyndns.env`
- die geheime URL wird weder in Git noch in einer systemd-Unit gespeichert und
  dem Curl-Prozess über dessen Standardeingabe statt als sichtbares URL-Argument
  übergeben
- der Updater verwendet `curl -fsS` mit 15 Sekunden Timeout und protokolliert nur
  sichere Erfolgs- oder Fehlermeldungen; `has not changed` gilt als Erfolg
- `dyndns.service` ist ein Oneshot-Dienst nach `network-online.target`
- `dyndns.timer` verwendet exakt `OnBootSec=2min`,
  `OnUnitActiveSec=60min` und `Persistent=true`
- bei gültigem `DYNDNS_URL` wird genau ein Update zur Validierung ausgeführt und
  der Timer anschließend aktiviert
- fehlt der Wert oder ist er noch `CHANGE_ME_DYNDNS_URL`, bleiben Dienst und
  Timer deaktiviert, während der übrige Installer erfolgreich fortfährt

Phase 4b verändert weder `/etc/resolv.conf` noch Unbound, Ports oder
Firewall-Regeln. Vorhandene ältere DynDNS-Dateien werden ohne Ausgabe möglicher
eingebetteter Secrets deterministisch durch die versionierten Dateien ersetzt.

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
./tests/phase3_test.sh
./tests/phase4a_test.sh
./tests/phase4b_test.sh
```

Zusätzlich sollte vor einem Commit die Shell-Syntax geprüft werden:

```shell
bash -n install.sh lib/phase1.sh lib/phase2.sh lib/phase3.sh lib/phase4a.sh \
  lib/phase4b.sh scripts/dyndns-update.sh \
  tests/phase1_test.sh tests/phase2_test.sh tests/phase3_test.sh \
  tests/phase4a_test.sh tests/phase4b_test.sh tests/mocks/* \
  tests/phase2-mocks/* tests/phase3-mocks/* tests/phase4a-mocks/* \
  tests/phase4b-mocks/*
```
