# Bike Maintainer – Deployment

Betriebsdateien für den **Bike Maintainer**: Compose-Dateien und Beispielkonfigurationen, mit denen sich die App aus
fertigen Images starten lässt – ohne Quellcode, Maven oder npm.

Der Code liegt in den anderen Repos:

| Repo | Inhalt |
|---|---|
| [bike-maintainer-api](https://github.com/stargazer74/bike-maintainer-api) | OpenAPI-Spezifikation |
| [bike-maintainer-backend](https://github.com/stargazer74/bike-maintainer-backend) | Spring-Boot-Backend, Image `ghcr.io/stargazer74/bike-maintainer-backend` |
| [bike-maintainer-frontend](https://github.com/stargazer74/bike-maintainer-frontend) | Angular-Frontend (nginx), Image `ghcr.io/stargazer74/bike-maintainer-frontend` |

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

Backend und Frontend laufen in allen Varianten unter festen Container-Namen (`bike-maintainer-backend`,
`bike-maintainer-frontend`), z. B. für `docker logs bike-maintainer-backend`. Deshalb lässt sich pro Rechner nur eine
Installation betreiben.

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

`portal/` bringt keinen eigenen Proxy mit und veröffentlicht keine Ports für die App. Nur das Frontend hängt
zusätzlich im Docker-Netz des vorhandenen nginx-proxy-manager (`PROXY_NETWORK` in der `.env`) und ist dort als
`bike-maintainer-frontend` erreichbar; `/api/` leitet der Frontend-Container selbst ans Backend weiter. Im
nginx-proxy-manager genügt ein Proxy-Host für die Domain:

- Ziel: `http://bike-maintainer-frontend:80`
- SSL: Let's Encrypt, „Force SSL“ an

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

Starten:

```bash
cd portal
cp .env.example .env    # Werte eintragen
docker compose up -d
```

Für jede Variante reicht es, `compose.yaml` und `.env.example` aus dem jeweiligen Verzeichnis herunterzuladen; ein
Klonen des ganzen Repos ist nicht nötig.
