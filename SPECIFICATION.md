# Spezifikation: Infrastruktur-Node „Nova“

## 1. Zweck und Zielbild

Dieses Repository beschreibt die spätere, vollständig reproduzierbare Installation
des Infrastruktur-Nodes **Nova** auf einem Raspberry Pi 5 ausgehend von einer
frischen Raspberry-Pi-OS-/Debian-13-Basis.

Langfristiges Ziel ist folgender Ablauf:

1. Eine frische und vollständig aktualisierte
   Raspberry-Pi-OS-/Debian-13-Basis bereitstellen.
2. Optional das Recovery-Medium `INFRA-RECOVERY` anschließen.
3. Die Installation über einen einzigen `curl`-Aufruf starten.
4. Den vollständigen, in diesem Dokument beschriebenen Nova-Sollzustand
   herstellen; fehlende optionale Secrets verhindern den Grundaufbau nicht.
5. Geschützte Anwendungsdaten bei Bedarf in den dokumentierten manuellen
   Restore-Schritten wiederherstellen.
6. Den Zustand durch Abschlussprüfung und Reboot-Test verifizieren.

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

### Architektur- und Wartungsgrundsätze

- Einfache, verständliche Standardkomponenten haben Vorrang vor technisch
  eleganten, aber schwer wartbaren Abstraktionen.
- Der Eigentümer muss das System auch nach längerer Zeit ohne Beschäftigung mit
  Nova verstehen und wiederherstellen können.
- Unnötige Abhängigkeiten zwischen Diensten werden vermieden. Der Ausfall einer
  Komfort- oder Speicherfunktion darf kritische Infrastruktur nicht mitreißen.
- Ein Neuaufbau anhand einer bekannten Spezifikation wird der Reparatur einer
  undurchsichtigen, historisch gewachsenen Installation vorgezogen.
- Git enthält reproduzierbare Konfiguration und Code. Das Recovery-Medium enthält
  ausschließlich nicht versionierbare Secrets und geschützte Restore-Daten.
- Codex ist ein Werkzeug zur Umsetzung der dokumentierten Architektur, nicht der
  Entscheidungsträger. Nicht ausdrücklich genehmigte architektonische
  Substitutionen sind unzulässig.

## 3. Zielplattform und Basissystem

| Merkmal | Sollzustand |
| --- | --- |
| Hardware | Raspberry Pi 5 |
| Architektur | ARM64 |
| Betriebssystem | Debian 13 (trixie) |
| Systemdatenträger | SSD |
| Zielbenutzer | `admin` mit UID/GID 1000 und Home `/home/admin` |
| Remote-Zugriff | SSH als `admin` |
| Zeitzone | `Europe/Zurich` |
| Locale | `en_GB.UTF-8` |
| Netzwerkmanager | NetworkManager |
| Hauptinterface | `eth0` |
| Container-Laufzeit | Docker Engine aus dem offiziellen Docker-Repository |
| Container-Orchestrierung | Docker Compose Plugin |
| Systemdienste | systemd Services und Timer |
| Anmeldung | MOTD mit Statusübersicht |

### 3.1 Benutzer und sudo

Der produktive Zielbenutzer ist `admin`:

- UID/GID: 1000
- Home: `/home/admin`
- Shell: `/bin/bash`
- Mitglied der benötigten Systemgruppen, insbesondere `sudo` und `docker`
- passwortloser sudo-Zugriff

Der spätere Installer geht von einem frisch installierten Debian-13-System aus
und stellt sicher, dass `admin` mit diesem Home und dieser Shell vorhanden ist,
Mitglied der für Nova benötigten Gruppen wird und sudo-Zugriff besitzt. Docker
muss nach der Installation ohne unnötige Workarounds durch `admin` verwendbar
sein. Der bestehende passwortlose sudo-Zugriff wird als Sollzustand übernommen.

Benutzerpasswörter dürfen weder im Repository gespeichert noch vom Installer
erzeugt werden.

### 3.2 SSH

Der SSH-Service ist auf dem produktiven Nova aktiviert und bleibt verbindlicher
Bestandteil des Sollzustands:

- Die Anmeldung als `admin` muss möglich sein.
- Key-basierter SSH-Zugriff muss funktionieren.
- Root-Login wird für den normalen Betrieb nicht benötigt.
- Es wird keine unnötig komplexe SSH-Hardening-Konfiguration eingeführt.
- Die bestehenden Debian-/OpenSSH-Defaults werden bevorzugt, solange sie für den
  vorgesehenen Betrieb geeignet sind.
- Der Installer darf SSH nicht versehentlich unzugänglich machen.

Private SSH-Schlüssel dürfen niemals im Repository gespeichert werden.

### 3.3 Zeit und Locale

Der verbindliche Sollzustand lautet:

- Zeitzone: `Europe/Zurich`
- Locale: `en_GB.UTF-8`
- NTP- beziehungsweise Systemzeitsynchronisation: aktiv

Die Systemzeit wird auf dem produktiven Nova erfolgreich synchronisiert.

### 3.4 Netzwerk

NetworkManager ist aktiviert und bleibt der Netzwerkmanager. Das produktive
Hauptinterface ist `eth0`. Die Basiskonfiguration muss zu folgenden bereits
dokumentierten Werten passen:

- Nova LAN-Adresse: `192.168.0.195/24`
- Gateway: `192.168.0.1`

Die genaue Methode der statischen beziehungsweise reservierten Adressvergabe wird
bei der Installer-Implementierung anhand des Testsystems festgelegt. Docker-,
WireGuard- und temporäre virtuelle Interfaces dürfen nicht als statische
Basiskonfiguration übernommen werden. `wlan0` wird für den normalen Nova-Betrieb
nicht benötigt.

**TODO (Atlas):** Die reproduzierbare Methode der Adressvergabe mit
NetworkManager auf dem Testsystem festlegen und validieren.

### 3.5 Automatische Updates

Auf dem produktiven Nova ist `unattended-upgrades` installiert und
`apt-daily-upgrade.timer` aktiviert. Für den Sollzustand gilt:

- `unattended-upgrades` ist installiert und aktiviert.
- Die systemeigenen APT-Timer dürfen verwendet werden.
- Es wird keine parallele eigene Update-Automatik entwickelt, solange Debian
  diese Aufgabe zuverlässig übernimmt.

### 3.6 Docker

Der aktuelle produktive Stand ist:

- Docker Engine 29.7.2
- Docker Compose v5.4.0
- `docker-ce`
- `docker-ce-cli`
- `containerd.io`
- `docker-compose-plugin`

Docker wird aus dem offiziellen Docker-APT-Repository installiert:

```text
https://download.docker.com/linux/debian
```

Der spätere Installer muss:

- das offizielle Docker-Repository reproduzierbar einrichten
- den offiziellen Repository-Keyring verwenden
- Docker Engine und Docker CLI installieren
- `containerd.io` installieren
- das Docker Compose Plugin installieren
- `admin` in die Gruppe `docker` aufnehmen
- den Docker-Service aktivieren
- vermeiden, auf eine möglicherweise ältere Docker-Version aus den
  Debian-Standardpaketen zurückzufallen

Die aktuell installierten Versionsnummern werden nicht fest gepinnt, sofern die
`vaultwarden-appliance` keine konkrete Version verlangt. Ziel ist der jeweils
aktuelle stabile Stand aus dem offiziellen Docker-Repository für Debian 13.

### 3.7 Syncthing-Repository

Der bereits dokumentierte Syncthing-Sollzustand wird bestätigt. Der aktuelle
produktive Stand lautet:

- Syncthing 2.1.3
- offizielles Repository: `https://apt.syncthing.net/`
- Channel: `syncthing stable-v2`
- Keyring: `/etc/apt/keyrings/syncthing-archive-keyring.gpg`

Der spätere Installer richtet dieses offizielle Repository und dessen Keyring
reproduzierbar ein. Er darf nicht auf die möglicherweise ältere Version aus
Debian `trixie/main` zurückfallen.

### 3.8 Grundpakete

Nach aktuellem Stand werden mindestens folgende Basiswerkzeuge benötigt:

- `ca-certificates`
- `curl`
- `git`
- `gnupg`
- `jq`
- `rsync`
- `unattended-upgrades`
- `wireguard-tools`

`nftables` ist aktuell installiert, wird beim Neuaufbau jedoch nur verwendet,
wenn es für die tatsächliche Nova-Konfiguration benötigt wird. Eine zusätzliche
restriktive nftables-Firewall wird nicht allein aus Prinzip eingeführt.

Weitere Pakete dürfen später ergänzt werden, wenn ein dokumentierter Dienst sie
tatsächlich benötigt.

### 3.9 `/opt`-Verzeichnisstruktur

Der aktuell produktive `/opt`-Baum enthält unter anderem:

- `/opt/AdGuardHome`
- `/opt/backups`
- `/opt/vaultwarden`

Der alte produktive Vaultwarden-Baum dient nur als Referenz und wird nicht 1:1
übernommen. Für Vaultwarden bleibt die `vaultwarden-appliance` maßgeblich. Die
endgültige `/opt`-Struktur entsteht aus den jeweiligen Dienst-Spezifikationen und
wird nicht blind vom alten Nova kopiert.

### 3.10 Bootstrap-Grundsatz

Der spätere Bootstrap geht von einem möglichst sauberen Debian-13-System aus. Er
stellt alle zusätzlich benötigten Pakete, APT-Repositories, Keyrings, Dienste und
Verzeichnisse selbst reproduzierbar her.

Der vorgesehene Ausgangszustand von Atlas ist:

- frisches Debian 13
- vollständig aktualisiertes System
- vorhandener SSH-Zugriff
- ansonsten möglichst keine vorausgesetzte Spezialkonfiguration

**TODO:** Aktuelle Partitionierung, Dateisysteme und Mountpoints der produktiven
SSD nur dann ergänzend erfassen, wenn sie für den reproduzierbaren Bootstrap oder
die späteren Restore-Abläufe relevant sind.

## 4. DNS

### 4.1 AdGuard Home

Die bestehende produktive AdGuard-Konfiguration dient als Referenz und wird
weitgehend übernommen. Historische oder künftig nicht mehr benötigte
Atlas-Einträge werden entfernt.

#### 4.1.1 Installation und Aufgaben

- Produktive Referenzversion: AdGuard Home v0.107.78
- Native Installation unter `/opt/AdGuardHome`
- systemd-Service: `AdGuardHome.service`
- Produktive Referenzkonfiguration:
  `/opt/AdGuardHome/AdGuardHome.yaml`
- DNS: TCP/UDP Port 53
- Weboberfläche: Port 3000
- DHCP: deaktiviert
- AdGuard-eigener DNS-Cache: bewusst deaktiviert
- DNSSEC in AdGuard: deaktiviert
- Filterung und Protection: aktiviert

Resolver-, Cache- und DNSSEC-Aufgaben liegen bei Unbound. Die DNS-Funktion muss
später durch Healthchecks geprüft werden.

AdGuard Home wird beim Neuaufbau erst nahe dem Ende installiert und konfiguriert.
Unbound muss zuvor auf Port 5335 unabhängig getestet sein, und alle benötigten
APT-Downloads sowie Docker-Pulls müssen abgeschlossen sein. Dadurch bleibt die
bestehende DNS-Funktion bis zum bewusst ausgeführten finalen DNS-Umschalten
unangetastet.

Der bestehende Web-UI-Zugang wird über `ADGUARD_PASSWORD_HASH` aus dem
Recovery-Secret wiederhergestellt. Ein Klartextpasswort wird weder benötigt noch
gespeichert.

#### 4.1.2 Upstreams, Fallback und Bootstrap

Der zukünftige produktive AdGuard verwendet genau zwei reguläre interne
DNS-Upstreams:

- `127.0.0.1:5335` — lokaler Unbound auf Nova
- `192.168.0.193:5335` — Unbound auf Arc

`upstream_mode: parallel` wird beibehalten. Die beiden internen
Unbound-Instanzen bilden die gewünschte DNS-Redundanz.

Nicht migriert werden:

- `192.168.0.192:5335` — ehemaliger Atlas-Upstream
- der derzeit auskommentierte öffentliche Quad9-DoH-Upstream

Atlas wird ausschließlich als Testsystem verwendet und ist kein Bestandteil der
produktiven DNS-Infrastruktur.

Die bisherigen öffentlichen Fallback-Resolver werden nicht übernommen. Google,
Cloudflare und direkte öffentliche Quad9-Resolver dürfen nicht als
AdGuard-Fallback verwendet werden. `fallback_dns` bleibt im neuen Sollzustand
leer. DNS soll sichtbar fehlschlagen, wenn beide vorgesehenen internen
Unbound-Instanzen nicht verfügbar sind, statt die definierte Resolver-Kette
unbemerkt zu umgehen.

Davon unabhängig dürfen die bestehenden `bootstrap_dns` beibehalten werden:

- `9.9.9.10`
- `149.112.112.10`

#### 4.1.3 Lokale DNS-Rewrites und Caddy

Lokale DNS-Rewrites werden getrennt von der kritischen DNS-Resolver-Funktion
dokumentiert und umgesetzt. Sie sind für interne Namen und HTTPS-Komfort relevant,
aber nicht Voraussetzung für die grundlegende externe DNS-Auflösung.

Folgende Rewrites werden übernommen:

| Hostname | Zieladresse |
| --- | --- |
| `arc.lan` | `192.168.0.193` |
| `ds3.lan` | `192.168.0.195` |
| `adguard-nova.lan` | `192.168.0.195` |
| `adguard-arc.lan` | `192.168.0.195` |
| `vault.lan` | `192.168.0.195` |
| `nova.lan` | `192.168.0.195` |
| `syncthing-nova.lan` | `192.168.0.195` |
| `syncthing-ds3.lan` | `192.168.0.195` |

Die auf `192.168.0.195` zeigenden Einträge sind absichtlich so konfiguriert.
Diese Adresse gehört Nova und dient für die lokalen HTTPS-Namen als
Caddy-Reverse-Proxy-Endpunkt. Caddy leitet anschließend an die jeweiligen
eigentlichen Backends weiter. Die Rewrites dürfen daher nicht automatisch auf
die Backend-Adressen „korrigiert“ werden.

Der historische Rewrite `atlas.lan -> 192.168.0.192` wird nicht migriert.

#### 4.1.4 Filter

Folgende bestehende produktive Filterlisten werden übernommen:

- AdGuard DNS filter
- AdAway Default Blocklist
- HaGeZi's Normal Blocklist
- HaGeZi's Allowlist Referral

Die bestehenden lokalen User-Rules werden ebenfalls übernommen. Filterlisten
werden weder allein aus Prinzip ergänzt noch durch vermeintlich bessere Listen
ersetzt.

#### 4.1.5 Laufzeitdaten

Folgende Laufzeitdaten sind nicht Bestandteil des reproduzierbaren
Infrastrukturzustands und müssen beim Neuaufbau nicht restauriert werden:

- `querylog.json`
- `stats.db`
- `sessions.db`

#### 4.1.6 Konfigurationsstrategie

Die bestehende `/opt/AdGuardHome/AdGuardHome.yaml` dient als Referenz für den
späteren reproduzierbaren Sollzustand. Dabei gelten folgende Vorgaben:

- bewährte DNS- und Filterparameter erhalten
- Atlas-Einträge entfernen
- keine unnötigen historischen Laufzeitdaten übernehmen
- keine eigenständigen „Optimierungen“ der getesteten DNS-Architektur durchführen
- keine Secrets ins Repository übernehmen

### 4.2 Unbound

- Unbound dient als lokaler Resolver.
- Installierte Debian-Paketversion: Unbound 1.22.0
- Unbound läuft nativ als `unbound.service`.
- Das Debian-13-systemd-Unit startet Unbound mit
  `/usr/sbin/unbound -d -p`. Durch `-p` wird kein PID-File verwendet; die von
  `nova-infra` verwaltete Konfiguration darf daher keine `pidfile`-Direktive
  definieren.
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
- Beim Neuaufbau muss die Konfiguration zunächst mit `unbound-checkconf` validiert
  werden.
- Anschließend muss die DNS- beziehungsweise Resolver-Funktion durch einen
  Healthcheck geprüft werden.

#### Konfigurationslayout und DNSSEC

Die Debian-Paketkonfiguration bleibt soweit praktisch unverändert. `nova-infra`
installiert genau eine eigene, eindeutig verwaltete Include-Datei unter:

```text
/etc/unbound/unbound.conf.d/nova.conf
```

Die produktive historische Doppelung zwischen `/etc/unbound/unbound.conf` und
`50-custom.conf` wird nicht reproduziert. Insbesondere werden `50-custom.conf`
und `99-modules.conf` nicht migriert. Paketverwaltete Dateien werden nicht
unnötig ersetzt oder dupliziert.

Für den DNSSEC-Trust-Anchor bleibt ausschließlich die Integration des
Debian-Pakets maßgeblich:

```text
/etc/unbound/unbound.conf.d/root-auto-trust-anchor-file.conf
```

Die von `nova-infra` verwaltete Datei definiert deshalb keine zusätzliche
`auto-trust-anchor-file`-Direktive. Die Modulkonfiguration bleibt
`module-config: "validator iterator"`.

#### Verbindliche Server- und Zugriffseinstellungen

Die folgenden Werte sind der verbindliche Zielzustand:

| Einstellung | Wert |
| --- | --- |
| `chroot` | `""` |
| `verbosity` | `1` |
| `interface` | `0.0.0.0` |
| `port` | `5335` |
| `do-ip4` | `yes` |
| `do-ip6` | `no` |
| `do-udp` | `yes` |
| `do-tcp` | `yes` |
| `root-hints` | `/var/lib/unbound/root.hints` |
| `hide-identity` | `yes` |
| `hide-version` | `yes` |
| `harden-algo-downgrade` | `yes` |
| `harden-referral-path` | `yes` |
| `harden-glue` | `yes` |
| `harden-dnssec-stripped` | `yes` |
| `harden-below-nxdomain` | `yes` |
| `qname-minimisation` | `yes` |
| `aggressive-nsec` | `yes` |

Folgende Zugriffskontrollen werden exakt übernommen:

| Netz | Aktion |
| --- | --- |
| `127.0.0.0/8` | `allow` |
| `10.0.0.0/8` | `allow` |
| `192.168.0.0/16` | `allow` |
| `10.8.0.0/16` | `allow` |

Unbound lauscht damit über IPv4 auf Port 5335 und übernimmt nicht Port 53.
IPv6 bleibt für Unbound deaktiviert.

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

### 4.3 DNS-Zusammenspiel

Der geplante normale DNS-Pfad lautet:

```text
Clients
  -> AdGuard Home auf Nova (TCP/UDP Port 53)
  -> parallel:
     - Unbound auf Nova (127.0.0.1:5335)
     - Unbound auf Arc (192.168.0.193:5335)
  -> Upstream- beziehungsweise rekursive Auflösung gemäß Unbound-Konfiguration
```

AdGuard Home übernimmt dabei Filterung und Protection. Die Resolver-Funktion
einschließlich DNSSEC-Verarbeitung, Cache und eigentlicher Auflösung liegt bei den
Unbound-Instanzen.

Unbound wird vor AdGuard eingerichtet und unabhängig auf Port 5335 validiert.
AdGuard übernimmt Port 53 erst in der späten DNS-Phase des Neuaufbaus. Der
kritische DNS-Wechsel darf nicht vor Abschluss aller Paketdownloads und
Container-Pulls stattfinden.

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
- FreeDNS wird mit dem vollständigen Wert von `DYNDNS_URL` aufgerufen.
- `DYNDNS_URL` stammt bevorzugt aus `/secrets/secrets.env` auf dem Recovery-Medium
  mit dem Dateisystem-Label `INFRA-RECOVERY` und wird für die Installation sicher
  lokal bereitgestellt.
- Die nicht geheime Skriptlogik darf später im Repository gespeichert werden.
- Das Secret wird zur Laufzeit aus einer separaten lokalen, nur für `root`
  lesbaren Konfigurations- oder Environment-Datei geladen.
- Eine Beispiel- oder Template-Datei ohne Secret darf im Repository gespeichert
  werden.

Fehlt `DYNDNS_URL`, wird der Platzhalter `CHANGE_ME_DYNDNS_URL` verwendet und
DynDNS bleibt deaktiviert beziehungsweise meldet klar, dass eine manuelle
Vervollständigung erforderlich ist. Der Platzhalter darf niemals als Update-URL
ausgeführt werden.

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

### 7.1 Maßgebliche Implementierung

Vaultwarden wird in `nova-infra` nicht neu implementiert. Die bereits fertig
entwickelte `vaultwarden-appliance` ist die maßgebliche Implementierung und wird
1:1 verwendet. Sie wird weder dupliziert noch als Copy-and-Paste-Fork in dieses
Repository übernommen.

Die Zuständigkeit der Appliance umfasst insbesondere:

- Vaultwarden
- Docker- und Compose-Konfiguration
- Caddy
- lokale HTTPS- und CA-Architektur
- `vwctl`
- Backup-Implementierung
- Backup-Validierung
- lokale Backup-Retention
- USB-Unterstützung
- systemd Backup-Service und Timer
- Status- und Restore-Funktionen der Appliance
- alle dort bereits implementierten Sicherheits- und Validierungsmechanismen

`nova-infra` darf diese Funktionen nicht parallel neu implementieren.
Vaultwarden bleibt dabei soweit praktisch logisch von der allgemeinen
Nova-Infrastruktur getrennt. Die Kerninstallation muss unabhängig verständlich
und wiederherstellbar bleiben.

### 7.2 Installation und Orchestrierung

Der spätere `nova-infra`-Installer verwendet den vorhandenen curl-basierten
Installer des Projekts `vaultwarden-appliance`:

```text
nova-infra
  -> bestehender curl-Installer von vaultwarden-appliance
  -> vollständig installierte Vaultwarden-Appliance auf Nova
```

`nova-infra` übernimmt dabei ausschließlich die Orchestrierung. Die genaue URL
und der konkrete Aufruf werden bei der späteren Implementierung aus dem
bestehenden Projekt übernommen und nicht neu erfunden.

**TODO:** Bei der späteren Implementierung die maßgebliche Installer-URL und den
konkreten Aufruf direkt aus `vaultwarden-appliance` übernehmen.

### 7.3 Datenpfade

Die von der Vaultwarden-Appliance definierten Pfade bleiben unverändert
maßgeblich:

- Live-Daten: `/opt/vaultwarden/data`
- lokale Backups: `/opt/vaultwarden/backups`

Die Backup-Architektur der Appliance wird durch `nova-infra` nicht verändert.

### 7.4 Disaster Recovery

Nach einer vollständigen Neuinstallation von Nova sind für Vaultwarden bewusst
einmalige manuelle Restore-Schritte vorgesehen. Manuell wiederhergestellt werden
insbesondere:

- bestehende Vaultwarden-Daten
- benötigte Caddy-Zertifikats- und CA-Daten, damit die bestehende lokale
  Vertrauenskette erhalten werden kann

Dieser manuelle Import ist akzeptiert und wird nicht zwanghaft vollständig
automatisiert. Der Infrastrukturaufbau soll automatisiert sein; das Einspielen
der sensitiven produktiven Daten darf ein klar dokumentierter manueller Schritt
bleiben. Ein vollständig unbeaufsichtigter Restore aller Secrets und Nutzdaten
ist ausdrücklich nicht das Ziel.

Secrets, private Schlüssel, CA-Private-Key-Material und produktive
Vaultwarden-Daten dürfen niemals im Git-Repository von `nova-infra` gespeichert
werden.

**TODO:** Den einmaligen manuellen Restore-Ablauf anhand der vorhandenen
Appliance-Funktionen dokumentieren, ohne geheime oder produktive Daten in das
Repository zu übernehmen.

### 7.5 Caddy-Integration

#### 7.5.1 Architektur

Nova verwendet genau eine gemeinsame Caddy-Instanz als lokalen
HTTPS-Reverse-Proxy. Diese Instanz wird zuerst durch den bestehenden Installer von
`vaultwarden-appliance` installiert. `nova-infra` installiert keine zweite
Caddy-Instanz.

Vaultwarden ist der primäre Grund für Caddy und dessen interne Root-CA. Der
Nova-Installer darf eine vorhandene Caddy-Konfiguration niemals blind
überschreiben.

Nach erfolgreicher Installation der Vaultwarden-Appliance ergänzt `nova-infra`
die zusätzlich für Nova benötigten lokalen Reverse-Proxy-Einträge
reproduzierbar, ohne die vorhandene Caddy-Konfiguration der Appliance zu
beschädigen.

Eine einzelne, verständliche Caddyfile-Konfiguration wird bevorzugt. Sie wird
nicht ohne konkreten Bedarf in zahlreiche Dateien oder abstrakte Fragmente
zerlegt. Zusätzliche lokale Hosts dürfen nach Abschluss der
Vaultwarden-/Caddy-Kerninstallation als klar markierte zusätzliche Host-Blöcke in
die bestehende Caddyfile eingefügt werden. Die Ergänzung erfolgt kontrolliert und
idempotent, nicht durch blindes Überschreiben oder wiederholtes Anhängen.

Alle betreffenden lokalen Dienste verwenden Caddys interne CA über
`tls internal`. Clients können dadurch nach Installation des Root-CA-Zertifikats
ohne Zertifikatswarnungen auf die lokalen HTTPS-Dienste zugreifen.

#### 7.5.2 Lokale HTTPS-Ziele

Die folgenden produktiven Zuordnungen wurden auf Nova inventarisiert und bleiben
grundsätzlich erhalten:

| Hostname | Backend | TLS | Besonderheit |
| --- | --- | --- | --- |
| `vault.lan` | `vaultwarden:80` | internal | HTTP wird auf HTTPS umgeleitet |
| `adguard-nova.lan` | `192.168.0.195:3000` | internal | AdGuard Home auf Nova |
| `adguard-arc.lan` | `192.168.0.193:80` | internal | AdGuard Home auf Arc |
| `ds3.lan` | `192.168.0.100:5000` | internal | DSM auf `Diskstation3` |
| `syncthing-ds3.lan` | `192.168.0.100:8384` | internal | Syncthing auf `Diskstation3` |
| `syncthing-nova.lan` | `192.168.0.195:8384` | internal | Syncthing auf Nova |

Die Hostnamen müssen mit den entsprechenden AdGuard-DNS-Rewrites abgestimmt
sein. Da der HTTPS-Zugriff über den gemeinsamen Caddy auf Nova erfolgt, zeigen
die betreffenden Rewrites bewusst auf Novas LAN-Adresse `192.168.0.195`, auch
wenn Caddy anschließend an einen Dienst auf einem anderen Host weiterleitet.
Diese Rewrites dürfen nicht automatisch auf die jeweilige Backend-Adresse
„korrigiert“ werden.

Die gemeinsame Caddy-Instanz bedient damit:

- Vaultwarden
- AdGuard Home auf Nova
- AdGuard Home auf Arc
- DSM auf `Diskstation3`
- Syncthing auf `Diskstation3`
- Syncthing auf Nova

Mit Ausnahme des Vaultwarden-Kerns sind diese zusätzlichen lokalen HTTPS-Hosts
Komfortfunktionen. Sie nutzen die ohnehin vorhandene interne Root-CA, um
Browserwarnungen zu vermeiden. Ihr Fehlen darf die Kerninfrastruktur und
insbesondere Vaultwarden, DNS, VPN oder lokale Backups nicht funktionsunfähig
machen.

#### 7.5.3 Nicht zu migrierende Altbestände

- Der alte auskommentierte Eintrag `syncthing-lumen.lan` wird nicht migriert.
- MediaMTX ist kein Bestandteil der zukünftigen Caddy-Konfiguration.

Der aktuell produktive alte Nova-Vaultwarden-Stack verwendet unter anderem:

- `/opt/vaultwarden/vw-data`
- `/opt/vaultwarden/caddy-data`
- `/opt/vaultwarden/caddy-config`

Diese alte Compose- und Verzeichnisstruktur dient ausschließlich als Referenz und
ist nicht der zukünftige Sollzustand. Für den Neuaufbau ist nur die bereits
spezifizierte und gebaute `vaultwarden-appliance` maßgeblich. Daher gelten
folgende Vorgaben:

- Den alten Nova-Compose-Stack nicht kopieren.
- Die alten Vaultwarden-Pfade nicht als neue Sollstruktur übernehmen.
- Vaultwarden und Caddy zuerst über den bestehenden Installer von
  `vaultwarden-appliance` installieren.
- Anschließend ausschließlich die zusätzlichen lokalen Nova-Caddy-Einträge
  reproduzierbar ergänzen.

#### 7.5.4 Zertifikate und interne CA

Die persistierenden Daten der bestehenden Caddy-CA werden beim Disaster Recovery
manuell aus dem geschützten Backup wiederhergestellt. Private CA-Schlüssel und
anderes geheimes Zertifikatsmaterial dürfen niemals im Git-Repository von
`nova-infra` gespeichert werden.

`nova-infra` erfindet die bestehende Vertrauenskette nicht neu, sondern baut auf
der Caddy- und CA-Architektur der Vaultwarden-Appliance auf.

### 7.6 Backup und Syncthing

Die Vaultwarden-Appliance erstellt weiterhin selbstständig ihre validierten
lokalen Backups unter `/opt/vaultwarden/backups`. Syncthing wird von `nova-infra`
lediglich als nachgelagerte, unabhängige Replikation dieses Verzeichnisses zu
`Diskstation3` eingerichtet. Die Vaultwarden-Appliance wird dafür nicht verändert.

```text
Vaultwarden
  -> vwctl backup
  -> /opt/vaultwarden/backups
  -> Syncthing (sendonly)
  -> Diskstation3
```

### 7.7 Abgrenzung der Projekte

| Projekt | Verantwortung |
| --- | --- |
| `vaultwarden-appliance` | Vaultwarden, Caddy innerhalb der Appliance, `vwctl`, Backup, Restore und Appliance-Funktionalität |
| `nova-infra` | Gesamter Nova Infrastructure Node sowie Installation und Integration der fertigen Appliance in DNS, Syncthing, MOTD und die übrige Nova-Infrastruktur |

Die Schnittstelle zwischen beiden Projekten bleibt eine Orchestrierung der
fertigen Appliance; deren Implementierung wird nicht nach `nova-infra` kopiert.

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

`Diskstation3` beziehungsweise die Synology ist primär ein Daten- und
Speicherziel, kein kritischer Infrastrukturserver. Sie übernimmt derzeit
Speicheraufgaben, Syncthing-/Borg-bezogene Datenfunktionen und ein angeschlossenes
Backup-Laufwerk. DNS, VPN, Vaultwarden-Kernbetrieb und andere kritische
Nova-Funktionen dürfen nicht von ihrer Verfügbarkeit abhängen. Die
Recovery-Architektur bleibt soweit praktisch plattformunabhängig, damit eine
Synology nicht zwingende Voraussetzung für den Neuaufbau ist.

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
Vaultwarden-Appliance und bleibt ebenfalls unabhängig von Syncthing. Ein dafür
verwendetes Backup-Medium ist konzeptionell vom Bootstrap-/Recovery-Stick
`INFRA-RECOVERY` getrennt. `INFRA-RECOVERY` wird nicht als normales
Vaultwarden-USB-Backupmedium verwendet.

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
`jtee3d/prusa_connect_rtsp:latest` realisiert. Die Docker-basierte Lösung ist der
verbindliche Sollzustand; eine zwischenzeitlich erwogene native
systemd-/FFmpeg-Implementierung ist obsolet und wird nicht übernommen. Es wird
keine eigene Upload-Anwendung entwickelt.

Die Verwendung von `latest` ist derzeit eine bewusste Entscheidung. Eine feste
Tag- oder Digest-Pinnung darf später neu bewertet werden, falls eine strengere
Reproduzierbarkeit wichtiger wird; sie ist aktuell keine Anforderung.

Die sensitiven Werte stammen vom Recovery-Medium `INFRA-RECOVERY`:

- `CAMERA_URL` enthält die vollständige RTSP-URL einschließlich der
  Kamera-Zugangsdaten.
- `TOKEN` enthält das Prusa-Connect-Token.

`CAMERA_URL`, `TOKEN` und andere sensitive Werte dürfen niemals im
Git-Repository gespeichert werden. Nicht geheime Werte wie Fingerprint,
Verzögerungen, Drucker-IP und Monitorverhalten gehören dagegen in die
versionierte Konfiguration und nicht auf das Recovery-Medium.

Der Kamera-Container erhält einen festen `container_name`, damit der Monitor nicht
von automatisch erzeugten Compose-Namen abhängt. Als verbindlicher logischer Name
wird `prusa-connect-rtsp` verwendet.

**TODO:** Bei der späteren Implementierung die nicht geheimen Container-Parameter
und den Netzwerkmodus anhand der Image-Anforderungen festlegen.

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

Auch der Monitor wird als Docker-Container und nicht als nativer
systemd-/FFmpeg-Dienst umgesetzt. Er verwendet für den Kamera-Container den festen
Namen `prusa-connect-rtsp` und darf nicht von generierten Compose-Namen abhängen.

Die verbindliche Logik lautet:

- Der Watchdog prüft `192.168.0.61` alle 30 Sekunden per Ping.
- Ist der Drucker erreichbar, prüft der Watchdog, ob der Upload-Container läuft,
  und startet ihn andernfalls.
- Ist der Drucker nicht erreichbar, prüft der Watchdog, ob der Upload-Container
  läuft, und stoppt ihn gegebenenfalls.
- Die Logik bleibt funktional einfach und wird nicht unnötig erweitert.

Die bisherige Synology-/Portainer-Lösung verwendete einen Alpine-Container und
installierte beziehungsweise verwendete `iputils` und `docker-cli`. Diese bereits
bewährte einfache Alpine-basierte Monitor-Lösung wird für Nova bevorzugt. Ein
eigenes Watchdog-Image wird weder verlangt noch bevorzugt. Der Monitor bindet
`/var/run/docker.sock` ein und verwendet `docker-cli`; die Watchdog-Logik bleibt
absichtlich einfach.

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
- `prusa-connect-rtsp` läuft, wenn der Drucker erreichbar ist.
- `prusa-connect-rtsp` ist `stopped` oder `exited`, wenn der Drucker ausgeschaltet
  ist.

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

- `jtee3d/prusa_connect_rtsp:latest` als `prusa-connect-rtsp`
- ein einfacher Alpine-basierter `prusa-monitor`-Watchdog

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

## 11. Secrets und Disaster Recovery

### 11.1 Grundprinzip und Repository-Regeln

Das Git-Repository `nova-infra` bleibt vollständig frei von Secrets und
produktiven privaten Schlüsseln. Die komplette reproduzierbare Infrastruktur
gehört ins Repository; maschinenspezifische Secrets und Restore-Daten werden
separat lokal auf einem geschützten Restore-Medium, beispielsweise einem
geschützten USB-Stick, aufbewahrt.

Es wird kein zusätzliches komplexes Secret-Management-System eingeführt.

Folgende Inhalte dürfen niemals im Repository gespeichert werden:

- Passwörter
- API-Tokens
- private Keys
- Zertifikats-Secrets und CA-Private-Key-Material
- produktive Daten und Backupgenerationen
- sonstige geheime Zugangsdaten

Private LAN-IP-Adressen dürfen im Repository dokumentiert werden.

Zusätzlich gelten folgende Grundsätze:

- Bestehende bewährte Konfigurationen werden bevorzugt übernommen, statt neu
  erfunden zu werden.
- Standardsoftware wird möglichst über vorhandene Debian-Pakete oder gepflegte
  Docker-Images eingesetzt.
- Konfigurationen trennen klar zwischen nicht geheimen, versionierbaren Anteilen
  und separat bereitzustellenden Secrets.
- Beispiele und Vorlagen für geheime Werte enthalten ausschließlich leere oder
  offensichtlich nicht produktive Platzhalter.
- Es werden keine Secrets unnötig erhoben oder in lokale Secret-Dateien
  aufgenommen.

**TODO:** Vor der späteren Übernahme bestehender Dateien jede Konfiguration auf
eingebettete Secrets prüfen und diese auslagern.

### 11.2 Lokale Installer-Secrets

Bevorzugte Recovery-Quelle ist ein entfernbarer USB-Stick mit ext4-Dateisystem
und dem Dateisystem-Label `INFRA-RECOVERY`. Der Installer sucht das Medium anhand
des Labels; ein bestimmter Mountpoint wird nicht fest vorausgesetzt.

`INFRA-RECOVERY` ist ein allgemeines, hostunabhängiges
Infrastruktur-Bootstrap- und Recovery-Medium und nicht dauerhaft an den Hostnamen
Nova gebunden. Die aktuelle `/secrets/secrets.env` enthält die für Nova
benötigten Secrets. Dasselbe Medienkonzept soll später auch für Arc oder einen
anderen Ersatz-Infrastrukturhost verwendbar bleiben. Eine Multi-Host-
Verzeichnisstruktur wird derzeit ausdrücklich nicht eingeführt; die einfache
Struktur bleibt unverändert.

Auf dem Medium liegt die Secret-Datei unter:

```text
/secrets/secrets.env
```

Für die lokale Verwendung darf sie nach folgendem Pfad übernommen werden:

```text
/opt/nova-bootstrap/secrets.env
```

Für diese Datei gelten folgende Anforderungen:

- Sie liegt niemals im Git-Repository.
- Die produktive Quelle liegt auf `INFRA-RECOVERY` und niemals im Repository.
- Eine lokale Kopie wird nur bei vorhandenem Recovery-Medium sicher auf den
  jeweiligen Zielhost übernommen; für Nova gilt der oben genannte lokale Pfad.
- Eigentümer und Gruppe sind `root:root`.
- Der Dateimodus ist `0600`.
- Der spätere Installer verwendet sie ausschließlich lesend.
- Sie enthält nur einfache Konfigurationswerte und Secrets, die während der
  Installation tatsächlich benötigt werden.

Nach aktuellem Stand gehören insbesondere folgende Variablen hinein:

- `DYNDNS_URL`
- `CAMERA_URL`
- `TOKEN`
- `ADGUARD_PASSWORD_HASH`
- `WG_EASY_PASSWORD`

`CAMERA_URL` enthält die vollständige RTSP-URL einschließlich eventueller
Kamera-Zugangsdaten und wird vollständig als Secret behandelt. `TOKEN` ist das
Prusa-Connect-Token. `ADGUARD_PASSWORD_HASH` enthält ausschließlich den
vorhandenen Passwort-Hash für die AdGuard-Weboberfläche, niemals das
Klartextpasswort. `WG_EASY_PASSWORD` ist das für eine spätere wg-easy-
Integration vorgesehene Zugangspasswort; Phase 1 installiert oder konfiguriert
wg-easy nicht.

Weitere Variablen dürfen während der späteren Implementierung nur ergänzt werden,
wenn ein tatsächlicher Bedarf besteht.

Fehlt `INFRA-RECOVERY`, muss die Installation trotzdem fortgesetzt werden können.
Fehlende Werte werden durch eindeutige Platzhalter mit dem Präfix `CHANGE_ME_`
repräsentiert. Dienste, die ein fehlendes Secret zwingend benötigen, bleiben
deaktiviert oder melden klar, dass eine manuelle Vervollständigung erforderlich
ist.

### 11.3 Repository-Vorlage

Bei der späteren Implementierung wird im Repository eine Vorlage wie
`secrets.env.example` bereitgestellt. Sie enthält ausschließlich Variablennamen
und leere oder offensichtlich nicht produktive Platzhalter, beispielsweise:

```dotenv
DYNDNS_URL="CHANGE_ME_DYNDNS_URL"
CAMERA_URL="CHANGE_ME_CAMERA_URL"
TOKEN="CHANGE_ME_TOKEN"
ADGUARD_PASSWORD_HASH="CHANGE_ME_ADGUARD_PASSWORD_HASH"
WG_EASY_PASSWORD="CHANGE_ME_WG_EASY_PASSWORD"
```

Die produktive `secrets.env` muss durch `.gitignore` ausgeschlossen werden. In
dieser Spezifikationsphase werden weder die Vorlage noch eine `.env`- oder
`.gitignore`-Datei erstellt.

### 11.4 Dateibasierte Restore-Daten

Binäre Daten, Konfigurationsdateien, Datenbanken, Zertifikate und private Schlüssel
werden nicht künstlich als Environment-Variablen gespeichert. Insbesondere
gehören nicht in `secrets.env`:

- Syncthing `config.xml`
- Syncthing `key.pem`
- Syncthing `cert.pem`
- Vaultwarden-Backupgenerationen
- Caddy-CA-Daten
- Vaultwarden-Datenbanken
- sonstige größere Restore-Artefakte

Größere Restore-Daten, insbesondere Vaultwarden-Backupgenerationen und
Vaultwarden-Datenbanken, verbleiben auf den dafür vorgesehenen normalen
Backup-Zielen und werden nicht standardmäßig auf `INFRA-RECOVERY` gespeichert.
Der Bereich `/backup/` auf `INFRA-RECOVERY` bleibt ausschließlich für kleine,
manuell ausgewählte, essenzielle Recovery-Artefakte reserviert, falls diese
später tatsächlich benötigt werden. Der genaue Mountpoint wird nicht fest
verdrahtet.

Die verbindliche oberste Struktur des ext4-Mediums lautet:

```text
INFRA-RECOVERY (filesystem label)
├── secrets/
│   └── secrets.env
├── backup/
└── README.txt
```

Die interne Struktur von `/backup/` wird erst festgelegt, wenn konkrete kleine
Recovery-Artefakte ausgewählt wurden. Reproduzierbare Konfigurationen und Code
gehören nicht auf das Recovery-Medium, sondern in Git. Eine gegebenenfalls dort
gesicherte Syncthing-`config.xml` gilt wegen ihrer gerätebezogenen Identitätsdaten
als geschütztes Restore-Artefakt und nicht als allgemeine reproduzierbare
Konfigurationsquelle.

### 11.5 Wiederherstellung von Syncthing

Für die Wiederherstellung der bestehenden Syncthing-Geräteidentität werden
separat gesichert:

- `config.xml`
- `key.pem`
- `cert.pem`

Diese Dateien werden beim Disaster Recovery gezielt an die in Abschnitt 8.5
dokumentierten Syncthing-Pfade zurückgespielt. `key.pem` ist Secret-Material und
darf niemals ins Repository gelangen.

### 11.6 Wiederherstellung von Vaultwarden und Caddy

Vaultwarden wird weiterhin über die bestehende `vaultwarden-appliance`
installiert. Anschließend wird eine gültige vorhandene
Vaultwarden-Backupgeneration manuell über die von der Appliance bereitgestellte
Restore-Funktion wiederhergestellt. Diese Generation stammt normalerweise aus
der regulären Vaultwarden-Backuparchitektur und nicht von `INFRA-RECOVERY`.

Die Vaultwarden-Backups enthalten gemäß der bestehenden Appliance-Spezifikation
auch die benötigten persistenten Caddy-Daten einschließlich der internen CA. So
kann die bestehende lokale Caddy-Vertrauenskette nach einem Disaster Recovery
erhalten bleiben.

Vaultwarden-Backupgenerationen und privates Caddy- beziehungsweise
CA-Schlüsselmaterial dürfen niemals im Git-Repository gespeichert werden.

### 11.7 WireGuard nach Disaster Recovery

Bestehende private WireGuard-Client-Keys und Preshared Keys werden bewusst nicht
als Teil des Nova-Disaster-Recovery gesichert. Nach einem vollständigen Neuaufbau
werden benötigte WireGuard-Clients neu erzeugt und verteilt.

WireGuard-Client-Secrets dürfen weder ins Repository noch in `secrets.env`
übernommen werden.

### 11.8 Konzeptioneller Neuaufbau

Der spätere Disaster-Recovery-Ablauf ist konzeptionell wie folgt:

1. Frisches unterstütztes Debian auf dem Raspberry Pi installieren.
2. System aktualisieren.
3. Falls vorhanden, den ext4-Stick mit Label `INFRA-RECOVERY` bereitstellen.
4. Den zukünftigen curl-Installer von `nova-infra` starten.
5. Der Installer erkennt das optionale Medium, legt `/opt/nova-bootstrap` an und
   übernimmt bei vorhandenem Stick `/secrets/secrets.env` sicher nach
   `/opt/nova-bootstrap/secrets.env`; andernfalls fährt er mit klaren
   `CHANGE_ME_`-Platzhaltern fort.
6. Der Installer baut die reproduzierbare Infrastruktur auf und verwendet die
   vorhandenen einfachen Secrets.
7. Vaultwarden über die vorhandene Appliance-Restore-Funktion manuell
   wiederherstellen.
8. Syncthing-Konfiguration und Geräteidentität gezielt wiederherstellen.
9. WireGuard-Clients neu erzeugen.
10. Abschließende Funktionskontrolle durchführen.

Die genaue Reihenfolge darf bei der späteren Implementierung technisch angepasst
werden, wenn Abhängigkeiten dies erfordern.

### 11.9 Installer-Verhalten bei Secrets

Fehlt für einen optionalen Dienst ein benötigtes Secret, gibt der spätere
Installer eine klare und verständliche Meldung aus. Fehlende Secrets werden
eindeutig beim Variablennamen benannt, damit beim Restore sofort erkennbar ist,
was noch manuell bereitgestellt werden muss.

Am Ende der Installation listet der Installer alle noch ungelösten Werte mit dem
Präfix `CHANGE_ME_` auf. Dienste mit zwingend fehlenden Secrets bleiben
deaktiviert oder werden eindeutig als manuell zu vervollständigen gemeldet.

Der Installer darf:

- keine Secrets erfinden
- keine geheimen Werte aus dem Internet oder Git beziehen
- keine Secrets in Logs, MOTD oder Fehlermeldungen ausgeben

### 11.10 Zielbild

Ein vollständiger Nova-Neuaufbau besteht aus zwei klar getrennten Bestandteilen:

1. reproduzierbare Infrastruktur aus dem öffentlichen Git-Repository
2. wenige lokale Secrets und dateibasierte Restore-Daten vom geschützten
   Restore-Medium

Damit bleibt `nova-infra` vollständig reproduzierbar und secret-frei, ohne ein
unnötig komplexes Secret-Management-System einzuführen.

## 12. Installer-Architektur

### 12.1 Ziel und Einstiegspunkt

Der spätere Installer baut einen möglichst leeren Raspberry Pi 5 mit Debian 13
reproduzierbar als Nova Infrastructure Node auf. Der Einstieg soll über einen
einzelnen curl-Aufruf möglich sein, sinngemäß:

```shell
curl -fsSL <raw-github-url>/install.sh | sudo bash
```

Die endgültige URL wird bei der Implementierung aus dem tatsächlichen Repository
abgeleitet und nicht vorab erfunden. Der curl-Aufruf ist nur der Einstiegspunkt;
intern darf und soll der Installer modular aufgebaut sein.

### 12.2 Unterstützte Plattform und frühe Prüfung

Der Installer unterstützt zunächst bewusst ausschließlich den vorgesehenen
Nova-Zielzustand:

- Raspberry Pi 5
- ARM64 / aarch64
- Debian 13 / trixie

Plattform, Architektur und Distribution werden vor Änderungen klar geprüft. Bei
nicht unterstützten Systemen bricht der Installer früh mit einer verständlichen
Meldung ab. Er trifft keine stillen Annahmen über andere Distributionen oder
Architekturen.

### 12.3 Ausgangszustand und Referenzsysteme

Als Testreferenz dient Atlas mit folgendem Ausgangszustand:

- frisches Debian 13
- ausgeführtes `apt update`
- vollständiges Upgrade
- vorhandener SSH-Zugriff
- ansonsten möglichst leeres System

Nova bleibt während der Entwicklung ein unangetastetes produktives
Referenzsystem. Sämtliche destruktiven Installations-, Reinstallations- und
Restore-Tests erfolgen ausschließlich auf Atlas.

### 12.4 Modularer Aufbau

Der Installer wird intern in klar getrennte Module beziehungsweise
Installationsschritte gegliedert. Die genaue Dateistruktur wird bei der
Implementierung festgelegt; logisch werden mindestens folgende Bereiche
getrennt:

- Basissystem
- Repositories und Grundpakete
- Docker
- Unbound
- AdGuard Home
- WireGuard / PiVPN
- DynDNS
- Vaultwarden-Appliance-Integration
- Syncthing
- Prusa-Container
- Caddy-Erweiterungen
- MOTD

Ein einzelnes Modul soll nach Möglichkeit separat erneut ausführbar sein, ohne das
gesamte System neu zu installieren. Es wird keine unnötige Framework-Abhängigkeit
eingeführt; Shell-Skripte sind für die spätere Implementierung ausreichend.

### 12.5 Idempotenz und deterministische Änderungen

Der Installer muss möglichst idempotent sein. Insbesondere gilt:

- Mehrfaches Ausführen darf das System nicht beschädigen.
- Bereits korrekte Verzeichnisse werden nicht unnötig neu angelegt.
- Repositories werden nicht mehrfach eingetragen.
- systemd-Units werden nicht mehrfach oder widersprüchlich erzeugt.
- Docker-Repositories und Keyrings werden nicht dupliziert.
- Benutzer und Gruppen werden nur bei Bedarf angelegt oder geändert.
- Bestehende korrekte Konfigurationen werden nicht blind erweitert.
- Konstruktionen wie `echo >>`, die bei Wiederholung mehrfache Einträge erzeugen,
  werden vermieden.
- Dateien werden deterministisch erzeugt oder kontrolliert ersetzt.
- Erforderliche Änderungen werden in der Ausgabe klar benannt.

### 12.6 Schutz produktiver Daten

Der Installer darf produktive Nutzdaten und Secrets niemals blind löschen oder
ersetzen. Besonders geschützt werden:

- `/opt/vaultwarden/data`
- `/opt/vaultwarden/backups`
- persistente Caddy-Daten
- private Syncthing-Schlüssel und die Geräteidentität
- `/opt/nova-bootstrap/secrets.env`

Werden vorhandene produktive Daten erkannt, handelt der Installer konservativ und
bricht bei unklaren oder potenziell destruktiven Änderungen kontrolliert ab.

### 12.7 Umgang mit lokalen Secrets

Einfache lokale Secrets werden bevorzugt aus `/secrets/secrets.env` auf dem
ext4-Medium mit Label `INFRA-RECOVERY` übernommen und anschließend ausschließlich
lesend aus `/opt/nova-bootstrap/secrets.env` geladen. Das Medium ist optional;
sein Fehlen darf die Gesamtinstallation nicht abbrechen. Ergänzend zu Abschnitt
11 gelten für den Installer folgende Anforderungen:

- Er gibt den Dateiinhalt nicht aus.
- Er schreibt keine Secrets in Logs.
- Er kopiert keine Secrets in das Repository.
- Er zeigt keine Secrets im MOTD oder in Fehlermeldungen an.
- Er erfindet keine geheimen Werte und bezieht sie nicht automatisch aus
  unsicheren Quellen.

Fehlt ein Secret für einen optionalen Dienst, nennt der Installer verständlich
den fehlenden Variablennamen, beispielsweise `DYNDNS_URL`, `CAMERA_URL`, `TOKEN`
oder `ADGUARD_PASSWORD_HASH` oder `WG_EASY_PASSWORD`, ohne einen geheimen Wert
auszugeben. Der fehlende Wert wird mit einem eindeutigen `CHANGE_ME_`-Platzhalter
repräsentiert. Der betroffene Dienst bleibt deaktiviert oder wird eindeutig als
manuell zu vervollständigen gemeldet. Am Installationsende werden alle ungelösten
`CHANGE_ME_`-Werte zusammengefasst.

### 12.8 Integration externer Projekte

Die `vaultwarden-appliance` bleibt ein eigenständiges Projekt. Der
Nova-Installer ruft deren bestehenden curl-Installer auf und ergänzt anschließend
nur die Nova-spezifische Integration. `nova-infra` implementiert insbesondere
nicht erneut:

- den Vaultwarden-Compose-Stack
- `vwctl`
- die Vaultwarden Backup Engine
- Restore-Funktionen der Appliance
- die Caddy-Basisinstallation der Appliance
- die USB-Backup-Logik

### 12.9 Verbindliche Konfigurationsquellen

Bewährte produktive Konfigurationen werden bevorzugt als reproduzierbare
Referenz übernommen. Dies gilt insbesondere für:

- die getestete Unbound-Konfiguration
- die bereinigte AdGuard-Konfiguration
- die definierten Caddy-Reverse-Proxy-Einträge
- systemd-Services und Timer
- die DynDNS-Logik

Der Installer führt keine vermeintlichen Optimierungen ohne konkreten Grund ein.
Wenn diese Spezifikation einen bestehenden Wert als getestet oder verbindlich
bezeichnet, hat dieser Vorrang vor generischen Best Practices.

### 12.10 APT-Repositories und Keyrings

Externe offizielle Paketquellen werden reproduzierbar eingerichtet. Dazu gehören
insbesondere:

- das offizielle Docker-APT-Repository
- das offizielle Syncthing-APT-Repository

Repository-Keyrings werden unter einem modernen Pfad wie `/etc/apt/keyrings`
verwaltet. Die veraltete `apt-key`-Methode wird nicht verwendet. Wenn laut
Spezifikation ein offizielles Projekt-Repository erforderlich ist, darf der
Installer nicht stillschweigend auf eine ältere Version aus den
Debian-Standardpaketen zurückfallen.

`apt-cacher-ng` ist kein Bestandteil der Zielinfrastruktur. Tests mit der
verfügbaren Internetanbindung von ungefähr 600 Mbit/s zeigten keinen relevanten
Zeitgewinn beim Neuaufbau. Nova und Arc verwenden APT direkt. Ein Paketcache darf
höchstens später als ausdrücklich optionale Optimierung für langsame Verbindungen
neu bewertet werden.

### 12.11 systemd

Native Dienste und Timer werden über systemd verwaltet. Eigene Units müssen:

- klar benannt sein
- nur bei tatsächlichen Änderungen ein `systemctl daemon-reload` auslösen
- dauerhaft benötigte Dienste aktivieren
- spezifizierte Timer aktivieren
- unnötige eigene Daemons vermeiden, wenn ein Timer oder Oneshot-Service genügt

### 12.12 Docker

Docker wird aus dem offiziellen Repository installiert und als normaler
Systemdienst betrieben. Für eigene Nova-Container gelten folgende Grundsätze:

- einfache Compose-Struktur
- sinnvolle `restart`-Policy
- keine zusätzlichen Docker-Healthchecks allein aus Prinzip
- tatsächlichen Docker-Zustand später über das MOTD sichtbar machen
- keine unnötigen Container einführen

Fremd-Images dürfen ihre vorhandenen eigenen Healthchecks behalten;
`nova-infra` ergänzt nicht pauschal weitere Healthchecks.

### 12.13 Fehlerbehandlung und Logging

Spätere Shell-Skripte sollen robust und verständlich fehlschlagen. Dazu gehören:

- sinnvolle Verwendung von `set -euo pipefail`
- klare Benennung des fehlgeschlagenen Installationsschritts
- keine endlosen Fehlerketten nach einem kritischen Fehler
- keine stillen Fehler, die ein unvollständiges System hinterlassen
- keine Secrets in Fehlermeldungen
- keine automatischen destruktiven Reparaturversuche
- kontrollierter Abbruch, wenn ein Schritt nicht sicher ausgeführt werden kann

Die Konsolenausgabe zeigt den aktuellen Installationsschritt sowie Erfolg,
Warnungen und Fehler verständlich an. Der Normalbetrieb erzeugt keine übermäßig
ausführliche Debug-Ausgabe. Ein später optionales Installationslog ist zulässig,
muss Secrets jedoch redigieren beziehungsweise darf sie gar nicht erst ausgeben.

### 12.14 Konservative Netzwerkänderungen

Netzwerkänderungen werden besonders konservativ behandelt. Der Installer darf
eine funktionierende SSH-Verbindung nicht unnötig gefährden und keine
Interface-Konfiguration blind ersetzen. Maßgeblich sind:

- Hauptinterface `eth0`
- Nova LAN-Adresse `192.168.0.195/24`
- Gateway `192.168.0.1`

Die konkrete Netzwerkimplementierung wird zuerst auf Atlas getestet.

### 12.15 MOTD

Die MOTD-Grundlage darf in der Basissystemphase vorbereitet werden. Ihre
vollständige Dienst- und Containeranzeige wird erst nach Installation der
betreffenden Komponenten finalisiert. Das MOTD dient ausschließlich der Anzeige
und führt keine Reparaturaktionen aus. Ein Fehler im MOTD darf niemals den Login
blockieren.

### 12.16 Abgrenzung manueller Restore-Schritte

Der Installer stellt die reproduzierbare Infrastruktur her. Folgende Schritte
bleiben bewusst manuell beziehungsweise separat:

- Vaultwarden-Restore
- Caddy-CA- und Vaultwarden-Datenrestore über die Appliance-Funktionen
- Restore der Syncthing-Geräteidentität
- Neuerzeugung der WireGuard-Clients

Der Installer dokumentiert diese Schritte klar, automatisiert sie aber nicht
zwanghaft vollständig.

### 12.17 Konzeptionelle Installationsreihenfolge

Die folgende Reihenfolge ist verbindlich auf Phasenebene. Technische Details
innerhalb einer Phase dürfen angepasst werden, wenn Abhängigkeiten dies erfordern.
Jede Phase soll soweit praktisch unabhängig testbar und idempotent sein:

1. Preflight-Prüfungen für Plattform, Systemzustand und sichere Ausführbarkeit.
2. APT-Repositories einrichten, `apt update` und vollständiges Upgrade ausführen
   sowie alle benötigten Pakete installieren.
3. Docker Engine und Docker Compose bereitstellen.
4. Basisdienste wie DynDNS, WireGuard / PiVPN und Unbound konfigurieren sowie die
   MOTD-Grundlage vorbereiten; Unbound unabhängig auf Port 5335 testen.
5. Container einschließlich Vaultwarden-Appliance und Prusa-Komponenten
   bereitstellen sowie die native Syncthing-Integration einrichten.
6. Die Caddy-Kerninstallation abschließen, interne HTTPS-/CA-Funktion validieren
   und klar markierte optionale Nova-Host-Blöcke ergänzen.
7. AdGuard Home zuletzt installieren und konfigurieren, die bereinigten Rewrites
   ergänzen und erst dann den kritischen DNS-Wechsel auf Port 53 ausführen.
8. Aufräumen, Gesamtvalidierung und Reboot-Test durchführen.

AdGuard und andere kritische Infrastrukturumschaltungen werden bewusst spät
ausgeführt. Insbesondere bleibt DNS unverändert, bis sämtliche Paketdownloads und
Docker-Pulls abgeschlossen sind.

### 12.18 Abschlussprüfung

Es wird keine komplexe permanente Monitoring-Plattform gebaut. Nach der
Installation muss jedoch ein einfacher Abschlusscheck mindestens prüfen können:

- Basissystem ist plausibel eingerichtet.
- Docker-Service läuft.
- Unbound-Service läuft und antwortet auf dem erwarteten Port.
- AdGuard-Service läuft und AdGuard antwortet auf Port 53.
- `wg0` existiert.
- DynDNS-Timer ist aktiv.
- Vaultwarden- und Caddy-Container existieren nach der Appliance-Installation.
- Syncthing-Service läuft.
- Prusa-Watchdog-Container existiert beziehungsweise läuft.
- MOTD-Datei ist installiert.
- Alle ungelösten `CHANGE_ME_`-Platzhalter werden am Ende sichtbar gemeldet.
- Ein Reboot-Test bestätigt, dass Dienste, Timer und Container wie vorgesehen
  wieder verfügbar sind.

Es werden keine unnötig komplexen Application-Level-Healthchecks ergänzt. Das
MOTD bleibt die primäre schnelle Betriebsübersicht im Alltag.

### 12.19 Verbindlichkeit der Spezifikation

Bis zum Beginn der eigentlichen Implementierung bleibt `SPECIFICATION.md` die
verbindliche Quelle für Architekturentscheidungen. Dokumentierte Entscheidungen
dürfen bei der späteren Implementierung nicht stillschweigend geändert werden.
Ist eine Anforderung technisch problematisch, wird dies gemeldet und nicht
eigenmächtig umgebaut.

## 13. Test- und Einführungsstrategie

### 13.1 Rollen der Systeme

- **Nova** bleibt zunächst das produktive Referenzsystem und wird während der
  Entwicklung nicht verändert.
- **Atlas** wird aus der produktiven DNS-Infrastruktur entfernt und dient künftig
  ausschließlich als Testserver.
- Atlas erhält als Ausgangspunkt ein möglichst leeres Debian-13-System, im
  Wesentlichen ein frisches Debian 13 nach `apt update` und Upgrade, mit
  vorhandenem SSH-Zugriff und ohne weitere vorausgesetzte Spezialkonfiguration.
- Sämtliche destruktiven Installations- und Wiederherstellungstests werden
  ausschließlich auf Atlas durchgeführt.

### 13.2 Späterer Zielablauf

```text
frische Raspberry-Pi-OS-/Debian-13-Basis
  -> optional INFRA-RECOVERY bereitstellen
  -> curl-Installer
  -> vollständiger Nova-Sollzustand
  -> erforderliche manuelle Restore-Schritte
  -> Abschlussprüfung und Reboot-Test
```

### 13.3 Zu prüfende Ergebnisse

- Basissystem und benötigte Pakete sind reproduzierbar eingerichtet.
- Alle vorgesehenen systemd Services und Timer sind aktiv und korrekt geplant.
- Alle vorgesehenen Container laufen mit der erwarteten Konfiguration.
- AdGuard Home und Unbound liefern funktionierendes DNS.
- WireGuard erhält die bestehende Routing- und DNS-Funktion.
- DynDNS aktualisiert wie vorgesehen.
- Vaultwarden ist nach Restore der separat gesicherten Daten funktionsfähig.
- Syncthing und die Backup-Struktur sind eingerichtet; die Synchronisation zur
  Synology und der Restore-Prozess sind überprüfbar, ohne dass kritische Dienste
  von der Synology-Verfügbarkeit abhängen.
- Der Prusa-Watchdog startet und stoppt den Upload-Container entsprechend der
  Erreichbarkeit von `192.168.0.61`.
- Die MOTD zeigt die geforderten System- und Dienstzustände.
- Im Repository befinden sich keine Secrets.

**TODO:** Detaillierten Healthcheck-Katalog mit Prüfmethoden, Sollwerten,
Fehlerfällen und Abnahmekriterien erstellen.

### 13.4 Installer-Tests auf Atlas

Die erste Implementierung muss vollständig auf Atlas getestet werden. Die
Testziele umfassen mindestens:

- Installation auf sauberem Debian 13
- erneutes Ausführen des vollständigen Installers
- erneutes Ausführen einzelner Module
- unabhängige Prüfung jeder Installationsphase, soweit praktisch
- Installation mit vorhandenem `INFRA-RECOVERY`
- erfolgreiche Fortsetzung ohne `INFRA-RECOVERY`
- klare Meldung aller verbleibenden `CHANGE_ME_`-Platzhalter
- Abschluss aller APT-Downloads und Docker-Pulls vor dem DNS-Wechsel
- Reboot des Systems
- korrekter Start der Dienste nach dem Reboot
- weiterhin aktive Timer
- erwartungsgemäß erneut gestartete Docker-Container
- funktionierendes MOTD
- keine Secrets im Git-Repository
- keine Beschädigung produktiver Daten
- funktionsfähige kritische Infrastruktur bei nicht erreichbarer Synology und
  fehlenden optionalen Caddy-Komfort-Hosts

Erst wenn der Aufbau auf Atlas reproduzierbar funktioniert, darf ein späterer
Einsatz auf Nova in Betracht gezogen werden.

## 14. Offene Erhebung am Referenzsystem Nova

Die in den vorherigen Abschnitten markierten `TODO`-Punkte müssen zunächst durch
rein lesende Bestandsaufnahme am produktiven Nova geklärt werden. Dabei gilt:

- Nova wird nicht verändert.
- Geheimnisse werden weder in Ausgaben noch im Repository erfasst.
- Bewährte Konfigurationen werden vollständig und nachvollziehbar inventarisiert.
- Abhängigkeiten, Versionen, Pfade, Benutzer, Berechtigungen, Ports, Volumes,
  Timer und Restore-Anforderungen werden dokumentiert.
- Erst nach dieser Bestandsaufnahme werden Implementierungsentscheidungen für den
  späteren Installer getroffen.

## 15. Änderungsverlauf

| Datum | Änderung |
| --- | --- |
| 2026-08-15 | Recovery-Medium von Nova entkoppelt und als allgemeines `INFRA-RECOVERY` konzipiert |
| 2026-08-14 | Deployment-Reihenfolge, INFRA-RECOVERY, Caddy-/Prusa-Strategie und nachrangige Synology-Rolle konsolidiert |
| 2026-08-09 | Verbindliche Architektur, Idempotenz- und Testanforderungen für den zukünftigen Installer ergänzt |
| 2026-08-09 | AdGuard-Home-Sollzustand einschließlich Upstreams, Rewrites, Filter und Fallback-Strategie finalisiert |
| 2026-08-09 | Bestandsaufnahme des Nova-Basissystems und verbindliche Bootstrap-Anforderungen ergänzt |
| 2026-08-09 | Secret- und Disaster-Recovery-Konzept einschließlich lokaler Installer-Secrets und dateibasierter Restore-Daten ergänzt |
| 2026-08-09 | Produktive Caddy-Zuordnungen und Architektur der gemeinsamen lokalen HTTPS-Instanz dokumentiert |
| 2026-08-09 | Verbindliche Integrations- und Projektabgrenzungsstrategie für die Vaultwarden-Appliance ergänzt |
| 2026-08-09 | Verbindlichen Sollzustand für Prusa-Kamera-Upload und Watchdog dokumentiert |
| 2026-08-09 | Anforderungen an das zukünftige dynamische Nova-MOTD ergänzt |
| 2026-08-09 | Syncthing-Bestandsaufnahme und Sollzustand für die nachgelagerte Vaultwarden-Backup-Replikation ergänzt |
| 2026-08-09 | DynDNS-Bestandsaufnahme einschließlich Secret-, WireGuard- und Healthcheck-Anforderungen ergänzt |
| 2026-08-09 | Bestandsaufnahme von WireGuard und PiVPN einschließlich MTU-, Client- und Firewall-Strategie ergänzt |
| 2026-08-09 | Bestandsaufnahme von Unbound, AdGuard Home und DNS-Architektur ergänzt; Rolle von Atlas präzisiert |
| 2026-08-09 | Initiale Erfassung des bisher bekannten Sollzustands |
