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

- Anbieter: FreeDNS
- Ausführung über einen systemd Service und einen systemd Timer
- Aktualisierung derzeit ungefähr stündlich
- Token und andere Secrets dürfen nicht im Repository gespeichert werden.

**TODO:** Bestehenden Service, Timer, tatsächliches Intervall, Update-Aufruf,
Abhängigkeiten und Fehlerbehandlung vom produktiven Nova auslesen.

**TODO:** Sicheren Bereitstellungsweg für das FreeDNS-Token festlegen.

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

- Syncthing läuft auf Nova.
- Die Backup-Verzeichnisstruktur muss reproduzierbar hergestellt werden können.
- Vaultwarden-Backups sind Bestandteil der Sicherung.
- Backups werden zur Synology synchronisiert.
- Der Restore-Prozess muss Bestandteil der späteren Gesamtlösung sein.

**TODO:** Syncthing-Version, Installationsart, Service-Benutzer, Daten- und
Konfigurationspfade sowie relevante Ordnerzuordnungen von Nova auslesen.

**TODO:** Bestehende Backup-Verzeichnisstruktur, Berechtigungen,
Aufbewahrungsregeln und Zeitpläne erfassen.

**TODO:** Synchronisationsbeziehung zur Synology einschließlich Zielpfaden und
erwartetem Verhalten erfassen; Gerätekennungen oder Zugangsdaten nur dann
dokumentieren, wenn sie keine Secrets darstellen.

**TODO:** Vollständigen Restore-Prozess und dessen Validierung definieren.

## 9. 3D-Drucker und Kamera-Upload

### 9.1 Drucker und Upload

- Prusa-Drucker-IP: `192.168.0.61`
- Der Kamera-Upload läuft über das Docker-Image
  `jtee3d/prusa_connect_rtsp`.
- Das Prusa-Connect-Token darf nicht im Repository gespeichert werden.
- MediaMTX wird im neuen System nicht migriert.

**TODO:** Aktuell verwendete Image-Version, Container-Parameter, Kameraquelle,
Netzwerkmodus, Volumes und sonstige Laufzeitabhängigkeiten auslesen.

**TODO:** Sicheren Bereitstellungsweg für das Prusa-Connect-Token festlegen.

### 9.2 Watchdog

- Ein zusätzlicher eigener Watchdog-Container steuert den Upload-Container.
- Der Watchdog prüft die Drucker-IP alle 30 Sekunden.
- Ist der Drucker online, wird der Upload-Container gestartet.
- Ist der Drucker offline, wird der Upload-Container gestoppt.
- Der Watchdog benötigt Zugriff auf `/var/run/docker.sock`.

**TODO:** Exakte Online-Prüfung, Timeout-, Retry- und Fehlerbehandlung sowie den
aktuellen Namen des Upload-Containers vom produktiven Nova auslesen.

> Sicherheitshinweis: Der Zugriff auf den Docker-Socket verleiht dem Watchdog
> weitreichende Kontrolle über den Host. Die spätere Implementierung muss diesen
> Zugriff ausdrücklich dokumentieren und auf den erforderlichen Umfang begrenzen,
> soweit dies technisch möglich ist.

## 10. MOTD und Statusübersicht

Die MOTD muss wieder vorhanden sein und mindestens folgende Informationen zeigen:

- Hostname
- Uptime
- Load
- Speicherplatz
- CPU-Temperatur
- Status von AdGuard Home
- Status von Unbound
- Status von WireGuard
- Status von Docker
- Status von Vaultwarden
- Status von Syncthing
- Status von DynDNS
- Status der Backups
- optional: Status des Prusa-Systems

**TODO:** Bestehende MOTD-Skripte, Ausgabe, Pfade und Statuslogik vom produktiven
Nova auslesen.

**TODO:** Für jeden Dienst festlegen, was die Zustände „gesund“, „gestört“ und
„nicht verfügbar“ konkret bedeuten.

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
| 2026-08-09 | Bestandsaufnahme von WireGuard und PiVPN einschließlich MTU-, Client- und Firewall-Strategie ergänzt |
| 2026-08-09 | Bestandsaufnahme von Unbound, AdGuard Home und DNS-Architektur ergänzt; Rolle von Atlas präzisiert |
| 2026-08-09 | Initiale Erfassung des bisher bekannten Sollzustands |
