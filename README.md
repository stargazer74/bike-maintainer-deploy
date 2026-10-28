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

Die `compose.yaml` im Backend-Repo bleibt dort: Sie ist für die Entwicklung gedacht, baut das Backend aus dem
Quellcode und wird von `./mvnw spring-boot:run` automatisch gestartet.

## Varianten

Die Varianten unterscheiden sich nach Betriebsart und danach, wer TLS übernimmt – nicht nach Architektur. Jede liegt
in einem eigenen Verzeichnis mit `compose.yaml` und `.env.example`.

| Verzeichnis | Betriebsart | TLS / Proxy |
|---|---|---|
| [`portal/`](portal/) | Portal mit Login (Internet) | vorhandener nginx-proxy-manager auf dem Host |

## Portal hinter vorhandenem nginx-proxy-manager

`portal/` bringt keinen eigenen Proxy mit und veröffentlicht keine Ports für die App. Frontend und Backend hängen
zusätzlich im Docker-Netz des vorhandenen nginx-proxy-manager (`PROXY_NETWORK` in der `.env`) und sind dort über
ihren Service-Namen erreichbar. Im nginx-proxy-manager ein Proxy-Host für die Domain:

- Ziel: `http://bm-frontend:80`, SSL mit Let's Encrypt
- Custom Location `/api`: `http://bm-backend:8080` – entfällt, sobald der Frontend-Container `/api`
  selbst ans Backend weiterleitet (bike-maintainer-frontend#4)

## Starten

```bash
cd portal
cp .env.example .env    # Werte eintragen
docker compose up -d
```

Es reicht, das jeweilige Verzeichnis herunterzuladen; ein Klonen des ganzen Repos ist nicht nötig.
