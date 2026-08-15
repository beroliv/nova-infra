# nova-infra

Reproduzierbarer Aufbau des Raspberry-Pi-Infrastruktur-Nodes Nova gemäß
[`SPECIFICATION.md`](SPECIFICATION.md).

## Implementierungsstand

Aktuell sind Phase 1, Phase 2 und Phase 3 implementiert. Phase 1 umfasst:

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
```

Zusätzlich sollte vor einem Commit die Shell-Syntax geprüft werden:

```shell
bash -n install.sh lib/phase1.sh lib/phase2.sh lib/phase3.sh \
  tests/phase1_test.sh tests/phase2_test.sh tests/phase3_test.sh \
  tests/mocks/* tests/phase2-mocks/* tests/phase3-mocks/*
```
