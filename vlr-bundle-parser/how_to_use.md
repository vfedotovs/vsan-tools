# vlr_sbp.sh – how to use

`vlr_sbp.sh` reads an extracted VMware Live Recovery (VLR) appliance support bundle, versions 9.0.3 to 9.0.5. In one run it prints:

- the appliance configuration
- the services and topology
- certificate configuration, certificate events and certificate changes
- how much time each log covers
- a per-day log health report
- the outcome of the three main appliance workflows: vCenter registration, site pairing, and replication setup

It only reads the bundle and never changes it. If an input file is missing, the script warns, skips only the sections that need that file, and lists what was skipped in the summary at the end.

---

## Requirements

| Needs | Why |
|---|---|
| **bash 4.4 or newer** | associative arrays and `mapfile -d`. The default macOS bash (3.2) fails with `declare: -A: invalid option`. Run it in the Fedora container below, or install bash 5 with `brew install bash`. |
| `grep sed awk sort uniq column xargs find` | core parsing |
| `zcat` (gzip) | reading rotated `*.gz` logs. Without it, `.gz` files are skipped with a warning. |
| `cksum` | detecting duplicate copies of the same log |
| `base64`, `sha256sum`, `sha1sum` | certificate thumbprints (coreutils) |
| `openssl` (optional) | certificate subject, issuer, SAN and validity dates. Without it, only thumbprints are shown. |
| GNU awk recommended | everything is plain POSIX awk, but it was tested with gawk on Fedora 44 |

Any command that's missing is reported in the summary. Only the sections that need it are skipped.

---

## Quick start

### In the Docker container (recommended)

The `Dockerfile` in this folder builds a Fedora 44 image. It contains the Site-A bundle already extracted to `/bundle` and the script at `/usr/local/bin/vlr_sbp.sh`.

```bash
docker build -t vlr-sbp .
docker run --rm vlr-sbp vlr_sbp.sh /bundle                 # full report
docker run --rm -it vlr-sbp                                # interactive shell, then run it yourself
```

To test a changed script without rebuilding the image, mount it over the copy in the image:

```bash
docker run --rm -v "$PWD/vlr_sbp.sh:/usr/local/bin/vlr_sbp.sh:ro" vlr-sbp vlr_sbp.sh /bundle
```

### On any Linux host with bash 4.4+

```bash
unzip -q VMware-DPCA-support-Site-A-*.zip -d site-a
./vlr_sbp.sh site-a                      # or: cd site-a && ../vlr_sbp.sh
./vlr_sbp.sh site-a > site-a-report.txt 2> site-a-warnings.txt
```

`bundle_root_dir` is the folder that contains `var/`, `opt/` and `etc/` from the bundle. If you leave it out, the current directory is used.

---

## Usage

```
./vlr_sbp.sh [options] [bundle_root_dir]
```

### Flags

| Flag | Value | Applies to | Meaning |
|---|---|---|---|
| `-s`, `--sections` | `LIST` | all | Comma-separated list of sections to run. The default is all of them. Valid names: `build,network,services,endpoints,topology,certificates,coverage,health,workflows`. |
| `-f`, `--from` | `YYYY-MM-DD` | health, workflows, certificates | Only count log lines (health), tasks (workflows) or certificate events (certificates) on or after this day. |
| `-t`, `--to` | `YYYY-MM-DD` | health, workflows, certificates | Only count log lines, tasks or certificate events on or before this day. |
| `-l`, `--log` | `REGEX` | coverage, health | Only use log files whose path (relative to the bundle root) matches this bash extended regex, e.g. `'srm/\|hms/'`. |
| `-n`, `--top` | `N` | health | Number of rows in the top error, warning and exception tables. The default is 15. |
| `-a`, `--all-days` | – | health, workflows | health: list every log/day row, not just problem days. workflows: list every task even when a phase has more than 100. |
| `-h`, `--help` | – | – | Print the usage text and exit. |
| `--` | – | – | End of options; the next argument is the bundle root, even if it starts with `-`. |

Options and the bundle root can be given in any order. The script exits with code 2 if an option is unknown, a date isn't `YYYY-MM-DD`, `--from` is after `--to`, `--top` isn't a positive number, `--log` isn't a valid regex, or a section name is unknown.

### Examples

```bash
./vlr_sbp.sh /bundle                                         # everything
./vlr_sbp.sh -s build,network,services /bundle               # quick configuration check
./vlr_sbp.sh -s workflows /bundle                            # registration, pairing, replication outcomes
./vlr_sbp.sh -s certificates /bundle                         # certificate inventory, events and changes
./vlr_sbp.sh -s certificates -f 2026-06-28 /bundle           # certificate events on/after 06-28 only
./vlr_sbp.sh -s health -f 2026-06-26 -t 2026-06-28 /bundle   # health around an incident
./vlr_sbp.sh -s coverage,health -l 'srm/|hms/' -n 25 /bundle # only SRM and HMS logs, longer top tables
./vlr_sbp.sh -s health -a /bundle > health-all-days.txt      # every log/day row
```

### Exit codes

| Code | Meaning |
|---|---|
| 0 | Finished, and at least one section produced output. Any skipped sections are listed in the summary. |
| 1 | Finished, but every section was skipped. This usually means the wrong directory was given. |
| 2 | Usage error: a bad option, or the bundle root isn't a readable directory. |

The report goes to **stdout**. Warnings (missing files, skipped sections, unreadable `.gz` files) go to **stderr**.

---

## Sections

They run in this order. Each one starts with a title and a `====` line.

### `build` – appliance version and build
Source: `opt/vmware/etc/appliance-manifest.xml`. Shows the release date and the product description line, for example `VMware Live Recovery Appliance 9.0.4.0 build 24963726`.

### `network` – network settings and NTP
Source: `opt/vmware/etc/vami/ovfEnv.xml`. Shows the OVF properties for IP, prefix, gateway, DNS, domain, search path, NTP server and hostname.

### `services` – service states
Source: `opt/vmware/etc/va-configurator/svc-state.json`. One row per service (`dr-backup`, `dr-client`, `hms`, `aps`, `vmware-dr`, …) with its state, e.g. `CONFIGURED`.

### `endpoints` – service endpoint URLs
Source: every `opt/vmware/etc/*/svc-config.json`. Lists all `https` URLs each service is configured with. Use it to check hostnames, FQDN versus short name, and ports.

### `topology` – vCenters, VLR appliances and nodes seen
Source: `var/log/vmware/dr-client/dr.topology.log`. Three tables:
- **Topology VCenters seen**: each vCenter URL with the number of times it appears.
- **Topology VLR appliances seen**: each VRMS/VLR URL with its count. Watch for the same appliance listed under both a short name and an FQDN.
- **Topology nodes**: one row per node (handle, host, site, node, service) at its latest timestamp.

### `certificates` – certificate configuration, events and changes
Sources: the configuration files under `opt/vmware/etc` and `etc`, and every log (rotations included, duplicate copies read once). This section takes about 15 seconds. `openssl` is optional: without it, certificates are identified by thumbprint only (computed with `base64` and `sha256sum`/`sha1sum`); with it, subject, issuer, SAN and validity dates are shown as well. The Docker image includes `openssl`.

It prints six blocks:

1. **Certificates in configuration.** Every base64 DER (`MII…`) or PEM certificate found in the config files, one row per unique certificate: SHA-256 and SHA-1 thumbprints, subject, issuer, SAN, valid from/to, **days_left** and **status** (OK, EXPIRING = fewer than 30 days left, EXPIRED). Days left are counted from the **bundle time**, which is the newest file in `var/log`, not today. Below that, **where each certificate is used**:
   - `svc-config.json` `certificate @ <vCenter>` is the vCenter certificate each service trusts.
   - `certificate @ <site name>` is the appliance's own certificate.
   - `sslTrust[] @ <url>` is the certificate published for that endpoint in the Lookup Service registration.
   - `trust store: <host> / <service>` is an entry in the APS or SRM `ssl-trust-store-*.xml` (which certificate is trusted for which host and service, e.g. HMS, DR, APS, VSANSS).
   - Others are named after their key, e.g. `hms-ls-cert` (`hms-configuration.xml`) or `vcCertificate` (`drplugin.properties`).
2. **Pinned thumbprints in configuration.** Thumbprint settings such as `hms-localvc-thumbprint`, `hms-ls-thumbprint`, `PscThumbprint`, `VcThumbprint`, `lsppThumbprint` and `backupServiceThumbprint`, each matched to the certificate above that it belongs to. A pinned thumbprint with "(no configured certificate with this thumbprint)" means the pin no longer matches any stored certificate, which is typical after a certificate was replaced and the pin wasn't updated.
3. **Certificate and TLS settings.** `hms-trust-mode` (1 = lenient: a remote certificate is accepted if its thumbprint matches vSphere; 0 = strict: also checks expiry, hostname and CA chain), `hms-allow-legacy-hash-algo`, `hms-certificate-warning-period`, `hms-ssl-enabled-protocols`, `hms-ssl-context-protocol`, `sync-peer-site-host-certificates-on-boot`, SRM `minCertRemainingTime` and `disableNFCServerCertificateChecks`, `enableSsl`, the FIPS mode, and certificate file paths (`vcCertPath`, `vc-cert-path`). Passwords and secrets are never printed.
4. **Certificate events in logs.** Grouped by event, target and detail, with first, last, count and the logs they came from. `--from`/`--to` apply here.

   | Event | Where it comes from | What it means |
   |---|---|---|
   | certificate generated/installed | `dpca-init` "Generated new certificate", `hbrsrv-generate-certificate.log`, "certificate … generated/installed/replaced" | a new appliance or replication server certificate |
   | service account certificate recreated | SRM / dr-backup "Recreating local service account '…' certificate" | the solution user certificate was renewed |
   | certificate file changed | dr-rest / dr-client `FileWatcher` "File vc.certificate was ENTRY_CREATE/MODIFY" | the stored vCenter certificate file was written |
   | certificate change via VAMI (Success/Failure) | va-config audit `drConfig.SslCertificateManager.<method>`, except get/probe/retrieve | someone changed the appliance certificate in VAMI |
   | certificate change via UI | drconfigui requests named `*Certificate*` that aren't `get…` | the same, from the configuration UI |
   | certificate change event | HMS `…CertificateChangedEvent` being handled (not the handler registration at startup) | HMS noticed a VC, VR server or broker certificate change |
   | SSL handshake failed (untrusted) | vmacore "SSL client handshake to 'host:port' failed", plus the problem (e.g. "unable to get local issuer certificate") and the peer SHA-1 | a probe of that host saw an untrusted certificate |
   | thumbprint mismatch | `…$ThumbprintMismatch` (e.g. `CheckPscCredentialsRequestHandler` during pairing), "thumbprint mismatch" | the certificate presented doesn't match the expected thumbprint. This blocks pairing. |
   | certificate verification failed | HMS "[hmssrv/hbrsrv] certificate verification failed for remote server … at host" | HMS rejected a remote certificate |
   | client rejected appliance certificate | envoy `TLS_error … CERTIFICATE_UNKNOWN / BAD_CERTIFICATE / UNKNOWN_CA` with the client IP | a browser or client doesn't trust the appliance certificate |
   | Java TLS trust failure | `PKIX path building failed`, `unable to find valid certification path`, `SSLHandshakeException` | a Java service doesn't trust a peer |
   | certificate expiring/expired | `SrmCertificateExpiring/ExpiredEvent` raised, "certificate expired/expiring" (not the event-type registration lines) | expiry warning |
   | new thumbprint trusted | dr-client / dr-rest `DynamicVerifier` "Added thumbprint '…'" | a thumbprint was added to the in-memory trust list. A thumbprint never seen before suggests a new certificate. |

5. **Certificates presented by hosts in failed SSL probes.** When a vmacore probe fails, the log contains the full certificate the host presented (`PeerCertificate`). These are decoded and grouped per host: first and last seen, number of probes, SHA-256, subject and validity. **If the same host shows more than one certificate, it's flagged `CHANGED:`**, meaning that host's certificate was replaced between those times.
6. **Thumbprints seen in logs.** Every SHA-1 or SHA-256 thumbprint in any log line, with first and last seen, count, the host it was seen with, the configured certificate it matches, and which logs it appeared in. The host is a best guess: it comes from a URL, a `_lsppHost` / `hostId` / `address` value, or a `'host:port'` on the same line or up to 3 lines before. A thumbprint that **first appears part way through the logs**, or doesn't match a configured certificate, suggests a new or replaced certificate. Remote-site certificates first appear when pairing starts.

### `coverage` – line count and time window per log file
Source: every `*.log` and `*.gz` under the bundle root, including rotated files such as `vmware-dr-3.log.gz`, `messages.1.gz` and `envoy.log.1.gz`. `.gz` files are read through `zcat`.

One row per file:

```
lines    start                end                  file
68178    2026-06-11 18:08:55  2026-06-28 19:55:12  var/log/vmware/dr-backup/dr-backup.log
...
31192997 2025-09-17 12:08:30  2026-06-28 19:56:32  TOTAL (343 files)
```

- **lines** counts awk records, so a last line without a trailing newline still counts.
- **start / end** are the earliest and latest timestamps found in the file, not just the first and last lines.
- `-` means the file has no recognised timestamps. That's normal for install scripts, `lastlog` (binary), and empty files.
- A `.gz` that fails part way is still listed with whatever could be read, and is marked `(gzip error)`.

Use it to answer: do the logs cover the time of the problem, and did any log rotate away the interesting period?

### `health` – log health per day
Source: the same files as `coverage`. This is the slowest section, about a minute for 5–6 GB of decompressed logs; `-f`, `-t` or `-l` make it faster.

It prints six blocks:

1. **Duplicate files skipped.** The bundle often contains the same log twice, e.g. `vmware-dr.log` and `vmware-dr-7.log`. Files of the same log with the same checksum are read only once.
2. **Appliance timeline.** One row per day for all logs combined: lines, events, error, warn, fatal, traces, err/1k, the number of logs at CRIT, the status, and a `#` bar scaled to the worst day.
3. **Per-log summary.** One row per log, sorted by errors: days covered, totals, err/1k, worst day (with its error count), how many days were OK / LOW / WARN / CRIT, and health%.
4. **Per log per day.** Only WARN and CRIT days and spikes; `-a` shows every day.
5. **Top ERROR/FATAL signatures** and **top WARN signatures.** Repeated messages are grouped, with IDs, UUIDs, hex values, IP addresses and numbers masked. Each row shows the count and the first and last day seen.
6. **Top exceptions, causes and faults.** Java stack-trace exception classes, `Caused by:` classes, and SRM `*.fault.*` types. Each is tagged with the level of the event it belongs to, so INFO-level `java.lang.Exception: stack info (debug trace)` entries can be told apart from real failures.

### `workflows` – appliance work phases
Counts each workflow's attempts and their outcome. It reads every rotation of the source logs, skipping duplicate copies. `--from`/`--to` filter on the day a task started.

| Phase | What it covers | Where it is found | Start | End |
|---|---|---|---|---|
| **1. VLR registration with vCenter** | the VAMI (appliance management UI) *Configure* / *Reconfigure* task and its *Validate connection* / *Find Conflicts* checks | `va-config` logs. A task is every event with the same `opID=…-configure`. | first event with that opID | `--> Configure task succeeded./failed. (N sec)`. The detail column shows the vCenter used and the number of Lookup Service registrations created. |
| **2. Site pairing** | pairing tasks from the UI, plus HMS pairing and repair | `dr-client/dr.log` UI tasks whose name contains `pair` (`pairServices`), and HMS `PairHmsTask` / `RepairHmsTask` | `Created new task` / `handleHmsTaskStartedEvent` | `completed successfully` / `completed with error` plus the fault from the next lines (e.g. `hms.remote.fault.AlreadyPairedFault`), or HMS `success: true/false` plus the `error:` text |
| **3. Replication configuration per VM** | creating a VM replication | HMS `Configure replication` (this site is the source) and `Configure Replication Secondary` (this site is the target), and `dr-client` `configureReplications` UI tasks | HMS started event; the VM name and moref come from the replication spec | HMS finished event, with the group ID (`GID-…`) |

Each phase prints:
- **Summary.** Grouped by source and task: attempts, succeeded, failed, no_result (started, but no end found in the logs), and first and last time seen.
- **Tasks.** In time order: start, end, source, task, result, detail (vCenter / remote site / `VM name (vm-N); GID`), and the error. If a phase has more than 100 tasks, only the ones that didn't succeed are listed unless you use `-a`.
- **Audited API calls.** `[Success]`/`[Failure]` counts per method from the va-config, aps-service and vmware-dr audit logs. For example, phase 1 shows `drConfig.ConfigurationManager.configure` and phase 2 shows `aps.site.SiteManager.remoteSetConnectionInfo`.

Things to keep in mind:
- The UI (`dr-client`) creates **two** tasks for each replication you configure. **Count VMs from the HMS rows.**
- HMS and the UI can disagree, and the difference matters. For example, the HMS `Pair` can succeed while the UI `pairServices` fails with `AlreadyPairedFault`.
- If the registration happened before the oldest rotated `va-config` file, phase 1 is empty.

### Summary
Always printed at the end: the bundle root, sections run versus selected, missing files or commands, and skipped sections with the reason.

---

## How it works

### Timestamps
The `coverage`, `health` and `workflows` sections share one timestamp parser. It only looks at the **start of the line** (ISO timestamps within the first 40 characters, the other formats at the very start). Dates inside message text, such as `tokenExpirationTime = Tue Jun 30 …`, are therefore ignored. All times are treated as UTC, which is how VLR logs.

| Format | Example | Seen in |
|---|---|---|
| ISO | `2026-06-11T18:08:55.210Z`, `2026-06-06 20:49:28,269`, `[2026-…`, JSON `"timestamp":"2026-…"` | most services |
| Tomcat | `23-Jun-2026 04:18:31.862` | catalina / localhost logs |
| `date` | `Sat Jun 6 07:25:45 PM UTC 2026` | vmware-network, hbrsrv cert |
| Java | `Jun 06, 2026 7:25:55 PM` | `catalina.out` |
| auditd epoch | `msg=audit(1782662209.651:…)` | `audit.log` |
| epoch at line start | `1780773946 HBRSERVERSTATS …` | hbrsrv `*.stats` |

### Log names (rotations merged)
In the `health` and `workflows` sections, rotated files are grouped into one log name:

| File | Log |
|---|---|
| `vmware-dr-7.log`, `vmware-dr-3.log.gz` | `vmware-dr.log` |
| `hms.0000078.log.gz`, `hms.0000079.log` | `hms.log` |
| `catalina.2026-06-11.log` | `catalina.log` |
| `messages.3.gz`, `envoy.log.1.gz` | `messages`, `envoy.log` |

### Health terms
| Term | Meaning |
|---|---|
| event | a line that starts with a timestamp. Lines without one (stack frames, `-->` fault details) belong to the event above them. |
| level | the first level word in the first 120 characters of the event. **FATAL** = FATAL, CRITICAL, PANIC, postgres `FATAL:`. **ERROR** = ERROR, error, SEVERE, JSON `"level":"error"`. **WARN** = WARN, WARNING, warning. Syslog files (`messages`, `cron`) have no levels and only count as events. |
| trace | one stack trace: a run of Java `at …(` frames (a `Caused by:` block continues the same trace), a vmacore `Backtrace:`, a Go `panic:` (also counted as FATAL), or a Python `Traceback`. |
| err/1k | ERROR + FATAL events per 1,000 events |
| status | **OK** = no ERROR or FATAL. **LOW** = err/1k under 1. **WARN** = err/1k from 1 up to 10. **CRIT** = err/1k 10 or more, or any FATAL. |
| SPIKE | a day with at least 10 errors and at least 3× the median daily errors of that log |
| health% | the share of a log's days that are OK or LOW |
| undated | lines before a file's first timestamp. Dropped when `--from` or `--to` is used. |

The thresholds are set in `status()` inside `HEALTH_AGG_AWK` in the script.

### Script layout
| Part | What it is |
|---|---|
| header comment | the usage text that `--help` prints, and the exit codes |
| `REQUIRED_FILES`, `REQUIRED_CMDS` | inputs checked before any section runs |
| `parse_args`, `want_section` | option parsing and section selection |
| `list_log_files`, `pick_logs`, `log_family`, `read_log` | finding log files, filtering them, skipping duplicates, decompressing |
| `AWK_TS_LIB` | the shared timestamp parser (`ts_of`) |
| `section_*` | one function per report section |
| `HEALTH_FILE_AWK` / `HEALTH_AGG_AWK` | health: a parser that runs once per file, then a step that combines the results |
| `WF_*_AWK`, `print_phase` | workflows: one parser per source (va-config, dr-client, HMS, audit), then the step that combines them |
| `CERT_CFG_AWK`, `CERT_LOG_AWK`, `cert_row`, `thumb` | certificates: config scan, log event scan, certificate decoding (openssl or base64 + sha*sum) |
| `main` | runs the selected sections, then prints the summary |

The script is a single file on purpose. Support engineers copy it around, so it has no shared library.

---

## Typical triage flow

1. `-s build,network,services`: check the version, hostname/DNS/NTP, and that every service is `CONFIGURED`.
2. `-s coverage`: make sure the logs cover the time of the incident.
3. `-s workflows`: check whether registration, pairing and replication setup succeeded, and if not, which fault they hit.
4. `-s certificates`: check certificate validity, which thumbprints are pinned, and whether any certificate changed, wasn't trusted, or caused a thumbprint mismatch.
5. `-s health -f <day before> -t <day after>`: find which log went bad on which day, then use the top signatures and exceptions to find what to grep for.
6. Open the specific log at the times the report points to.

Run the script on **both** sites' bundles. Pairing problems often only make sense when you see both sides.
