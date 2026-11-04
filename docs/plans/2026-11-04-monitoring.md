# Portal Monitoring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Metrics and structured logs from the backend, plus a self-contained monitoring stack (Alloy, Prometheus,
Loki, Grafana) that alerts `alert@bike-maintainer.de` about portal problems.

**Architecture:** The backend exposes Micrometer metrics (`bm.*` plus Spring defaults) on management port 8081 and
logs ECS JSON in portal mode. In the deploy repo, `monitoring/` runs Alloy as the single collector (Docker logs with
IP truncation, host/container metrics, backend scrape, blackbox probes), Prometheus and Loki as stores and Grafana
with file-provisioned datasources, alert rules and dashboards. Both stacks share the external network
`bike-maintainer-monitoring`.

**Tech Stack:** Java 25 / Spring Boot 4 / Micrometer, JUnit 5 + AssertJ + Mockito, Cucumber; Docker Compose,
Grafana Alloy, Prometheus, Loki, Grafana.

**Spec:** `bike-maintainer-deploy/docs/specs/2026-11-04-monitoring-design.md`

## Global Constraints

- Repos and branches: `bike-maintainer-backend` and `bike-maintainer-deploy`, both on branch `feature/monitoring`;
  commit messages reference backend#71 resp. deploy#9; no Claude attribution.
- Backend rules (`.junie/guidelines.md`): no `var`; counting in Components (ArchUnit); no `@SpringBootTest` outside
  Cucumber; `./mvnw verify` green incl. 90 % line/branch coverage.
- Metric names prefixed `bm.`; tags only from fixed small value sets – never user IDs, emails, names, free paths.
- `/actuator/prometheus` only on management port 8081, never on 8080.
- Deploy repo is pull-only: official images with pinned Major.Minor tags, configuration via bind mounts, no `build:`.
- No host ports published by the monitoring stack (dev override excepted, bound to `127.0.0.1`).
- Memory limits: Alloy 384m, Prometheus 512m, Loki 512m, Grafana 256m.
- Metrics: scrape interval 15s, retention 30d. Logs: retention 14d (336h).
- IP truncation in logs: IPv4 last octet → `0`; IPv6 global unicast cut after the third group → `::`.
- Alert recipient `BM_ALERT_EMAIL`, default `alert@bike-maintainer.de`; sender `noreply@bike-maintainer.de` via
  `smtp.ionos.de:587` STARTTLS.
- Grafana: no sign-up, no anonymous access, analytics/update checks/gravatar off.
- READMEs and tickets in German; code, comments and commit messages in English.

## Review Focus

1. Requests that match no handler (404, static files, `/actuator/*` on 8080) must log without `http.route` and must
   never put the raw URL or query string into the MDC → test in Task 7.
2. IP truncation must not mangle times (`10:23:45`, `2026-11-04T10:23:45.123Z`) or plain numbers → regex cases in
   Task 9, checked against Loki in the dev stack.
3. `/actuator/prometheus` must not be reachable through the frontend's nginx (`/api` only) →
   `curl http://localhost:8100/actuator/prometheus` in the dev stack returns no metrics (Task 9).
4. Backend stopped: the "Backend-Metriken fehlen" alert must fire (not stay in NoData) → dev test in Task 10.
5. `bm.mail.quota.used` gauge is read on every scrape: a database error there must not fail the scrape or log an
   ERROR every 15 s → Task 5 test with a throwing repository.

---

## Part A – Backend (`bike-maintainer-backend`, branch `feature/monitoring`)

### Task 1: Prometheus endpoint, common tags, request histogram

**Files:**
- Modify: `pom.xml` (dependency `io.micrometer:micrometer-registry-prometheus`, version from Spring Boot BOM)
- Modify: `src/main/resources/application.properties`
- Create: `src/test/resources/features/metrics.feature`
- Modify: `src/test/java/.../cucumber/support/ApiClient.java` (+ management port), `.../cucumber/steps/HttpSteps.java`
- Create: `docs/metrics.md`

**Interfaces:**
- Produces: property values `management.endpoints.web.exposure.include=health,prometheus`,
  `management.metrics.tags.application=bike-maintainer`, `management.metrics.tags.mode=${bm.mode}`,
  `management.metrics.distribution.percentiles-histogram.http.server.requests=true`;
  Cucumber step `a GET request is sent to the management path {string}`.

- [ ] **Step 1: Write the failing scenarios** in `metrics.feature`:
  - `The Prometheus endpoint is served on the management port`: GET management path `/actuator/prometheus` → status
    200, body contains `application="bike-maintainer"` and `mode="portal"` and `http_server_requests_seconds_bucket`.
  - `The Prometheus endpoint is not served on the application port`: GET `/actuator/prometheus` → status is not 200
    (expect 404 or 401 as the security chain answers; assert "not 200").
  The step uses `@LocalManagementPort` (RANDOM_PORT also randomises the management port).
- [ ] **Step 2: Run** `./mvnw test -Dtest=CucumberTest -Dcucumber.filter.name="Prometheus"` → first scenario FAILS (404).
- [ ] **Step 3: Add dependency and properties.** If the endpoint is still missing under Spring Boot 4, add
  `org.springframework.boot:spring-boot-micrometer-metrics` as well (Boot 4 module split) – check with
  `./mvnw dependency:tree | grep -i micrometer`.
- [ ] **Step 4: Run** the same command → both PASS; the household suite (`-Dtest=HouseholdCucumberTest`) stays green.
- [ ] **Step 5: Create `docs/metrics.md`** (German): endpoint, common tags, standard metrics; empty table
  "Fachliche Metriken" (Name, Art, Tags, Bedeutung) that later tasks fill in.
- [ ] **Step 6: Commit** `Prometheus endpoint on the management port with common tags (#71)`.

### Task 2: Login and lockout metrics

**Files:**
- Modify: `src/main/java/.../component/LoginAuthenticationProviderImpl.java`
- Modify: `src/test/java/.../component/LoginAuthenticationProviderImplTest.java`
- Modify: `docs/metrics.md`

**Interfaces:**
- Consumes: `io.micrometer.core.instrument.MeterRegistry` (new constructor parameter).
- Produces: counters `bm.auth.login{result}` with `result ∈ {success, bad_credentials, locked, disabled, unverified}`,
  `bm.auth.lockout` (no tags).

- [ ] **Step 1: Write failing tests** (use `SimpleMeterRegistry`, existing builders):
  `countsSuccessfulLogin` (`result=success` = 1), `countsUnknownEmailAsBadCredentials`,
  `countsWrongPasswordAsBadCredentials`, `countsLoginWhileLockedAsLocked`, `countsDisabledAccount`,
  `countsUnverifiedAccount`, `countsLockoutWhenMaxAttemptsReached` (`bm.auth.lockout` = 1 exactly on the attempt that
  sets `lockedUntil`, 0 on the attempts before).
- [ ] **Step 2: Run** `./mvnw test -Dtest=LoginAuthenticationProviderImplTest` → new tests FAIL.
- [ ] **Step 3: Implement** – increment right before each `throw`/`return`; lockout inside `registerFailedAttempt`
  when the threshold is reached.
- [ ] **Step 4: Run** → PASS. **Step 5:** add rows to `docs/metrics.md`. **Step 6: Commit**
  `Login and lockout metrics (#71)`.

### Task 3: Registration, password reset and ALTCHA metrics

**Files:**
- Modify: `component/RegistrationComponentImpl.java`, `component/PasswordComponentImpl.java`,
  `component/AltchaComponentImpl.java` and their tests; `docs/metrics.md`

**Interfaces:**
- Produces: `bm.auth.registration{step=started|verified}`, `bm.auth.password_reset{step=requested|completed}`,
  `bm.protection.altcha_failed` (no tags).

- [ ] **Step 1: Write failing tests:**
  - `RegistrationComponentImplTest`: `countsStartedRegistration` (new account created in `register`),
    `doesNotCountRegistrationForExistingEmail` (existing-account branch → `started` stays 0),
    `countsVerifiedEmail` (successful `verifyEmail`), `doesNotCountInvalidToken`.
  - `PasswordComponentImplTest`: `countsResetRequestForExistingAccount`, `doesNotCountResetRequestForUnknownEmail`,
    `countsCompletedReset`.
  - `AltchaComponentImplTest`: `countsFailedVerification` for missing, invalid and reused payload (3 cases);
    `doesNotCountValidSolution`.
- [ ] **Step 2: Run** the three test classes → FAIL.
- [ ] **Step 3: Implement** with constructor-injected `MeterRegistry`.
- [ ] **Step 4: Run** → PASS. **Step 5:** docs rows. **Step 6: Commit** `Registration, password reset and ALTCHA metrics (#71)`.

### Task 4: Rate-limit metric per endpoint group

**Files:**
- Modify: `component/IRateLimitComponent.java`, `component/RateLimitComponentImpl.java`,
  `configuration/RateLimitFilter.java`, tests of both; `docs/metrics.md`

**Interfaces:**
- Changes: `Optional<Duration> tryConsume(String group, String key)` (was `tryConsume(String key)`); `group` is one
  of the fixed values below and becomes the tag; the bucket key stays `path|remoteAddr`.
- Produces: `bm.protection.rate_limited{group}` with group mapping in `RateLimitFilter`:
  `POST /api/v1/auth/login → login`, `POST /api/v1/auth/register → registration`,
  `POST /api/v1/auth/verify-email/resend → verification_resend`,
  `POST /api/v1/auth/password-reset/request → password_reset`, `PUT /api/v1/auth/password → password_change`
  (replace `LIMITED_REQUESTS` by a `Map<String, String>`).

- [ ] **Step 1: Write failing tests:** `RateLimitComponentImplTest.countsRejectedAttemptWithGroup` (consume beyond the
  limit → `group=login` = 1), `doesNotCountAllowedAttempts`; filter test `passesGroupOfRequest` for each of the 5
  requests (mocked component receives the expected group).
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** → PASS, plus the full Cucumber suite (rate-limit
  scenarios unchanged). **Step 5:** docs. **Step 6: Commit** `Rate-limit metric per endpoint group (#71)`.

### Task 5: Mail metrics and quota gauges

**Files:**
- Modify: `component/AccountMailComponentImpl.java`, `component/IMailQuotaComponent.java`,
  `component/MailQuotaComponentImpl.java`, `service/SmtpMailService.java`, their tests; `docs/metrics.md`

**Interfaces:**
- Produces: `bm.mail.sent{type, result}` with `type ∈ {verification, password_reset, registration_exists}`
  (derived from the message key: `mail.verification`, `mail.passwordReset`, `mail.registrationExists`) and
  `result ∈ {queued, quota_exceeded}`; `bm.mail.delivery{result=success|failure}` in `SmtpMailService`;
  gauges `bm.mail.quota.used` and `bm.mail.quota.limit`.
- New: `int IMailQuotaComponent.sentToday()` – today's count, `0` if no row; registered as gauge source in
  `MailQuotaComponentImpl` (constructor), limit gauge from `AccountMailProperties.dailyLimit()`.

- [ ] **Step 1: Write failing tests:** `AccountMailComponentImplTest.countsQueuedVerificationMail`,
  `countsQuotaExceeded` (tryReserve false → `result=quota_exceeded`, no send); `SmtpMailServiceTest` (new, plain
  JUnit with mocked `JavaMailSender`): `countsSuccessfulDelivery`, `countsFailedDelivery` (sender throws
  `MailSendException`); `MailQuotaComponentImplTest.gaugesReportUsedAndLimit` (repository returns 7, limit 100 →
  gauges 7.0 and 100.0), `usedGaugeIsZeroWithoutRow`, `usedGaugeIsNaNAndLogsOnceWhenRepositoryFails` (repository
  throws `DataAccessResourceFailureException` → gauge `NaN`, no exception escapes).
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement** (`LoggingMailService` stays without metrics – local only).
- [ ] **Step 4: Run** → PASS. **Step 5:** docs. **Step 6: Commit** `Mail metrics and daily quota gauges (#71)`.

### Task 6: Report and checklist timers

**Files:**
- Modify: `component/MaintenanceLogComponentImpl.java`, `component/MaintenanceTaskComponentImpl.java`, their tests;
  `docs/metrics.md`

**Interfaces:**
- Produces: timer `bm.report.generated{type=report|checklist, result=success|failure}` around the PDF helper call
  only (not the DB reads).

- [ ] **Step 1: Write failing tests:** `recordsReportGeneration` (count 1, `result=success`),
  `recordsFailedReportGeneration` (helper throws → `result=failure`, exception rethrown), same pair for the checklist;
  no timer when the vehicle is not owned (empty Optional).
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement** with `Timer.Sample`. **Step 4: Run** → PASS.
  **Step 5:** docs. **Step 6: Commit** `Timers for report and checklist generation (#71)`.

### Task 7: Structured logging and route in the MDC

**Files:**
- Create: `src/main/java/.../configuration/RequestLoggingInterceptor.java`,
  `src/main/java/.../configuration/RequestLoggingConfiguration.java` (`WebMvcConfigurer` registering it)
- Create: `src/test/java/.../configuration/RequestLoggingInterceptorTest.java`
- Modify: `README.md` (backend: how to enable JSON logs), `docs/metrics.md` (section "Logs")

**Interfaces:**
- Produces: MDC keys `http.method` and `http.route` (value of
  `HandlerMapping.BEST_MATCHING_PATTERN_ATTRIBUTE`, e.g. `/api/v1/vehicles/{vehicleId}`), set in `preHandle`,
  removed in `afterCompletion`. JSON logging is switched on only by environment:
  `LOGGING_STRUCTURED_FORMAT_CONSOLE=ecs` (Spring Boot structured logging) – no property in
  `application.properties`.

- [ ] **Step 1: Write failing tests** (plain JUnit, `MockHttpServletRequest`):
  `putsMethodAndRouteIntoMdc`, `removesKeysAfterCompletion` (also when `afterCompletion` gets an exception),
  `leavesRouteOutWithoutPattern` (no attribute → no `http.route` key, never the request URI),
  `neverUsesQueryString` (URI `/api/v1/vehicles/7?x=secret` → MDC values contain neither `7` nor `secret`).
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** → PASS.
- [ ] **Step 5: Review log statements:** `grep -rn "log\.\(info\|warn\|error\|debug\)" src/main/java` – none may
  print an email, token, password or request body; fix findings (mask like `SmtpMailService.domainOf`).
- [ ] **Step 6: Manual check:** `LOGGING_STRUCTURED_FORMAT_CONSOLE=ecs ./mvnw spring-boot:run` → console lines are
  JSON with `log.level` and, during an API request, `http.route`.
- [ ] **Step 7: Run** `./mvnw verify` → BUILD SUCCESS (coverage gate). **Step 8: Commit**
  `Structured logging with route in the MDC (#71)`.

---

## Part B – Deploy (`bike-maintainer-deploy`, branch `feature/monitoring`)

### Task 8: Portal stack: healthchecks, monitoring network, JSON logs

**Files:**
- Modify: `portal/compose.yaml`, `portal/.env.example` (nothing new expected), `README.md` (Portal section)

**Interfaces:**
- Produces: external network `bike-maintainer-monitoring` (backend joined); backend env
  `LOGGING_STRUCTURED_FORMAT_CONSOLE=ecs`; healthchecks:
  backend `wget -qO- http://localhost:8081/actuator/health` (or `curl -fs` – use what the backend image contains;
  check with `docker run --rm --entrypoint sh ghcr.io/stargazer74/bike-maintainer-backend:0 -c 'command -v wget curl'`),
  frontend `wget -qO- http://localhost/` ; interval 15s, timeout 5s, retries 5, start_period 60s (backend) / 10s;
  frontend `depends_on: bike-maintainer-backend: condition: service_healthy`.

- [ ] **Step 1: Edit compose.** **Step 2: Validate:** `docker network create bike-maintainer-monitoring` (once),
  `cd portal && cp .env.example /tmp/x.env && <fill dummy values> && docker compose --env-file /tmp/x.env config -q`
  → no error.
- [ ] **Step 3: README** (German): network creation once (`docker network create bike-maintainer-monitoring`) before
  the first start of either stack; healthchecks; JSON logs note.
- [ ] **Step 4: Commit** `Portal: healthchecks, monitoring network, JSON logs (#9)`.

### Task 9: Monitoring stack: collection and storage

**Files:**
- Create: `monitoring/compose.yaml`, `monitoring/.env.example`, `monitoring/alloy/config.alloy`,
  `monitoring/prometheus/prometheus.yml`, `monitoring/loki/loki.yaml`,
  `monitoring/grafana/provisioning/datasources/datasources.yaml`, `monitoring/compose.dev.yaml`,
  `monitoring/README.md`
- Modify: `README.md` (pointer to `monitoring/`), `.gitignore` (`monitoring/.env`)

**Interfaces:**
- Produces (used by Tasks 10–11): datasource UIDs `prometheus` and `loki`; Loki labels `container`, `level`
  (`ERROR|WARN|INFO|DEBUG`, upper case), `stream`; Prometheus job names `backend`, `alloy-unix`, `alloy-cadvisor`,
  `blackbox` (label `target=app|website`); container names `bike-maintainer-{alloy,prometheus,loki,grafana}`.
- Alloy reads from env: `BM_CONTAINER_PREFIX` (default `bike-maintainer-`), `BM_BACKEND_TARGET`
  (default `bike-maintainer-backend:8081`), `BM_PROBE_APP_URL` (default `https://app.bike-maintainer.de`),
  `BM_PROBE_WEBSITE_URL` (default `https://bike-maintainer.de`).

- [ ] **Step 1: Compose:** four services with pinned Major.Minor tags (look up the current releases of
  `grafana/alloy`, `prom/prometheus`, `grafana/loki`, `grafana/grafana` at implementation time), `restart:
  unless-stopped`, `mem_limit` per Global Constraints, named volumes for Prometheus, Loki, Grafana data; networks:
  internal default, external `bike-maintainer-monitoring` (Alloy), external `${PROXY_NETWORK}` (Grafana only).
  Alloy mounts read-only: `/var/run/docker.sock`, `/proc:/host/proc`, `/sys:/host/sys`, `/:/host/root`,
  `/var/lib/docker:/var/lib/docker` (cadvisor). Prometheus flags `--web.enable-remote-write-receiver`
  `--storage.tsdb.retention.time=30d`. Grafana env: `GF_SECURITY_ADMIN_PASSWORD=${BM_GRAFANA_ADMIN_PASSWORD:?}`,
  `GF_SERVER_ROOT_URL=https://monitoring.bike-maintainer.de`, `GF_USERS_ALLOW_SIGN_UP=false`,
  `GF_AUTH_ANONYMOUS_ENABLED=false`, `GF_ANALYTICS_REPORTING_ENABLED=false`, `GF_ANALYTICS_CHECK_FOR_UPDATES=false`,
  `GF_ANALYTICS_CHECK_FOR_PLUGIN_UPDATES=false`, `GF_SECURITY_DISABLE_GRAVATAR=true`, SMTP `GF_SMTP_*` from `.env`.
- [ ] **Step 2: Loki config:** single binary, filesystem storage, `limits_config.retention_period: 336h`,
  `compactor.retention_enabled: true`, `delete_request_store: filesystem`, auth disabled (internal network only).
- [ ] **Step 3: Alloy config:**
  - Logs: `discovery.docker` → keep containers whose name matches `^/${BM_CONTAINER_PREFIX}.*` and not the
    monitoring containers themselves → `loki.source.docker` → `loki.process`:
    1. `stage.json` extract `log.level` (ECS) → label `level`;
    2. fallback `stage.regex` for `\[(?P<level>ERROR|Warning|Note|WARN|INFO)\]` (MariaDB) and nginx/apache
       `error`/`warn`, mapped to upper case via `stage.template`;
    3. IP truncation, applied to the whole line:
       - IPv4: expression `\b(?:\d{1,3}\.){3}(\d{1,3})\b`, replace `0`;
       - IPv6 global unicast: expression `\b[23][0-9a-fA-F]{3}:[0-9a-fA-F]{1,4}:[0-9a-fA-F]{1,4}((?::[0-9a-fA-F]{0,4}){1,5})`,
         replace `::`.
    → `loki.write` to `http://bike-maintainer-loki:3100`.
  - Metrics: `prometheus.exporter.unix` (`procfs_path=/host/proc`, `sysfs_path=/host/sys`,
    `rootfs_path=/host/root`), `prometheus.exporter.cadvisor` (docker only, `store_container_labels=false`),
    `prometheus.exporter.blackbox` with module `https_2xx` (method GET, `fail_if_not_ssl` true, valid status 2xx/3xx)
    for the two probe URLs, `prometheus.scrape` for `${BM_BACKEND_TARGET}` path `/actuator/prometheus` (job
    `backend`) and the exporters, all `scrape_interval = "15s"` → `prometheus.remote_write` to
    `http://bike-maintainer-prometheus:9090/api/v1/write`.
- [ ] **Step 4: Verify the IP regexes before deploying** with a throwaway Python check (RE2 subset) – expected:
  `203.0.113.17 → 203.0.113.0`; `2001:db8:abcd:12::1 → 2001:db8:abcd::`;
  `2a02:8070:1234:5678:9abc:def0:1234:5678 → 2a02:8070:1234::`; unchanged: `10:23:45`,
  `2026-11-04T10:23:45.123Z`, `took 1234 ms`.
- [ ] **Step 5: Dev override `compose.dev.yaml`:** env `BM_CONTAINER_PREFIX=bike-maintainer-dev-`,
  `BM_BACKEND_TARGET=bike-maintainer-dev-backend:8081`, `BM_PROBE_APP_URL=http://bike-maintainer-dev-frontend/`,
  `BM_PROBE_WEBSITE_URL=http://bike-maintainer-dev-website/`; Alloy and Grafana additionally in external network
  `bike-maintainer-dev_default`; blackbox module without `fail_if_not_ssl` for dev (separate module `http_2xx`
  selected by env `BM_PROBE_MODULE`, default `https_2xx`); Grafana port `127.0.0.1:8300:3000`, SMTP to
  `bike-maintainer-dev-mailpit:1025` without TLS; `PROXY_NETWORK` replaced by `bike-maintainer-dev_default`.
- [ ] **Step 6: Run in dev:** dev stack up (`bike-maintainer-deploy/dev`), backend image built from
  `feature/monitoring`; `cd monitoring && docker compose -f compose.yaml -f compose.dev.yaml up -d`. Check:
  - `docker stats --no-stream` → each monitoring container below its limit;
  - Grafana `http://127.0.0.1:8300` → Explore: Prometheus query `up{job="backend"}` = 1,
    `probe_success` = 1 for app and website, `node_filesystem_avail_bytes` present,
    `container_memory_working_set_bytes{name=~"bike-maintainer-dev-.*"}` present;
  - Loki query `{container="bike-maintainer-dev-backend"}` shows JSON lines with label `level`;
    `{container="bike-maintainer-dev-website"}` access lines show client IPs ending in `.0`;
  - `curl -s http://localhost:8100/actuator/prometheus | head -c 200` → not Prometheus text (Review Focus 3).
- [ ] **Step 7: `monitoring/README.md`** (German): purpose, prerequisites (network, `PROXY_NETWORK`, `.env`),
  start, proxy host `monitoring.bike-maintainer.de` → `bike-maintainer-grafana:3000` with TLS, DNS record,
  self-reachability check (`docker exec bike-maintainer-alloy wget -qO- https://app.bike-maintainer.de` or the
  Alloy UI target page), memory check, dev usage, data protection paragraph (logs with truncated IPs, 14 days, no
  third parties) as text block for the privacy policy, note on nginx-proxy-manager access logs.
- [ ] **Step 8: Commit** `Monitoring stack: Alloy, Prometheus, Loki, Grafana (#9)`.

### Task 10: Alerting

**Files:**
- Create: `monitoring/grafana/provisioning/alerting/contact-points.yaml`, `.../alerting/policies.yaml`,
  `.../alerting/rules.yaml`
- Modify: `monitoring/README.md` (alert list, test procedure), `monitoring/.env.example`

**Interfaces:**
- Consumes: datasource UIDs, labels and jobs from Task 9; metrics from Tasks 1–6.
- Produces: contact point `email` → `${BM_ALERT_EMAIL}` (default `alert@bike-maintainer.de`); policy: group by
  `alertname`, `group_wait 30s`, `group_interval 5m`, `repeat_interval 4h`; folder `Portal`.

- [ ] **Step 1: Rules** (one per row; `for` = duration; NoData/ExecErr handling as given):

| Rule | Query (Prometheus unless noted) | Condition | for | NoData |
|---|---|---|---|---|
| App/Website nicht erreichbar | `probe_success` per target | `== 0` | 2m | Alerting |
| Zertifikat läuft ab | `(probe_ssl_earliest_cert_expiry - time()) / 86400` | `< 14` | 1h | OK |
| Backend-Metriken fehlen | `up{job="backend"}` | `== 0` | 3m | Alerting |
| 5xx-Quote hoch | `sum(rate(http_server_requests_seconds_count{status=~"5.."}[5m])) / sum(rate(http_server_requests_seconds_count[5m]))` with guard `sum(increase(http_server_requests_seconds_count[5m])) >= 20` | `> 0.05` | 5m | OK |
| ERROR-Logs gehäuft (Loki) | `sum by (container) (count_over_time({level="ERROR"}[5m]))` | `> 10` | 0m | OK |
| Viele fehlgeschlagene Logins | `sum(increase(bm_auth_login_total{result!="success"}[15m]))` | `> 30` | 0m | OK |
| Viele Rate-Limit-Treffer | `sum(increase(bm_protection_rate_limited_total[15m]))` | `> 50` | 0m | OK |
| Mail-Zustellung fehlgeschlagen | `sum(increase(bm_mail_delivery_total{result="failure"}[15m]))` | `>= 3` | 0m | OK |
| Mail-Tageslimit fast erreicht | `bm_mail_quota_used / bm_mail_quota_limit` | `>= 0.8` | 0m | OK |
| Platte fast voll | `1 - node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"}` | `> 0.85` | 10m | OK |
| Wenig Arbeitsspeicher | `node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes` | `< 0.10` | 10m | OK |
| Container startet neu | `changes(container_start_time_seconds{name=~"bike-maintainer-.*"}[15m])` | `> 2` | 0m | OK |
| Container fehlt | `time() - container_last_seen{name=~"bike-maintainer-(backend|frontend|mariadb)"}` | `> 120` | 2m | Alerting |
| Keine Daten von Alloy | `up{job="alloy-unix"}` | `== 0` | 5m | Alerting |

  Annotations: German `summary` per rule incl. `{{ $labels.target }}` / `{{ $labels.container }}`.
- [ ] **Step 2: Restart Grafana in dev** → `docker logs bike-maintainer-grafana 2>&1 | grep -i "provisioning.*error"`
  → empty; Alerting UI lists all 14 rules in folder `Portal`, state Normal.
- [ ] **Step 3: Contact point test:** Grafana UI → Contact points → Test → mail arrives in Mailpit (`:8026`).
- [ ] **Step 4: Alarm test:** `docker stop bike-maintainer-dev-frontend` → within ~3 min mail "App … nicht erreichbar"
  in Mailpit; `docker start` → resolved mail. `docker stop bike-maintainer-dev-backend` → "Backend-Metriken fehlen"
  (Review Focus 4); start again.
- [ ] **Step 5: README:** alert table, test procedure, mailbox `alert@` must exist at IONOS.
- [ ] **Step 6: Commit** `Monitoring: alert rules and mail contact point (#9)`.

### Task 11: Dashboards

**Files:**
- Create: `monitoring/grafana/provisioning/dashboards/dashboards.yaml` (file provider, folder `Portal`,
  `allowUiUpdates: false`), `monitoring/grafana/dashboards/portal-overview.json`, `backend.json`, `logs.json`

**Interfaces:**
- Consumes: datasource UIDs `prometheus`, `loki`; metrics and labels from Tasks 1–6 and 9.

- [ ] **Step 1: Build in the dev Grafana UI, export as JSON** (datasource references by UID, no hard-coded
  `bike-maintainer-dev-` names – use a `container` template variable from `label_values`):
  - Portal-Überblick: probe status per target, days to cert expiry, request rate and 5xx ratio, p50/p95 from
    `http_server_requests_seconds_bucket`, CPU/RAM/disk, memory per container.
  - Backend: JVM heap, Hikari active/idle/pending, logins by result, lockouts, rate-limit by group, ALTCHA failures,
    mails by type/result, quota used/limit, report timer count and p95.
  - Logs: variables `container` and `level`, text search box, logs panel and ERROR rate per container.
- [ ] **Step 2: Restart Grafana** → dashboards appear in folder `Portal`, every panel shows data in dev (Mailpit
  traffic: trigger one registration and one report download first).
- [ ] **Step 3: Commit** `Monitoring: dashboards (#9)`.

---

## Rollout (after both PRs are merged, not part of the implementation)

Backend release with the metrics → on the server: `docker network create bike-maintainer-monitoring`, update
`portal/`, fill `monitoring/.env`, start `monitoring/`, proxy host and DNS for `monitoring.`, create `alert@`
mailbox, run the alarm test from Task 10 once against production.
