# Bike Maintainer – Deployment

Betriebsdateien für den **Bike Maintainer**: Compose-Dateien und Beispielkonfigurationen, mit denen sich die App aus
fertigen Images starten lässt – ohne Quellcode, Maven oder npm.

Der Code liegt in den anderen Repos:

| Repo | Inhalt |
|---|---|
| [bike-maintainer-api](https://github.com/stargazer74/bike-maintainer-api) | OpenAPI-Spezifikation |
| [bike-maintainer-backend](https://github.com/stargazer74/bike-maintainer-backend) | Spring-Boot-Backend, Image `ghcr.io/stargazer74/bike-maintainer-backend` |
| [bike-maintainer-frontend](https://github.com/stargazer74/bike-maintainer-frontend) | Angular-Frontend (nginx), Image `ghcr.io/stargazer74/bike-maintainer-frontend` |
| [bike-maintainer-portal](https://github.com/stargazer74/bike-maintainer-portal) | Website des Portals (WordPress), Image `ghcr.io/stargazer74/bike-maintainer-portal` |

Die Images gibt es für `linux/amd64` und `linux/arm64` unter demselben Namen; Docker zieht automatisch die passende
Variante. Jede Compose-Datei läuft also unverändert auf PC, Server und Raspberry Pi.

## Versionen

Backend und Frontend werden gemeinsam mit derselben Versionsnummer (SemVer) veröffentlicht:

| Image-Tag | Inhalt |
|---|---|
| `1.2.3` | genau diese Release |
| `1.2`, `1` | neueste Release mit dieser Minor- bzw. Major-Version |
| `latest` | neueste Release |

Images entstehen nur bei Releases, nicht bei jedem Merge.

Die Compose-Dateien ziehen `${BM_VERSION:-0}`: ohne Angabe die neueste `0.x`-Release. Solange die Version mit `0`
beginnt, ist das Projekt in der Anfangsphase, und jede Minor-Version (`0.1` → `0.2`) kann Breaking Changes
enthalten. Mit `BM_VERSION=0.1.0` in der `.env` bleibt die Installation auf genau dieser Release. Ab `1.0.0` wird
der Standard auf `1` umgestellt (neueste `1.x`, Updates ohne Breaking Changes).

Die `compose.yaml` im Backend-Repo bleibt dort: Sie ist für die Entwicklung gedacht, baut das Backend aus dem
Quellcode und wird von `./mvnw spring-boot:run` automatisch gestartet.

## Varianten

Alle Container laufen in allen Varianten unter festen Namen statt `<projekt>-<dienst>-1`: `bike-maintainer-backend`,
`bike-maintainer-frontend`, `bike-maintainer-mariadb` und im Portal `bike-maintainer-phpmyadmin`, z. B. für
`docker logs bike-maintainer-backend`. Deshalb lässt sich pro Rechner nur eine Installation betreiben.

Die Varianten unterscheiden sich nach Betriebsart und danach, wer TLS übernimmt – nicht nach Architektur. Jede liegt
in einem eigenen Verzeichnis mit `compose.yaml` und `.env.example`.

| Verzeichnis | Betriebsart | TLS / Proxy |
|---|---|---|
| [`portal/`](portal/) | Portal mit Login (Internet) | vorhandener nginx-proxy-manager auf dem Host |
| [`household/`](household/) | Haushalt ohne Login (nur Heimnetz) | keiner |

## Selbst hosten im Heimnetz

Der Haushaltsmodus ist für den privaten Betrieb zu Hause gedacht, z. B. auf einem Raspberry Pi. Es gibt keine
Anmeldung: Beim Öffnen wählt jede Person im Haushalt ihr Profil und sieht ihre eigenen Fahrzeuge.

> [!WARNING]
> Die Profile haben **kein Passwort** – jeder, der die App erreicht, sieht alle Daten. Betreibe den Haushaltsmodus
> nur im Heimnetz und richte **keine Portfreigabe im Router** ein. Für den Betrieb im Internet ist der Portalmodus
> (`portal/`) da.

Voraussetzung: ein Rechner mit Docker und Docker Compose (amd64 oder arm64, z. B. Raspberry Pi 4/5 mit 64-Bit-OS).

1. Dateien herunterladen:
   ```bash
   mkdir bike-maintainer && cd bike-maintainer
   curl -fsSLO https://raw.githubusercontent.com/stargazer74/bike-maintainer-deploy/main/household/compose.yaml
   curl -fsSL -o .env https://raw.githubusercontent.com/stargazer74/bike-maintainer-deploy/main/household/.env.example
   ```
2. In `.env` ein Datenbank-Passwort setzen (`BM_DB_PASSWORD`, beliebiger langer Zufallswert, z. B. aus
   `openssl rand -base64 24`). Optional mit `BM_PORT` den Port ändern.
3. Starten:
   ```bash
   docker compose up -d
   ```
4. Im Browser `http://<rechner>:8080` öffnen. Die Person „Admin“ gibt es schon; sie lässt sich umbenennen, weitere
   Personen kommen über „Person hinzufügen“ dazu.

Aktualisieren: `docker compose pull && docker compose up -d` (holt die neueste Release innerhalb von `BM_VERSION`, siehe
„Versionen“). Die Daten liegen im Docker-Volume `mariadb-data` und
bleiben dabei erhalten.

## Portal hinter vorhandenem nginx-proxy-manager

`portal/` bringt keinen eigenen Proxy mit und veröffentlicht keine Ports. Nur das Frontend der App und die Website
hängen zusätzlich im Docker-Netz des vorhandenen nginx-proxy-manager (`PROXY_NETWORK` in der `.env`) und sind dort
als `bike-maintainer-frontend` bzw. `bike-maintainer-website` erreichbar; `/api/` leitet der Frontend-Container
selbst ans Backend weiter. Im nginx-proxy-manager je ein Proxy-Host, jeweils mit SSL (Let's Encrypt) und „Force SSL“:

| Domain | Ziel |
|---|---|
| `app.bike-maintainer.de` | `http://bike-maintainer-frontend:80` |
| `bike-maintainer.de`, `www.bike-maintainer.de` | `http://bike-maintainer-website:80` |

DNS: `app.` und `www.` (zusätzlich zur Hauptdomain) auf den Server zeigen lassen.

**Website (WordPress mit Forum):** Image `ghcr.io/stargazer74/bike-maintainer-portal` (eigene Versionen,
`BM_WEBSITE_VERSION`, Standard `0`), ganz `/var/www/html` liegt im Volume `website-data` – WordPress aktualisiert
Kern, Plugins und Themes dort selbst, das Image bringt nur Theme und Must-use-Plugins mit. Die Website nutzt die
vorhandene MariaDB mit **eigener** Datenbank `wordpress` und eigenem Nutzer, der keine Rechte auf die App-Daten hat
(`BM_WEBSITE_DB_PASSWORD`); WordPress bekommt nie das Root-Passwort. Mails gehen über dasselbe Postfach wie die App;
Registrierung und „Passwort vergessen“ des Forums schützt ein **eigener** ALTCHA-Schlüssel
(`BM_WEBSITE_ALTCHA_HMAC_KEY`, nicht derselbe wie der der App).

Einmalig nach dem ersten Start einrichten (installiert WordPress, Sprachen, Forum und Plugins; Werte aus
`BM_WEBSITE_URL`, `BM_WEBSITE_ADMIN_*` der `.env`):

```bash
docker compose exec -u www-data bike-maintainer-website bm-setup
```

Nicht vorher die Website im Browser öffnen – sonst läuft stattdessen der WordPress-Installationsassistent, ohne
Theme, Sprachen und Forum.

**Bestehende Installation** (Datenbank lief schon vor der Website): Das Init-Skript `mariadb-init/10-website.sh`
läuft nur bei leerem Datenverzeichnis. Datenbank und Nutzer deshalb einmalig von Hand anlegen. Dafür braucht es das
Root-Passwort, das MariaDB beim allerersten Start zufällig erzeugt und ins Log geschrieben hat:

```bash
cd portal
PW=$(docker logs bike-maintainer-mariadb 2>&1 | sed -n 's/.*GENERATED ROOT PASSWORD: //p' | head -1)
docker compose exec -T -e MYSQL_PWD="$PW" bike-maintainer-mariadb sh -c 'mariadb -uroot <<EOF
CREATE DATABASE IF NOT EXISTS \`wordpress\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS "wordpress"@"%" IDENTIFIED BY "$BM_WEBSITE_DB_PASSWORD";
GRANT ALL PRIVILEGES ON \`wordpress\`.* TO "wordpress"@"%";
EOF'
```

Ist `PW` leer, wurde der Container seit dem ersten Start neu erstellt und das Log ist weg; dann muss das
Root-Passwort einmalig zurückgesetzt werden (MariaDB-Doku „Recover the root password“).

**Backup der Website:** die Datenbank `wordpress` (z. B. `mariadb-dump` im MariaDB-Container) und das Volume
`website-data` (Uploads, Plugins).

**Registrierung (ab Backend 0.3):** Neue Nutzer registrieren sich selbst und bestätigen ihre E-Mail-Adresse per
Link. Dafür braucht die `.env` das SMTP-Passwort von `noreply@bike-maintainer.de` (`SPRING_MAIL_PASSWORD`) und
einen geheimen Schlüssel für das Captcha (`BM_ALTCHA_HMAC_KEY`, z. B. `openssl rand -hex 32`); ohne beide startet
weder Compose noch das Backend. `BM_PUBLIC_URL` ist die Adresse der App in den Links der Mails (Standard
`https://app.bike-maintainer.de`). Höchstens 100 Mails pro Tag; unbestätigte Konten werden nach 7 Tagen gelöscht.

Nach außen erreichbar ist nur das Frontend, und auch das nur über das Netz des nginx-proxy-manager. Die Datenbank
veröffentlicht keinen Port, ihr Passwort (`BM_DB_PASSWORD`) steht in der `.env`. phpMyAdmin startet nur auf
Wunsch und lauscht nur auf `127.0.0.1` (Docker würde einen veröffentlichten Port sonst an einer Host-Firewall wie
`ufw` vorbei freigeben):

```bash
docker compose --profile tools up -d          # phpMyAdmin zusätzlich starten
ssh -L 8081:127.0.0.1:8081 <server>           # vom eigenen Rechner aus, dann http://localhost:8081
docker compose --profile tools stop bike-maintainer-phpmyadmin
```

Anmeldung in phpMyAdmin als `maintenance` mit `BM_DB_PASSWORD`; es gibt kein Auto-Login.

**Überwachung:** Das Backend hängt zusätzlich im Docker-Netz `bike-maintainer-monitoring`, über das nur der
Überwachungs-Stack (`monitoring/`, siehe dort) seine Metriken auf Port 8081 abholt; nach außen ist der Port nicht
erreichbar. Das Netz wird **einmalig** vor dem ersten Start angelegt (unabhängig davon, ob die Überwachung läuft).
Backend und Frontend haben Healthchecks (`docker compose ps` zeigt `healthy`); das Frontend startet erst, wenn das
Backend gesund ist. Das Backend schreibt seine Logs als JSON (eine Zeile pro Eintrag, `docker logs` bleibt lesbar
genug, mit `jq` komfortabler).

Starten:

```bash
docker network create bike-maintainer-monitoring   # einmalig
cd portal
cp .env.example .env    # Werte eintragen
docker compose up -d
```

Für jede Variante reicht es, `compose.yaml` und `.env.example` aus dem jeweiligen Verzeichnis herunterzuladen; ein
Klonen des ganzen Repos ist nicht nötig.

## Überwachung des Portals (`monitoring/`)

Eigener Stack neben `portal/` (Grafana Alloy, Prometheus, Loki, Grafana): Alarme per Mail an
`alert@bike-maintainer.de`, Dashboards und zentrale Logs mit gekürzten IP-Adressen. Einrichtung und Details in
[`monitoring/README.md`](monitoring/README.md).

## Lokale Entwicklung: kompletter Stack (`dev/`)

Für die Entwicklung gibt es in `dev/` den **ganzen** Stack im Portal-Modus auf einem Rechner: Backend, Frontend,
Website (WordPress), eine MariaDB mit beiden Datenbanken, Mailpit für alle Mails und phpMyAdmin. Anders als `portal/`
und `household/` **baut** `dev/` die Images aus den Nachbar-Repos – so läuft der aktuelle Code-Stand zusammen, auch
Unveröffentlichtes. Nur für die Entwicklung, nie für den Betrieb (feste Entwicklungs-Secrets, Debug-Ausgaben).

Voraussetzung: alle Repos nebeneinander ausgecheckt, dazu Java 25, Maven, Node 24 und Docker.

```
bike-maintainer-api/  bike-maintainer-backend/  bike-maintainer-frontend/  bike-maintainer-portal/  bike-maintainer-deploy/
```

```bash
cd dev
cp .env.example .env
./build.sh                    # API-Spec installieren, Backend-JAR, Frontend-API-Client, dann alle Images
docker compose up -d
docker compose exec -u www-data bike-maintainer-website bm-setup    # einmalig: WordPress einrichten
```

| Was | Adresse | Zugang |
|---|---|---|
| App | <http://localhost:8100> | Initial-Admin aus `.env` (`BM_INITIAL_ADMIN_*`) oder registrieren |
| Website | <http://localhost:8200> | Admin unter `/wp-admin` aus `.env` (`BM_WEBSITE_ADMIN_*`); Forum unter `/forum/`, Registrierung mit ALTCHA |
| Mailpit | <http://localhost:8026> | alle Mails von App und Website |
| phpMyAdmin | <http://localhost:8101> | `maintenance` / `BM_DB_PASSWORD` bzw. `wordpress` / `BM_WEBSITE_DB_PASSWORD` |

- Der Stack zeigt den Stand vom **letzten Build**, nicht den ausgecheckten: Nach Änderungen in einem Repo
  `./build.sh && docker compose up -d` (nur die Website: `docker compose build bike-maintainer-website`). Ein Neustart
  des Containers allein baut nichts neu. Die Website läuft im WordPress-Entwicklungsmodus `theme`, damit neue Patterns
  und `theme.json` nach dem Neubau sofort gelten.
- Die Startseite verweist auf das Landing-Page-Pattern. Wird sie einmal im Editor gespeichert, steht der Inhalt fest
  in der Seite, und Änderungen an den Pattern-Dateien kommen dort nicht mehr an.
- Die Website-Datenbank `wordpress` legt `dev/mariadb-init/10-website.sh` beim allerersten Start an, mit eigenem
  Nutzer ohne Rechte auf die App-Daten (so wie für den Portal-Betrieb geplant). Die Datei darf nicht ausführbar sein:
  Der MariaDB-Entrypoint bindet nur nicht ausführbare Skripte ein und stellt nur dann `docker_process_sql` bereit.
- Das Backend verlangt beim Mailversand STARTTLS und Anmeldung wie gegen IONOS; Mailpit bietet dazu STARTTLS mit
  selbst signiertem Zertifikat und nimmt jede Anmeldung an.
- Container heißen `bike-maintainer-dev-*` und nutzen eigene Ports, damit sie nicht mit einer `portal/`-Installation
  oder den Dev-Setups in den einzelnen Repos (Backend `8090`, Website `8095`) kollidieren.
- Für die Arbeit am Website-Theme mit sofort sichtbaren Änderungen eignet sich `compose.yaml` im Portal-Repo besser.
- Alles zurücksetzen: `docker compose down -v`.
