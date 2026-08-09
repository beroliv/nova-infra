# Spezifikation: Infrastruktur-Node „Nova“

## 1. Zweck und Zielbild

Dieses Repository beschreibt die spätere, vollständig reproduzierbare Installation
des Infrastruktur-Nodes **Nova** auf einem Raspberry Pi 5 mit Debian 13.

Langfristiges Ziel ist folgender Ablauf:

1. Ein frisches und vollständig aktualisiertes Debian 13 bereitstellen.
2. Die Installation über einen einzigen `curl`-Aufruf starten.
3. Den vollständigen, in diesem Dokument beschriebenen Nova-Sollzustand herstellen.
4. Secrets und gesicherte Anwendungsdaten separat einspielen.
5. Den Zustand und die zentralen Funktionen durch Healthchecks verifizieren.

Diese Datei dokumentiert zunächst ausschließlich den bisher bekannten Sollzustand.
Sie legt noch keine konkrete Implementierung fest.

## 2. Geltungsbereich und Abgrenzung

### Bestandteil der späteren Lösung

- reproduzierbare Installation und Konfiguration des Basissystems
- Installation und Betrieb der beschriebenen Infrastruktur-Dienste
- reproduzierbare Verzeichnis- und Service-Struktur
- Wiederherstellung separat gesicherter Daten und Konfigurationen
- Healthchecks für die wesentlichen Funktionen
- Statusübersicht über die MOTD

### Derzeit nicht Bestandteil

- Installer, Shell-Skripte oder produktiver Code
- Docker-Compose-Dateien
- Migration von MediaMTX
- Ablage von Secrets oder Zugangsdaten im Repository
- Veränderungen am produktiven Referenzsystem Nova während der Entwicklung

## 3. Zielplattform und Basissystem

| Merkmal | Sollzustand |
| --- | --- |
| Hardware | Raspberry Pi 5 |
| Architektur | ARM64 |
| Betriebssystem | Debian 13 (trixie) |
| Systemdatenträger | SSD |
| Remote-Zugriff | SSH |
| Container-Laufzeit | Docker |
| Container-Orchestrierung | Docker Compose |
| Systemdienste | systemd Services und Timer |
| Anmeldung | MOTD mit Statusübersicht |

### Noch vom produktiven Nova zu erfassen

- **TODO:** Aktuelle Partitionierung, Dateisysteme und Mountpoints der SSD auslesen.
- **TODO:** Aktuelle SSH-Konfiguration und erforderliche Härtungseinstellungen auslesen.
- **TODO:** Relevante Benutzer, Gruppen, Berechtigungen und Verzeichnisbesitzer auslesen.
- **TODO:** Bestehende systemd Services und Timer einschließlich Abhängigkeiten auslesen.
- **TODO:** Erforderliche Debian-Pakete und ihre Konfiguration erfassen.

## 4. DNS

### 4.1 AdGuard Home

- AdGuard Home stellt die DNS-Filterfunktion bereit.
- Produktive Version: AdGuard Home v0.107.78
- AdGuard Home ist nativ unter `/opt/AdGuardHome` installiert.
- systemd-Service: `AdGuardHome.service`
- DNS-Port: TCP/UDP 53
- Port der Weboberfläche: 3000
- Produktive Konfiguration: `/opt/AdGuardHome/AdGuardHome.yaml`
- DHCP ist deaktiviert.
- Der AdGuard-eigene DNS-Cache ist bewusst deaktiviert.
- DNSSEC ist in AdGuard deaktiviert; die Resolver-Funktion liegt bei Unbound.
- Filterung und Protection sind aktiviert.
- Die bestehenden Filterlisten und User-Regeln sollen übernommen werden.
- Querylog, `stats.db` und `sessions.db` sind Laufzeitdaten und müssen weder im
  Git-Repository noch im Infrastruktur-Restore enthalten sein.
- Die DNS-Funktion muss später durch Healthchecks geprüft werden.

#### Zukünftige Upstreams

Der neue produktive Sollzustand verwendet nur noch diese beiden regulären,
internen Unbound-Upstreams:

- `127.0.0.1:5335` — Unbound auf Nova
- `192.168.0.193:5335` — Unbound auf Arc

Der bisherige Upstream `192.168.0.192:5335` wird nicht migriert. Diese Adresse
gehörte Atlas; Atlas wird aus der produktiven DNS-Infrastruktur entfernt und
künftig ausschließlich als Testsystem verwendet.

Die derzeit konfigurierten öffentlichen `fallback_dns` sind getrennt von den
beiden regulären internen Upstreams zu behandeln.

**TODO:** Öffentliche `fallback_dns` separat bewerten und den zukünftigen Umgang
damit festlegen.

#### Lokale DNS-Rewrites und Caddy

Mehrere lokale DNS-Namen zeigen absichtlich auf `192.168.0.195`, die LAN-Adresse
von Nova. Dort arbeitet Caddy als Reverse Proxy, leitet Anfragen an die jeweiligen
Backend-Dienste weiter und stellt HTTPS bereit, damit Clients keine
Zertifikatswarnungen erhalten. Diese Rewrites dürfen deshalb nicht automatisch
als falsche IP-Adressen korrigiert werden.

Der bisherige Rewrite `atlas.lan -> 192.168.0.192` wird nicht migriert.

**TODO:** Alle übrigen bestehenden Rewrites vor der endgültigen Migration
vollständig inventarisieren und auf weiterhin benötigte Dienste prüfen.

**TODO:** Bestimmen, welche Anteile der produktiven AdGuard-Konfiguration
reproduzierbar ins Repository dürfen und welche separat eingespielt werden müssen.

### 4.2 Unbound

- Unbound dient als lokaler Resolver.
- Installierte Debian-Paketversion: Unbound 1.22.0
- Unbound läuft nativ als `unbound.service`.
- Zentrale produktive Konfiguration: `/etc/unbound/unbound.conf`
- Port: 5335
- IPv4 ist aktiviert; IPv6 ist deaktiviert.
- UDP und TCP sind aktiviert.
- Modulkonfiguration: `module-config: "validator iterator"`
- Root Hints: `/var/lib/unbound/root.hints`
- Der Zugriff ist für lokale, LAN- und VPN-Netze freigegeben.
- Als bevorzugte Forwarder werden die Quad9-Adressen `9.9.9.9` und
  `149.112.112.112` verwendet.
- `forward-first: yes` bewirkt, dass Quad9 bevorzugt und bei Bedarf die rekursive
  Auflösung als Fallback verwendet wird.
- Die bestehende getestete und optimierte Unbound-Konfiguration muss unverändert
  übernommen werden.
- Die Unbound-Konfiguration darf im Rahmen dieses Projekts nicht eigenständig
  „optimiert“ oder inhaltlich neu entworfen werden.
- Die alten Dateien `50-custom.conf` und `99-modules.conf` sind historischer
  Bestand und werden nicht automatisch migriert.
- Ziel ist eine eindeutige zentrale Unbound-Konfiguration.
- Der aktuelle systemd-Dienst startet Unbound mit `-p`; ein PID-File wird daher
  nicht benötigt.
- Beim Neuaufbau muss die Konfiguration zunächst mit `unbound-checkconf` validiert
  werden.
- Anschließend muss die DNS- beziehungsweise Resolver-Funktion durch einen
  Healthcheck geprüft werden.

#### Zu übernehmende Cache- und Performance-Einstellungen

Die folgenden bestätigten Einstellungen sind das Ergebnis früherer Tests und
müssen beim Neuaufbau übernommen werden:

| Einstellung | Wert |
| --- | --- |
| `cache-min-ttl` | `3600` |
| `cache-max-ttl` | `86400` |
| `prefetch` | `yes` |
| `prefetch-key` | `yes` |
| `serve-expired` | `yes` |
| `serve-expired-ttl` | `172800` |
| `serve-expired-client-timeout` | `1800` |
| `serve-expired-reply-ttl` | `30` |
| `num-threads` | `1` |
| `msg-cache-size` | `128m` |
| `rrset-cache-size` | `256m` |
| `so-rcvbuf` | `8m` |
| `so-sndbuf` | `8m` |
| `num-queries-per-thread` | `2048` |
| `outgoing-range` | `2048` |
| `jostle-timeout` | `200` |
| `edns-buffer-size` | `1232` |

QNAME-Minimierung, aggressives NSEC sowie die bestehenden Hardening-Optionen sind
ebenfalls zu übernehmen und nicht eigenständig zu optimieren.

**TODO:** Die exakten bestehenden Zugriffsnetze, QNAME-Minimierungs-,
Aggressive-NSEC- und übrigen Hardening-Optionen aus der zentralen produktiven
Konfiguration vollständig inventarisieren.

### 4.3 DNS-Zusammenspiel

Der geplante normale DNS-Pfad lautet:

```text
Clients
  -> AdGuard Home auf Nova (TCP/UDP Port 53)
  -> Unbound auf Nova (127.0.0.1:5335)
     und Unbound auf Arc (192.168.0.193:5335)
  -> Upstream- beziehungsweise rekursive Auflösung gemäß Unbound-Konfiguration
```

AdGuard Home übernimmt dabei Filterung und Protection. Die Resolver-Funktion
einschließlich DNSSEC-Verarbeitung, Cache und eigentlicher Auflösung liegt bei den
Unbound-Instanzen.

**TODO:** Konkrete DNS-Healthchecks und erwartete Antworten anhand des produktiven
Systems festlegen.

## 5. VPN

### 5.1 Produktiver Ist- und Sollzustand

- PiVPN ist installiert und wird zur Verwaltung von WireGuard verwendet.
- WireGuard läuft nativ über `wg-quick@wg0.service`.
- Interface: `wg0`
- VPN-Netz: `10.9.0.0/24`
- Nova VPN-Adresse: `10.9.0.1/24`
- Protokoll: UDP
- Listen-Port: `51824`
- LAN-Interface: `eth0`
- Nova LAN-Adresse: `192.168.0.195/24`
- Gateway: `192.168.0.1`
- DNS für VPN-Clients: `10.9.0.1`
- Öffentlicher Endpoint/Hostname: `bertrand.e-cloud.ch`
- IPv4-Forwarding ist aktiviert.
- VPN-Traffic aus `10.9.0.0/24` wird über `eth0` per MASQUERADE/NAT
  weitergeleitet.
- UFW wird nicht verwendet.
- IPv6 für das VPN ist deaktiviert.
- PiVPN ist für Full-Tunnel-Clients mit
  `ALLOWED_IPS="0.0.0.0/0, ::0/0"` eingerichtet.
- Unattended Upgrades sind laut PiVPN-Konfiguration aktiviert.
- Die bestehende Routing- und DNS-Funktion muss beim Neuaufbau erhalten bleiben.

### 5.2 MTU-Besonderheit

Zwischen der PiVPN-Konfiguration und der tatsächlich aktiven
WireGuard-Konfiguration besteht eine bewusste beziehungsweise historisch
entstandene Abweichung:

- In `/etc/pivpn/wireguard/setupVars.conf` steht aktuell `pivpnMTU=1200`.
- In der tatsächlich aktiven `/etc/wireguard/wg0.conf` steht `MTU = 1420`.
- Das laufende Interface `wg0` verwendet erfolgreich MTU 1420.
- Aus früheren Erfahrungen ist bekannt, dass `pivpnMTU=1420` direkt in
  `setupVars.conf` Probleme verursachen kann.
- Deshalb darf `pivpnMTU=1420` nicht automatisch in `setupVars.conf` gesetzt
  werden.
- Die aktive WireGuard-MTU 1420 ist der derzeit funktionierende Referenzzustand.

**TODO (wichtig, Atlas):** Beim Neuaufbau auf Atlas das MTU-Verhalten prüfen und
ein reproduzierbares Verfahren bestimmen, das die funktionierende aktive MTU 1420
herstellt, ohne ungeprüft `pivpnMTU=1420` in `setupVars.conf` zu setzen.

### 5.3 Client- und Key-Strategie

Bestehende WireGuard-Clients werden bewusst nicht restauriert. Es gelten folgende
Vorgaben:

- Keine privaten WireGuard-Keys dürfen im Repository gespeichert werden.
- Keine Preshared Keys dürfen im Repository gespeichert werden.
- Keine Client-Konfigurationen dürfen im Repository gespeichert werden.
- Ein Restore alter WireGuard-Client-Keys ist nicht vorgesehen.
- Bei einem Disaster Recovery werden die benötigten Clients mit PiVPN neu erzeugt.
- Dieses Vorgehen ist bewusst gewählt, weil es einfacher und sicherer ist.
- Peer-Namen und Public Keys sind nicht Bestandteil dieser
  Infrastruktur-Spezifikation.

### 5.4 Disaster-Recovery-Ablauf

Der spätere Disaster-Recovery-Ablauf für WireGuard ist konzeptionell wie folgt:

1. PiVPN und WireGuard installieren.
2. Serverkonfiguration für Nova herstellen.
3. `wg0` mit `10.9.0.1/24` bereitstellen.
4. UDP-Port `51824` verwenden.
5. IPv4-Forwarding und NAT/MASQUERADE herstellen.
6. VPN-DNS auf `10.9.0.1` setzen.
7. Endpoint `bertrand.e-cloud.ch` verwenden.
8. MTU-Verhalten entsprechend dem auf Atlas verifizierten Verfahren herstellen.
9. Keine alten Peers wiederherstellen.
10. Benötigte Clients anschließend mit PiVPN neu anlegen.

### 5.5 Firewall und nftables

- Nova besitzt aktuell keine separate restriktive nftables-Firewall wie Arc.
- Die vorhandenen nftables-Regeln stammen im Wesentlichen aus Docker
  beziehungsweise der iptables-nft-Kompatibilität und dem VPN-NAT.
- Docker verwaltet seine eigenen NAT- und Forwarding-Regeln.
- Beim Neuaufbau dürfen Docker-verwaltete nftables-Regeln nicht statisch aus dem
  alten System kopiert werden.
- Nur die tatsächlich erforderliche VPN-Forwarding- und NAT-Funktion soll
  reproduzierbar hergestellt werden.

## 6. DynDNS

### 6.1 Produktiver Ist-Zustand

- Anbieter: FreeDNS / `freedns.afraid.org`
- systemd-Service: `dyndns.service`
- Service-Typ: `oneshot`
- Ausführendes Skript: `/usr/local/bin/dyndns-update.sh`
- Der Service startet nach `network-online.target`.
- systemd-Timer: `dyndns.timer`
- Timer-Einstellungen:
  - `OnBootSec=2min`
  - `OnUnitActiveSec=60min`
  - `Persistent=true`
- Der Timer ist aktiviert.
- Der letzte geprüfte Lauf war erfolgreich.
- Zwischen den Läufen ist `dyndns.service` erwartungsgemäß `inactive (dead)`, da
  es sich um einen Oneshot-Service handelt. Dieser Zustand ist allein kein Fehler.

### 6.2 Update-Logik

Die bestehende einfache Skriptlogik soll bevorzugt beibehalten und nicht unnötig
durch einen Container oder komplexere Mechanismen ersetzt werden:

- Bash mit `set -euo pipefail`
- DynDNS-Update über `curl`
- Curl-Optionen: `-fsS`
- Timeout: 15 Sekunden
- FreeDNS meldet in seiner Antwort selbst, ob sich die öffentliche IP geändert
  hat.
- Enthält die Antwort `has not changed`, wird dies als erfolgreicher,
  unveränderter Zustand protokolliert.
- Eine eigene Datei zur Speicherung der letzten öffentlichen IP wird nicht
  benötigt.

### 6.3 Secret-Behandlung

Im produktiven Skript ist derzeit die vollständige FreeDNS-Update-URL enthalten.
Diese URL enthält ein geheimes Update-Token und darf daher nicht unverändert
übernommen werden. Für den neuen Sollzustand gelten folgende Vorgaben:

- Die echte FreeDNS-Update-URL beziehungsweise das Token darf nicht im Repository
  gespeichert werden.
- Die nicht geheime Skriptlogik darf später im Repository gespeichert werden.
- Das Secret wird zur Laufzeit aus einer separaten lokalen, nur für `root`
  lesbaren Konfigurations- oder Environment-Datei geladen.
- Eine Beispiel- oder Template-Datei ohne Secret darf im Repository gespeichert
  werden.

**TODO:** Die genaue technische Umsetzung der lokalen Secret-Datei und ihrer
Einbindung beim späteren Installer festlegen.

### 6.4 Abhängigkeit zu WireGuard

DynDNS hält den öffentlichen Hostnamen `bertrand.e-cloud.ch` aktuell. Dieser
Hostname wird als öffentlicher WireGuard-/PiVPN-Endpoint verwendet. Eine Störung
von DynDNS kann daher die Erreichbarkeit des VPNs nach einer Änderung der
öffentlichen IP beeinträchtigen.

### 6.5 Healthcheck

Der spätere DynDNS-Healthcheck muss mindestens prüfen können:

- `dyndns.timer` ist enabled und active.
- Der letzte Lauf von `dyndns.service` war erfolgreich.
- Der Timer besitzt einen nächsten Ausführungstermin.

Der erwartete Zustand `inactive (dead)` des Oneshot-Service zwischen zwei Läufen
darf dabei nicht als Fehler gewertet werden.

## 7. Vaultwarden

- Vaultwarden läuft in Docker.
- Der Stack besteht aus Vaultwarden und Caddy.
- Der bestehende Vaultwarden-Appliance-Installer soll später als Grundlage dienen.
- Vaultwarden-Daten werden separat per Backup und Restore wiederhergestellt.
- Secrets, Zertifikats-Secrets und Zugangsdaten dürfen nicht im Repository liegen.

**TODO:** Bestehenden Appliance-Installer, verwendete Images und Versionen,
Container-Konfiguration, Volumes, Netzwerke, Ports und Caddy-Konfiguration erfassen.

**TODO:** Erforderliche externe Secrets und Zertifikate inventarisieren und ihren
sicheren Bereitstellungsweg definieren.

**TODO:** Aktuellen Backup- und Restore-Ablauf einschließlich Datenpfaden und
Konsistenzanforderungen vom produktiven System auslesen und dokumentieren.

## 8. Syncthing und Backups

### 8.1 Zweck und Abgrenzung

Syncthing hat auf Nova genau einen Zweck: die externe Replikation der bereits von
der Vaultwarden-Appliance erzeugten Backups auf `Diskstation3`.

- Syncthing erstellt selbst keine Vaultwarden-Backups.
- Syncthing ist nicht für Retention, Backup-Validierung oder
  Vaultwarden-Konsistenz verantwortlich.
- Syncthing ist nicht als allgemeiner Datei-Synchronisationsdienst von Nova zu
  betrachten.
- Syncthing wird ausschließlich nachgelagert zur bestehenden
  Vaultwarden-Backup-Architektur eingesetzt.

### 8.2 Installation und Betrieb

Produktiv läuft Syncthing als `syncthing@admin.service` unter dem Benutzer
`admin`. Für den neuen Sollzustand gelten folgende Vorgaben:

- Syncthing wird nativ installiert.
- Das offizielle Syncthing-APT-Repository wird verwendet.
- Es wird nicht ausschließlich die möglicherweise veraltete Syncthing-Version
  aus dem Debian-Standard-Repository verwendet.
- Der spätere Installer richtet APT-Repository und Keyring reproduzierbar ein.
- Syncthing bleibt anschließend über das normale APT-System aktualisierbar.

### 8.3 Bestehender und zukünftiger Ordner

Der derzeitige alte Syncthing-Ordner auf Nova ist wie folgt konfiguriert:

| Merkmal | Bestehender Wert |
| --- | --- |
| Label | `Vaultwarden` |
| Folder-ID | `ycffz-zhzw9` |
| Pfad | `~/backups/vaultwarden` |
| Typ | `sendonly` |
| Zielgerät | `Diskstation3` |
| Filesystem Watcher | aktiviert |
| Zusätzlicher Rescan | alle 3600 Sekunden |

Der alte Pfad `~/backups/vaultwarden` wird nicht als zukünftiger Sollpfad
übernommen. Der neue Syncthing-Folder zeigt auf `/opt/vaultwarden/backups` und
behält die `sendonly`-Semantik sowie `Diskstation3` als Ziel bei.

Die Folder-ID kann beim Neuaufbau neu erzeugt oder durch die restaurierte
Syncthing-Konfiguration erhalten werden. Entscheidend sind der neue Pfad, der Typ
`sendonly` und `Diskstation3` als Zielgerät.

### 8.4 Integration mit der Vaultwarden-Appliance

Die bestehende Backup-Architektur der Vaultwarden-Appliance wird nicht neu
entworfen oder durch Syncthing verändert. Die Appliance erstellt ihre primären
lokalen Backup-Generationen unter `/opt/vaultwarden/backups` und ist selbst für
folgende Aufgaben verantwortlich:

- konsistente Vaultwarden-Backups über `vwctl backup`
- Validierung der Archive und SHA-256-Checksummen
- lokale Aufbewahrung der neuesten sieben gültigen Generationen
- automatische tägliche Backups um 02:30 Uhr lokaler Systemzeit
- Ausführung über `vaultwarden-appliance-backup.timer` mit `Persistent=true`
- Konsistenz, Validierung, lokale Retention, Capacity Checks und Locking

Der geplante Datenfluss lautet:

```text
Vaultwarden-Live-Daten
  -> vwctl backup
  -> /opt/vaultwarden/backups
  -> Syncthing (sendonly)
  -> Diskstation3
```

Die Vaultwarden-Appliance bleibt unabhängig von Syncthing. Ein Ausfall von
Syncthing darf die erfolgreiche lokale Erstellung eines Vaultwarden-Backups nicht
verhindern. Die USB-Replikation ist eine vorhandene Fähigkeit der
Vaultwarden-Appliance und bleibt ebenfalls unabhängig von Syncthing.

### 8.5 Disaster Recovery und Syncthing-Identität

Die aktuell relevanten Syncthing-Pfade auf Nova sind:

| Inhalt | Pfad |
| --- | --- |
| Konfiguration | `/home/admin/.local/state/syncthing/config.xml` |
| Device Private Key | `/home/admin/.local/state/syncthing/key.pem` |
| Device Certificate | `/home/admin/.local/state/syncthing/cert.pem` |
| GUI/API HTTPS Key | `/home/admin/.local/state/syncthing/https-key.pem` |
| GUI/API HTTPS Certificate | `/home/admin/.local/state/syncthing/https-cert.pem` |
| Datenbank | `/home/admin/.local/state/syncthing/index-v2` |
| Log | `/home/admin/.local/state/syncthing/syncthing.log` |

Für Disaster Recovery müssen mindestens folgende Dateien separat gesichert und
wiederherstellbar sein:

- `config.xml`
- `key.pem`
- `cert.pem`

Durch den Restore von `key.pem` und `cert.pem` behält Nova seine bestehende
Syncthing-Geräteidentität, sodass `Diskstation3` Nova weiterhin als dasselbe Gerät
erkennen kann. Die bestehende `config.xml` dient als Restore-Basis, muss beim
Neuaufbau jedoch den Sollpfad `/opt/vaultwarden/backups` verwenden.

`index-v2` und `syncthing.log` müssen nicht restauriert werden. Die Datenbank darf
nach dem Restore durch Syncthing neu aufgebaut werden.

GUI/API-HTTPS-Key und -Zertifikat werden nur gesichert und restauriert, falls sich
bei der späteren Implementierung herausstellt, dass sie für die konkrete
GUI-Konfiguration benötigt werden.

**TODO:** Bei der späteren Implementierung prüfen, ob
`https-key.pem` und `https-cert.pem` für die konkrete GUI-Konfiguration gesichert
und restauriert werden müssen.

### 8.6 Secrets

`key.pem` ist geheimes Schlüsselmaterial. Daher gelten folgende Vorgaben:

- `key.pem` darf niemals im Git-Repository gespeichert werden.
- Syncthing Private Keys dürfen nicht im Repository gespeichert werden.
- Secrets dürfen nicht in dieser Spezifikation dokumentiert werden.
- Restore-Dateien mit Secrets gehören in das separate geschützte
  Disaster-Recovery- beziehungsweise Backup-Konzept.
- Die Syncthing-Device-ID selbst ist kein Secret.

### 8.7 Healthcheck

Der spätere Nova-Healthcheck muss mindestens prüfen können:

- `syncthing@admin.service` ist aktiv.
- Die Syncthing-Konfiguration ist vorhanden.
- Der Vaultwarden-Folder existiert.
- Der konfigurierte Pfad ist `/opt/vaultwarden/backups`.
- Der Folder-Typ ist `sendonly`.
- Der lokale Backup-Pfad existiert.

Eine fehlende oder nicht erreichbare `Diskstation3` darf als Warnung gemeldet
werden. Sie darf jedoch nicht fälschlich als Fehlschlag der lokalen
Vaultwarden-Backup-Erstellung gewertet werden.

## 9. 3D-Drucker und Kamera-Upload

### 9.1 Drucker

Der Prusa-3D-Drucker ist unter der festen privaten LAN-Adresse `192.168.0.61`
erreichbar. Diese private IP-Adresse ist kein Secret, darf im Repository
dokumentiert und später fest in der Konfiguration verwendet werden.

### 9.2 Kamera-Upload zu Prusa Connect

Der Kamera-Upload wird direkt über das bestehende Docker-Image
`jtee3d/prusa_connect_rtsp` realisiert. Es wird keine eigene Upload-Anwendung
entwickelt.

Zu den sensitiven Werten gehören insbesondere:

- die Kamera-URL, falls sie Zugangsdaten enthält
- das Prusa-Connect-Token

Das Prusa-Connect-Token und andere sensitive Werte dürfen niemals im
Git-Repository gespeichert werden. Sie werden später über eine lokale `.env`-Datei
oder eine vergleichbare Secret-Konfiguration außerhalb des Repositories
bereitgestellt. Eine `.env.example` ohne Secrets darf bei der späteren
Implementierung ins Repository aufgenommen werden.

**TODO:** Bei der späteren Implementierung Image-Version, Container-Parameter,
Kameraquelle, Netzwerkmodus und die konkrete lokale Secret-Einbindung festlegen.

### 9.3 Ausschluss von MediaMTX

Der aktuell auf Nova vorhandene native `mediamtx.service` wird nicht migriert.
MediaMTX ist Altbestand und entfällt beim Neuaufbau vollständig, weil
`jtee3d/prusa_connect_rtsp` direkt mit der Kameraquelle arbeiten kann. Der spätere
Installer darf MediaMTX nicht installieren.

### 9.4 Watchdog / Prusa Monitor

Zusätzlich zum Upload-Container wird ein eigener kleiner Watchdog-Container
benötigt. Der Kamera-Upload über `prusa_connect_rtsp` kann nach längerer Laufzeit
beziehungsweise längeren Drucker-Off-Zeiten unzuverlässig werden. Die bewährte
Lösung startet und stoppt den Upload-Container deshalb gezielt abhängig von der
Erreichbarkeit des Druckers.

Die verbindliche Logik lautet:

- Der Watchdog prüft `192.168.0.61` alle 30 Sekunden per Ping.
- Ist der Drucker erreichbar, prüft der Watchdog, ob der Upload-Container läuft,
  und startet ihn andernfalls.
- Ist der Drucker nicht erreichbar, prüft der Watchdog, ob der Upload-Container
  läuft, und stoppt ihn gegebenenfalls.
- Die Logik bleibt funktional einfach und wird nicht unnötig erweitert.

Die bisherige Synology-/Portainer-Lösung verwendete einen Alpine-Container und
installierte `iputils` und `docker-cli` bei jedem Start. Für Nova wird stattdessen
bevorzugt ein kleines reproduzierbares eigenes Watchdog-Image verwendet, das die
benötigten Werkzeuge bereits enthält. Die Watchdog-Logik selbst bleibt möglichst
einfach.

### 9.5 Docker-Zugriff

Der Watchdog benötigt Zugriff auf `/var/run/docker.sock`, um den Upload-Container
starten und stoppen zu können. Dieser Zugriff verleiht weitreichende Rechte auf
dem Host. Das Risiko ist bekannt und wird für diesen kontrollierten eigenen
Watchdog bewusst akzeptiert.

### 9.6 Keine zusätzlichen Docker-Healthchecks

`nova-infra` ergänzt weder für den Prusa-Watchdog noch für den
Prusa-Upload-Container eigene Docker-Healthchecks.

Begründung:

- Zusätzliche Healthchecks sind für diesen Anwendungsfall nicht erforderlich.
- Sie würden die Lösung unnötig komplexer und fehleranfälliger machen.
- Der tatsächliche Docker-Status reicht für die Betriebsübersicht aus.
- Der Upload-Container darf absichtlich gestoppt sein, wenn der Drucker
  ausgeschaltet ist.

Zulässige Zustände sind beispielsweise:

- `prusa-monitor` läuft dauerhaft.
- `prusa-upload` läuft, wenn der Drucker erreichbar ist.
- `prusa-upload` ist `stopped` oder `exited`, wenn der Drucker ausgeschaltet ist.

`stopped` oder `exited` beim Upload-Container ist ausdrücklich nicht automatisch
ein Fehler. Dafür wird keine zusätzliche automatische Bewertung implementiert.
Besitzt ein verwendetes Fremd-Image bereits einen eigenen eingebauten
Healthcheck, darf dessen Docker-Status angezeigt werden; `nova-infra` fügt jedoch
keinen weiteren eigenen Container-Healthcheck hinzu.

### 9.7 MOTD-Integration

Das spätere Nova-MOTD zeigt die Prusa-Container wie die übrigen relevanten
Container an:

- Containername
- tatsächlicher Docker-Zustand
- Laufzeit bei laufenden Containern
- auch gestoppte Container

Das MOTD beobachtet ausschließlich und darf niemals Container starten, stoppen
oder reparieren. Die Start-/Stop-Logik für den Upload-Container gehört
ausschließlich zum Prusa-Watchdog.

### 9.8 Spätere Docker-Struktur

Konzeptionell werden mindestens zwei Komponenten benötigt:

- `jtee3d/prusa_connect_rtsp`
- ein eigener `prusa-monitor`-Watchdog

MediaMTX gehört ausdrücklich nicht dazu. Die konkrete Compose- und
Verzeichnisstruktur wird erst bei der späteren Implementierung festgelegt.

Für die Docker-Dienste auf Nova gilt grundsätzlich: Status soll sichtbar sein,
ohne unnötige zusätzliche Monitoring- oder Healthcheck-Logik einzubauen.
Einfachheit und robuste reproduzierbare Funktion haben Vorrang vor zusätzlicher
Überwachung.

## 10. MOTD und Statusübersicht

### 10.1 Zweck

Nova zeigt beim SSH-Login ein kompaktes dynamisches MOTD. Es dient nicht der
Dekoration, sondern als schnelle Übersicht über den Zustand des Infrastructure
Nodes. Innerhalb weniger Sekunden soll erkennbar sein, was Nova ist, wie es dem
System geht und welche relevanten Dienste und Container aktuell laufen.

Das MOTD wird neu implementiert. Das bestehende alte MOTD kann bei der späteren
Umsetzung als Referenz oder Fallback herangezogen werden, falls die neue
Implementierung keinen Vorteil bietet.

### 10.2 Kopfbereich

Der Kopfbereich identifiziert Nova eindeutig, beispielsweise sinngemäß als:

```text
NOVA — Infrastructure Node
```

Mindestens folgende Angaben müssen erkennbar sein:

- Hostname
- Rolle als Infrastructure Node
- Raspberry Pi
- Debian-Version
- Architektur

Die genaue optische Gestaltung wird bei der späteren Implementierung festgelegt.
Das Ergebnis muss übersichtlich und terminaltauglich bleiben.

### 10.3 Systeminformationen

Direkt unter dem Kopfbereich werden kompakt angezeigt:

- Uptime
- CPU-Temperatur
- Auslastung des Root-Dateisystems
- Gesamtkapazität sowie verwendeter und verfügbarer Speicherplatz
- System Load

Unnötig ausführliche Hardwareinformationen werden nicht angezeigt.

### 10.4 Native Dienste

Ein eigener Bereich zeigt die tatsächlichen Zustände der für Nova relevanten
nativen beziehungsweise systemd-basierten Dienste kompakt an, beispielsweise
`active`, `inactive` oder `failed`. Fehlerhafte Zustände müssen klar erkennbar
sein.

Nach aktuellem Stand gehören mindestens dazu:

- AdGuard Home
- Unbound
- WireGuard / `wg-quick@wg0`
- Syncthing
- DynDNS Timer
- Vaultwarden Backup Timer

Diese Liste ist ausdrücklich noch nicht vollständig. Die endgültige Liste wird
erst nach Abschluss der gesamten Nova-Bestandsaufnahme anhand dieser Spezifikation
festgelegt.

**TODO:** Nach Abschluss der Nova-Bestandsaufnahme die endgültige Liste der
relevanten nativen Dienste und Timer festlegen.

**TODO:** Für jeden Dienst festlegen, welche Zustände erwartet, informativ,
warnungswürdig oder fehlerhaft sind. Insbesondere darf ein erwarteter inaktiver
Oneshot-Service nicht pauschal als Fehler gelten.

### 10.5 Docker und Container

Der Zustand von Docker selbst wird separat geprüft. Darunter werden die für Nova
relevanten Container mit ihrem tatsächlichen Zustand aufgelistet.

Dabei gelten folgende Anforderungen:

- Auch gestoppte Container werden angezeigt.
- `stopped` beziehungsweise `exited` ist nicht automatisch ein Fehler, da
  Container abhängig von ihrer Funktion absichtlich gestoppt sein dürfen.
- Insbesondere kann bei der späteren Prusa-Integration ein gestoppter Upload- oder
  Kamera-Container bei ausgeschaltetem Drucker dem gewünschten Zustand
  entsprechen.
- Laufende Container zeigen möglichst ihre Laufzeit.
- Bei gestoppten Containern werden nach Möglichkeit der tatsächliche Status und
  ein sinnvoller Zeitpunkt beziehungsweise die Dauer seit der Beendigung
  angezeigt.
- Zustände wie `unhealthy`, `dead` oder dauerhaftes `restarting` müssen deutlich
  als problematisch erkennbar sein.
- Wenn Docker selbst nicht läuft, darf die Container-Abfrage das MOTD nicht
  abbrechen.

Die Containerliste wird bis zum Abschluss der Nova-Bestandsaufnahme nicht auf
eine heute fest kodierte Liste beschränkt. Nach aktuellem Stand sind unter anderem
Vaultwarden, Caddy und später die Prusa-Komponenten relevant.

**TODO:** Nach Abschluss der Nova-Bestandsaufnahme festlegen, ob und wie die
relevanten Container dynamisch ausgewählt oder vollständig aufgelistet werden.

### 10.6 Verhalten und Robustheit

Das MOTD muss:

- schnell sein und den SSH-Login nicht merklich verzögern
- ausschließlich Statusinformationen lesen
- keine Reparaturen oder Änderungen durchführen
- keine Dienste starten oder stoppen
- keine Container starten oder stoppen
- keine langsamen externen Internetabfragen durchführen
- bei einem fehlgeschlagenen einzelnen Check die übrigen Informationen weiterhin
  anzeigen
- keine Secrets, Tokens, Private Keys oder sensitiven Konfigurationswerte
  ausgeben
- auch bei einem teilweise defekten System möglichst eine brauchbare
  Diagnoseübersicht liefern

Das MOTD selbst darf niemals dazu führen, dass ein SSH-Login fehlschlägt.

### 10.7 Darstellung

Die spätere Implementierung darf Farben verwenden, wenn das Terminal sie
unterstützt, muss aber auch ohne Farben verständlich bleiben. Ziel ist ungefähr
folgende Informationsdichte; das endgültige Layout darf verbessert werden:

```text
NOVA — Infrastructure Node
Raspberry Pi / Debian / ARM64

Uptime | Temperature | Disk | Load

Services
AdGuard | Unbound | WireGuard | Syncthing | DynDNS | Backup Timer | ...

Containers
Containername | Status | Laufzeit
```

### 10.8 Spätere Implementierung

Als wahrscheinlicher Zielort ist `/etc/update-motd.d/10-nova-status` vorgesehen.
Die endgültige Implementierung erfolgt jedoch erst nach Abschluss der gesamten
Nova-Bestandsaufnahme, damit die Dienst- und Containerliste vollständig bestimmt
werden kann. Bis dahin wird kein MOTD-Skript erstellt.

**TODO:** Bestehende MOTD-Skripte, Ausgabe, Pfade und Statuslogik vom produktiven
Nova als mögliche Referenz beziehungsweise Fallback auslesen.

## 11. Secrets und Repository-Regeln

Folgende Inhalte dürfen niemals im Repository gespeichert werden:

- Passwörter
- API-Tokens
- private Keys
- Zertifikats-Secrets
- sonstige geheime Zugangsdaten

Private LAN-IP-Adressen dürfen im Repository dokumentiert werden.

Zusätzlich gelten folgende Grundsätze:

- Bestehende bewährte Konfigurationen werden bevorzugt übernommen, statt neu
  erfunden zu werden.
- Standardsoftware wird möglichst über vorhandene Debian-Pakete oder gepflegte
  Docker-Images eingesetzt.
- Konfigurationen müssen klar zwischen nicht geheimen, versionierbaren Anteilen
  und separat bereitzustellenden Secrets trennen.
- Beispiele und Vorlagen für geheime Werte dürfen ausschließlich erkennbare
  Platzhalter enthalten.

**TODO:** Vor der späteren Übernahme bestehender Dateien jede Konfiguration auf
eingebettete Secrets prüfen und diese auslagern.

**TODO:** Verfahren zur sicheren Übergabe, Speicherung und Rotation aller Secrets
festlegen.

## 12. Test- und Einführungsstrategie

### Rollen der Systeme

- **Nova** bleibt zunächst das produktive Referenzsystem und wird während der
  Entwicklung nicht verändert.
- **Atlas** wird aus der produktiven DNS-Infrastruktur entfernt und dient künftig
  ausschließlich als Testserver.
- Atlas erhält als Ausgangspunkt ein möglichst leeres Debian-13-System, im
  Wesentlichen ein frisches Debian 13 nach `apt update` und Upgrade.
- Sämtliche destruktiven Installations- und Wiederherstellungstests werden
  ausschließlich auf Atlas durchgeführt.

### Späterer Zielablauf

```text
frisches Debian 13
  -> curl-Installer
  -> vollständiger Nova-Sollzustand
  -> Secrets und Backups einspielen
  -> Healthcheck
```

### Zu prüfende Ergebnisse

- Basissystem und benötigte Pakete sind reproduzierbar eingerichtet.
- Alle vorgesehenen systemd Services und Timer sind aktiv und korrekt geplant.
- Alle vorgesehenen Container laufen mit der erwarteten Konfiguration.
- AdGuard Home und Unbound liefern funktionierendes DNS.
- WireGuard erhält die bestehende Routing- und DNS-Funktion.
- DynDNS aktualisiert wie vorgesehen.
- Vaultwarden ist nach Restore der separat gesicherten Daten funktionsfähig.
- Syncthing und die Backup-Struktur sind eingerichtet; die Synchronisation zur
  Synology und der Restore-Prozess sind überprüfbar.
- Der Prusa-Watchdog startet und stoppt den Upload-Container entsprechend der
  Erreichbarkeit von `192.168.0.61`.
- Die MOTD zeigt die geforderten System- und Dienstzustände.
- Im Repository befinden sich keine Secrets.

**TODO:** Detaillierten Healthcheck-Katalog mit Prüfmethoden, Sollwerten,
Fehlerfällen und Abnahmekriterien erstellen.

**TODO:** Anforderungen an Wiederholbarkeit und Idempotenz des späteren Installers
festlegen.

## 13. Offene Erhebung am Referenzsystem Nova

Die in den vorherigen Abschnitten markierten `TODO`-Punkte müssen zunächst durch
rein lesende Bestandsaufnahme am produktiven Nova geklärt werden. Dabei gilt:

- Nova wird nicht verändert.
- Geheimnisse werden weder in Ausgaben noch im Repository erfasst.
- Bewährte Konfigurationen werden vollständig und nachvollziehbar inventarisiert.
- Abhängigkeiten, Versionen, Pfade, Benutzer, Berechtigungen, Ports, Volumes,
  Timer und Restore-Anforderungen werden dokumentiert.
- Erst nach dieser Bestandsaufnahme werden Implementierungsentscheidungen für den
  späteren Installer getroffen.

## 14. Änderungsverlauf

| Datum | Änderung |
| --- | --- |
| 2026-08-09 | Verbindlichen Sollzustand für Prusa-Kamera-Upload und Watchdog dokumentiert |
| 2026-08-09 | Anforderungen an das zukünftige dynamische Nova-MOTD ergänzt |
| 2026-08-09 | Syncthing-Bestandsaufnahme und Sollzustand für die nachgelagerte Vaultwarden-Backup-Replikation ergänzt |
| 2026-08-09 | DynDNS-Bestandsaufnahme einschließlich Secret-, WireGuard- und Healthcheck-Anforderungen ergänzt |
| 2026-08-09 | Bestandsaufnahme von WireGuard und PiVPN einschließlich MTU-, Client- und Firewall-Strategie ergänzt |
| 2026-08-09 | Bestandsaufnahme von Unbound, AdGuard Home und DNS-Architektur ergänzt; Rolle von Atlas präzisiert |
| 2026-08-09 | Initiale Erfassung des bisher bekannten Sollzustands |
