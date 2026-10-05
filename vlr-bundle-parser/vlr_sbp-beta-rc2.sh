#!/usr/bin/env bash
# vlr_sbp.sh - converged VLR bundle parser for 9.0.3, 9.0.4, and 9.0.5
# Was sb_vlr_905.sh. SRM 8.x-9.0.2: srm_sb_log_parser.sh. VRMS 9.0-9.0.2.x: vrms_sbp.sh.
#
# Usage: ./vlr_sbp.sh [options] [bundle_root_dir]
#   bundle_root_dir  extracted VLR bundle (default: .)
#   -s, --sections LIST  comma separated sections to run (default: all):
#                        build,network,services,endpoints,topology,certificates,coverage,health,workflows
#   -f, --from DATE      health, workflows, certificates: only lines/tasks/events on or after DATE (YYYY-MM-DD)
#   -t, --to DATE        health, workflows, certificates: only lines/tasks/events on or before DATE (YYYY-MM-DD)
#   -l, --log REGEX      coverage + health: only log files whose path matches REGEX
#   -n, --top N          health: rows in the top signature/exception tables (default 15)
#   -a, --all-days       health: every log/day row; workflows: every task, also above 100
#   -h, --help           show this help
#
# Examples:
#   ./vlr_sbp.sh /bundle
#   ./vlr_sbp.sh -s health -f 2026-06-26 -t 2026-06-28 /bundle
#   ./vlr_sbp.sh -s coverage,health -l 'srm/|hms/' -n 25 /bundle
#   ./vlr_sbp.sh -s workflows /bundle
#   ./vlr_sbp.sh -s certificates /bundle
#
# A missing input file is NOT fatal: it is reported on stderr, only the
# sections that need it are skipped, and a summary is printed at the end.
# The helpers below are copied, not sourced. Support engineers copy single
# scripts around, so there is no shared lib_bundle.sh.
#
# Exit codes:
#   0  finished and at least one section produced output
#      (missing files / skipped sections, if any, are listed in the summary)
#   1  finished but every section was skipped - nothing usable was found
#      (most likely the wrong directory)
#   2  usage error: bad option, or bundle_root_dir is not a readable directory

set -uo pipefail   # no -e: grep exits 1 on "no match", which is normal here

# TODO roadmap
# Extract copnfioguiration
# 1. Build  [ok]
# 2. Hostname [ok]
# 3. network settings [ok]
# 4. ntp settings [ok]
# 5  certificate settings  [vip]
# 6. topology [vip]
# 7. key applaince crud events
#       deploy configure
#       reconfigure aka join to VC
#       create site pair
#       create replication jobn
#       replication job state
#
#Appliance service states
# Errors in log files

BUNDLE_ROOT="."         # set by parse_args
OPT_SECTIONS=""         # empty = all sections
OPT_FROM=""
OPT_TO=""
OPT_LOG=""
OPT_TOP=15
OPT_ALL_DAYS=0
ALL_SECTIONS="build,network,services,endpoints,topology,certificates,coverage,health,workflows"

# --- Required files (relative to BUNDLE_ROOT, globs allowed) ------------------
APPLIANCE_MANIFEST="opt/vmware/etc/appliance-manifest.xml"
OVF_ENV="opt/vmware/etc/vami/ovfEnv.xml"
SVC_STATE="opt/vmware/etc/va-configurator/svc-state.json"
SVC_CONFIG="opt/vmware/etc/*/svc-config.json"
TOPOLOGY_LOG="var/log/vmware/dr-client/dr.topology.log"

REQUIRED_FILES=(
    "$APPLIANCE_MANIFEST"   # appliance version and build
    "$OVF_ENV"              # network settings and NTP
    "$SVC_STATE"            # service states
    "$SVC_CONFIG"           # service endpoint URLs
    "$TOPOLOGY_LOG"         # vCenter and VLR URL counts, and the per-node table
)
REQUIRED_CMDS=(grep sed awk sort uniq column xargs find zcat cksum)

# --- State ---------------------------------------------------------------------
declare -A FOUND=()     # pattern -> matching paths, newline separated
declare -A HAVE_CMD=()  # command -> 1 if available
MISSING=()              # missing files/commands, for the summary
SKIPPED=()              # skipped sections, for the summary
SECTIONS_RUN=0
SECTIONS_TOTAL=0

# --- Helpers -------------------------------------------------------------------
warn() { echo "WARNING: $*" >&2; }

print_section() {
    echo ""
    echo "$*"
    echo "===================================="
}

# skip_section <section> <reason>
skip_section() {
    warn "skipping section '$1': $2"
    SKIPPED+=("$1 - $2")
}

# have_file <pattern>: true if check_required_files found at least one match
have_file() { [[ -n "${FOUND[$1]:-}" ]]; }

# files_for <pattern>: print the matching paths, one per line
files_for() { printf '%s\n' "${FOUND[$1]}"; }

check_required_files() {
    local pattern match IFS=   # IFS= : expand globs but don't split on spaces
    local -a matches
    shopt -s nullglob
    for pattern in "${REQUIRED_FILES[@]}"; do
        matches=()
        # $pattern is intentionally unquoted so the glob expands
        for match in "$BUNDLE_ROOT"/$pattern; do
            if [[ -f "$match" && -r "$match" ]]; then
                matches+=("$match")
            elif [[ -e "$match" ]]; then   # literal (non-glob) paths come back as-is
                warn "required file not readable, ignored: $match"
            fi
        done
        if (( ${#matches[@]} > 0 )); then
            FOUND[$pattern]="$(printf '%s\n' "${matches[@]}")"
        else
            warn "required file missing: $BUNDLE_ROOT/$pattern"
            MISSING+=("file: $BUNDLE_ROOT/$pattern")
        fi
    done
    shopt -u nullglob
}

check_required_cmds() {
    local cmd
    for cmd in "${REQUIRED_CMDS[@]}"; do
        if command -v "$cmd" >/dev/null 2>&1; then
            HAVE_CMD[$cmd]=1
        else
            warn "required command missing: $cmd"
            MISSING+=("command: $cmd")
        fi
    done
}

# have_cmds <cmd> [cmd...]: true when every named command was found
have_cmds() {
    local cmd
    for cmd in "$@"; do
        [[ -n "${HAVE_CMD[$cmd]:-}" ]] || return 1
    done
}

usage() {
    # print the header comment block from "Usage:" down to the exit codes
    sed -n '/^# Usage:/,/^# A missing input/{/^# A missing input/d;s/^# \{0,1\}//;p;}' "$0"
}

usage_error() {
    echo "ERROR: $*" >&2
    echo "Run '$0 --help' for usage." >&2
    exit 2
}

# need_value <option> <value...>: the option must be followed by a value
need_value() { (( $# >= 2 )) || usage_error "option '$1' needs a value"; }

is_date() { [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; }

parse_args() {
    local root_set=0 s
    while (( $# > 0 )); do
        case "$1" in
            -h|--help)     usage; exit 0 ;;
            -s|--sections) need_value "$@"; OPT_SECTIONS="$2"; shift 2 ;;
            -f|--from)     need_value "$@"; OPT_FROM="$2"; shift 2 ;;
            -t|--to)       need_value "$@"; OPT_TO="$2"; shift 2 ;;
            -l|--log)      need_value "$@"; OPT_LOG="$2"; shift 2 ;;
            -n|--top)      need_value "$@"; OPT_TOP="$2"; shift 2 ;;
            -a|--all-days) OPT_ALL_DAYS=1; shift ;;
            --)            shift; break ;;
            -*)            usage_error "unknown option '$1'" ;;
            *)
                (( root_set == 0 )) || usage_error "more than one bundle_root_dir given: '$BUNDLE_ROOT' and '$1'"
                BUNDLE_ROOT="$1"; root_set=1; shift ;;
        esac
    done
    if (( $# > 0 )); then
        (( root_set == 0 && $# == 1 )) || usage_error "unexpected arguments: $*"
        BUNDLE_ROOT="$1"
    fi
    BUNDLE_ROOT="${BUNDLE_ROOT%/}"
    [[ -n "$BUNDLE_ROOT" ]] || BUNDLE_ROOT="/"
    if [[ -n "$OPT_FROM" ]] && ! is_date "$OPT_FROM"; then usage_error "--from '$OPT_FROM' is not YYYY-MM-DD"; fi
    if [[ -n "$OPT_TO" ]] && ! is_date "$OPT_TO"; then usage_error "--to '$OPT_TO' is not YYYY-MM-DD"; fi
    if [[ -n "$OPT_FROM" && -n "$OPT_TO" && "$OPT_FROM" > "$OPT_TO" ]]; then
        usage_error "--from $OPT_FROM is after --to $OPT_TO"
    fi
    [[ "$OPT_TOP" =~ ^[1-9][0-9]*$ ]] || usage_error "--top '$OPT_TOP' is not a positive number"
    if [[ -n "$OPT_LOG" ]]; then
        # [[ =~ ]] returns 2 for an invalid regex
        [[ "" =~ $OPT_LOG ]] 2>/dev/null
        (( $? != 2 )) || usage_error "--log '$OPT_LOG' is not a valid regular expression"
    fi
    if [[ -n "$OPT_SECTIONS" ]]; then
        for s in ${OPT_SECTIONS//,/ }; do
            [[ ",$ALL_SECTIONS," == *",$s,"* ]] || usage_error "unknown section '$s' (valid: $ALL_SECTIONS)"
        done
    fi
}

# want_section <name>: true when --sections is unset or lists <name>
want_section() { [[ -z "$OPT_SECTIONS" || ",$OPT_SECTIONS," == *",$1,"* ]]; }

# list_log_files: fill LOG_FILES with every *.log and *.gz under BUNDLE_ROOT,
# sorted by path and filtered by --log. *.gz files are left out when zcat is
# missing. Runs once; later calls reuse the list.
LOG_FILES=()
LOG_FILES_LISTED=0
list_log_files() {
    local f
    local -a all
    (( LOG_FILES_LISTED )) && return
    LOG_FILES_LISTED=1
    if have_cmds zcat; then
        mapfile -d '' -t all < <(find "$BUNDLE_ROOT" -type f \( -name '*.log' -o -name '*.gz' \) -print0 2>/dev/null | sort -z)
    else
        warn "zcat not available: *.gz files are left out of the log sections"
        mapfile -d '' -t all < <(find "$BUNDLE_ROOT" -type f -name '*.log' -print0 2>/dev/null | sort -z)
    fi
    for f in "${all[@]}"; do
        if [[ -n "$OPT_LOG" && ! "${f#"$BUNDLE_ROOT"/}" =~ $OPT_LOG ]]; then
            continue
        fi
        LOG_FILES+=("$f")
    done
}

# print_tsv <header> <rows>: tab separated rows as aligned columns
print_tsv() {
    local formatted
    if formatted=$(printf '%s\n%s\n' "$1" "$2" | column -t -s $'\t' 2>/dev/null); then
        printf '%s\n' "$formatted"
    else
        printf '%s\n%s\n' "$1" "$2"
    fi
}

# --- Sections ------------------------------------------------------------------

section_build() {
    local name="VLR appliance version and build" f
    local -a files
    SECTIONS_TOTAL=$(( SECTIONS_TOTAL + 1 ))
    if ! have_file "$APPLIANCE_MANIFEST"; then
        skip_section "$name" "no '$APPLIANCE_MANIFEST' file found"
        return
    fi
    print_section "$name"
    mapfile -t files < <(files_for "$APPLIANCE_MANIFEST")
    for f in "${files[@]}"; do
        grep -E "releaseDate|description" "$f" || echo "(no version info in this file)"
    done
    SECTIONS_RUN=$(( SECTIONS_RUN + 1 ))
}

section_network() {
    local name="VLR appliance network settings + NTP" f out
    local -a files
    SECTIONS_TOTAL=$(( SECTIONS_TOTAL + 1 ))
    if ! have_file "$OVF_ENV"; then
        skip_section "$name" "no '$OVF_ENV' file found"
        return
    fi
    if ! have_cmds grep awk; then
        skip_section "$name" "required command not available"
        return
    fi
    print_section "$name"
    mapfile -t files < <(files_for "$OVF_ENV")
    for f in "${files[@]}"; do
        out=$(grep "Property" "$f" | grep -E "network|ntpserver|hostname" | awk -F '=' '{print $2, $3}' || true)
        if [[ -n "$out" ]]; then
            printf '%s\n' "$out"
        else
            echo "(no network or ntp properties)"
        fi
    done
    SECTIONS_RUN=$(( SECTIONS_RUN + 1 ))
}

section_services() {
    local name="Services on VLR" f
    local -a files
    SECTIONS_TOTAL=$(( SECTIONS_TOTAL + 1 ))
    if ! have_file "$SVC_STATE"; then
        skip_section "$name" "no '$SVC_STATE' file found"
        return
    fi
    if ! have_cmds sed xargs column; then
        skip_section "$name" "required command not available"
        return
    fi
    print_section "$name"
    mapfile -t files < <(files_for "$SVC_STATE")
    for f in "${files[@]}"; do
        sed -e 's/{//g' -e 's/}//g' "$f" | xargs -n 4 | column -t || true
    done
    SECTIONS_RUN=$(( SECTIONS_RUN + 1 ))
}

section_endpoints() {
    local name="VLR srvice endpoinds from all json files" f
    local -a files
    SECTIONS_TOTAL=$(( SECTIONS_TOTAL + 1 ))
    if ! have_file "$SVC_CONFIG"; then
        skip_section "$name" "no '$SVC_CONFIG' file found"
        return
    fi
    if ! have_cmds grep column; then
        skip_section "$name" "required command not available"
        return
    fi
    print_section "$name"
    mapfile -t files < <(files_for "$SVC_CONFIG")
    for f in "${files[@]}"; do
        # grep -H so a single file still shows its path. -v protocol drops the
        # protocol property lines the old pipeline excluded.
        grep -H https "$f" || true
    done | grep -v protocol | column -t || true
    SECTIONS_RUN=$(( SECTIONS_RUN + 1 ))
}

# Sample endpoint lines (hostnames are placeholders):
# opt/vmware/etc/vmware-dr/svc-config.json:    "url":       "https://vlr01.example.com:443/drserver/vcdr/vmomi/sdk",
# opt/vmware/etc/vmware-dr/svc-config.json:    "url":       "https://vlr01.example.com:443/drserver/vcdr/extapi/sdk",
# opt/vmware/etc/vmware-dr/svc-config.json:    "url":       "https://vlr01.example.com:5480/configureserver/sdk",
# opt/vmware/etc/vmware-dr/svc-config.json:    "value":     "https://vlr01.example.com:5480/configure"
# opt/vmware/etc/hms/svc-config.json:          "url":       "https://vlr01.example.com:443/vrms",
# opt/vmware/etc/hms/svc-config.json:          "value":     "https://vlr01:443/vrms/versions/hms-supported-versions.xml"
# opt/vmware/etc/hms/svc-config.json:          "value":     "https://vlr01:5480"
# opt/vmware/etc/dr-backup/svc-config.json:    "url":       "https://vlr01.example.com:443/backupserver",
# opt/vmware/etc/dr-rest/svc-config.json:      "entityId":  "https://vlr01.example.com/api/rest",
# opt/vmware/etc/dr-client/svc-config.json:    "url":       "https://vlr01.example.com:443/dr",
# opt/vmware/etc/dr-client/svc-config.json:    "entityId":  "https://vlr01.example.com/dr",
# opt/vmware/etc/dpx-agent/svc-config.json:    "url":       "https://vlr01.example.com:443/dpx/api",
# opt/vmware/etc/snapservice/svc-config.json:  "url":       "https://vlr01.example.com:443/api/snapservice",
# opt/vmware/etc/snapservice/svc-config.json:  "url":       "https://vlr01.example.com:443/snapservice",
# opt/vmware/etc/aps/svc-config.json:          "url":       "https://vlr01.example.com:443/aps/sdk",

# all json config files on applinace
#└─$ find . -iname '*.json'
# ./var/log/poi/manifest.json
#
# ./opt/vmware/etc/vmware-dr/svc-config.json
# ./opt/vmware/etc/vmware-dr/config-spec.json
#
# ./opt/vmware/etc/hms/svc-config.json
# ./opt/vmware/etc/hms/config-spec.json
#
# ./opt/vmware/etc/dr-backup/svc-config.json
# ./opt/vmware/etc/dr-backup/config-spec.json
#
# ./opt/vmware/etc/dr-rest/svc-config.json
# ./opt/vmware/etc/dr-rest/config-spec.json
#
# ./opt/vmware/etc/dr-client/svc-config.json
# ./opt/vmware/etc/dr-client/config-spec.json
#
# ./opt/vmware/etc/envoy/envoy-proxy-config.json
#
# ./opt/vmware/etc/snapservice-ui/svc-config.json
# ./opt/vmware/etc/snapservice-ui/config-spec.json
#
# ./opt/vmware/etc/dpx-agent/svc-config.json
# ./opt/vmware/etc/dpx-agent/config-spec.json
# ./opt/vmware/etc/appliance/fips.json
#
# ./opt/vmware/etc/dr-client-plugin/svc-config.json
# ./opt/vmware/etc/dr-client-plugin/config-spec.json
#
# ./opt/vmware/etc/snapservice/mockdata/mockdata.json
# ./opt/vmware/etc/snapservice/svc-config.json
# ./opt/vmware/etc/snapservice/appliance_config/configuration_spec.json
# ./opt/vmware/etc/snapservice/metadata/com.vmware.snapservice_internal_metadata.json
# ./opt/vmware/etc/snapservice/metadata/com.vmware.snapservice_metadata.json
#
# ./opt/vmware/etc/va-configurator/custom-config.json
# ./opt/vmware/etc/va-configurator/svc-state.json
#
# ./opt/vmware/etc/aps/svc-config.json
# ./opt/vmware/etc/aps/config-spec.json

# One row per node from dr.topology.log. Pure awk, copied into this script
# and into srm_sb_log_parser.sh. No shared library and no embedded python.
# Latest timestamp wins. A blank field on a later line does not erase an
# earlier value. A line with none of these fields (including URL-only lines)
# is ignored.
print_topology_nodes() {
    local file="$1" table formatted
    if [[ -z "${HAVE_CMD[awk]:-}" ]]; then
        echo "(awk not available; per-node table skipped)"
        return
    fi
    table=$(awk '
        function strip(s) {
            gsub(/^[ \t]+|[ \t]+$/, "", s)
            gsub(/^\{+|\}+$/, "", s)
            gsub(/^\[+|\]+$/, "", s)
            gsub(/^"+|"+$/, "", s)
            gsub(/,+$/, "", s)
            return s
        }
        function key_of(token,    p, name) {
            p = index(token, "=")
            if (p == 0) p = index(token, ":")
            name = token
            if (p > 1) name = substr(token, 1, p - 1)
            return strip(name)
        }
        function val_of(token,    p) {
            p = index(token, "=")
            if (p == 0) p = index(token, ":")
            if (p > 1 && p < length(token)) return strip(substr(token, p + 1))
            return ""
        }
        function field(line, key,    n, i, tok, val) {
            n = split(line, tok, /[[:space:],]+/)
            for (i = 1; i <= n; i++) {
                if (key_of(tok[i]) != key) continue
                val = val_of(tok[i])
                if (val != "") return val
                if (tok[i] ~ /[:=]$/) {
                    if (i < n) return strip(tok[i + 1])
                    return ""
                }
                if (i < n && (tok[i + 1] == "=" || tok[i + 1] == ":")) {
                    if (i + 1 < n) return strip(tok[i + 2])
                    return ""
                }
            }
            return ""
        }
        function pick(line, keys,    k, n, i, v) {
            n = split(keys, k, ",")
            for (i = 1; i <= n; i++) {
                v = field(line, k[i])
                if (v != "") return v
            }
            return ""
        }
        function timestamp_of(line,    t) {
            t = field(line, "timestamp")
            if (t != "") return t
            if (match(line, /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9:.]+Z?/))
                return substr(line, RSTART, RLENGTH)
            return ""
        }
        {
            ts = timestamp_of($0)
            handle = pick($0, "handle,topologyHandle")
            host = pick($0, "host,hostName,hostname")
            site = pick($0, "site,siteId,siteName")
            node = pick($0, "nodeId,nodeID,node")
            service = pick($0, "serviceId,serviceID,service")
            if (handle == "" && host == "" && site == "" && node == "" && service == "") next
            if (node != "") id = node
            else if (handle != "") id = handle
            else id = host "/" service
            if (!(id in seen)) {
                order[++n] = id
                seen[id] = 1
            }
            # take is true when this line is the newest timestamp so far.
            take = (stamps[id] == "" || (ts != "" && ts >= stamps[id]))
            if (ts != "" && take) stamps[id] = ts
            if (handle != "" && (take || handles[id] == "")) handles[id] = handle
            if (host != "" && (take || hosts[id] == "")) hosts[id] = host
            if (site != "" && (take || sites[id] == "")) sites[id] = site
            if (node != "" && (take || nodes[id] == "")) nodes[id] = node
            if (service != "" && (take || services[id] == "")) services[id] = service
        }
        END {
            if (n == 0) exit
            print "timestamp\thandle\thost\tsite\tnode\tservice"
            for (i = 1; i <= n; i++) {
                id = order[i]
                print stamps[id] "\t" handles[id] "\t" hosts[id] "\t" sites[id] "\t" nodes[id] "\t" services[id]
            }
        }
    ' "$file") || true
    if [[ -z "$table" ]]; then
        echo "(no per-node topology records)"
        return
    fi
    if formatted=$(printf '%s\n' "$table" | column -t -s $'\t' 2>/dev/null); then
        printf '%s\n' "$formatted"
    else
        printf '%s\n' "$table"
    fi
}

section_topology_vcenters() {
    local name="Topology VCenters seen" f out
    local -a files
    SECTIONS_TOTAL=$(( SECTIONS_TOTAL + 1 ))
    if ! have_file "$TOPOLOGY_LOG"; then
        skip_section "$name" "no '$TOPOLOGY_LOG' file found"
        return
    fi
    if ! have_cmds grep sort column uniq; then
        skip_section "$name" "required command not available"
        return
    fi
    print_section "$name"
    mapfile -t files < <(files_for "$TOPOLOGY_LOG")
    for f in "${files[@]}"; do
        out=$(grep url "$f" | grep vcenter | sort | column -t | uniq -c || true)
        if [[ -n "$out" ]]; then
            printf '%s\n' "$out"
        else
            echo "(no vcenter urls)"
        fi
    done
    SECTIONS_RUN=$(( SECTIONS_RUN + 1 ))
}

# 198 url  =  https://vc01.example.com:443/vcenter
# 198 url  =  https://vc02.example.com:443/vcenter

section_topology_vlr() {
    local name="Topology VLR appliances seen" f out
    local -a files
    SECTIONS_TOTAL=$(( SECTIONS_TOTAL + 1 ))
    if ! have_file "$TOPOLOGY_LOG"; then
        skip_section "$name" "no '$TOPOLOGY_LOG' file found"
        return
    fi
    if ! have_cmds grep sort column uniq; then
        skip_section "$name" "required command not available"
        return
    fi
    print_section "$name"
    mapfile -t files < <(files_for "$TOPOLOGY_LOG")
    for f in "${files[@]}"; do
        out=$(grep url "$f" | grep -E " https.*vrms" | sort | column -t | uniq -c || true)
        if [[ -n "$out" ]]; then
            printf '%s\n' "$out"
        else
            echo "(no vrms urls)"
        fi
    done
    SECTIONS_RUN=$(( SECTIONS_RUN + 1 ))
}

# 156 url  =  https://vlr01:443/vrms4
#  42 url  =  https://vlr01.example.com:443/vrms
# 156 url  =  https://vlr02:443/vrms
#  42 url  =  https://vlr02.example.com:443/vrms

section_topology_nodes() {
    local name="Topology nodes" f
    local -a files
    SECTIONS_TOTAL=$(( SECTIONS_TOTAL + 1 ))
    if ! have_file "$TOPOLOGY_LOG"; then
        skip_section "$name" "no '$TOPOLOGY_LOG' file found"
        return
    fi
    if ! have_cmds awk; then
        skip_section "$name" "required command not available"
        return
    fi
    print_section "$name"
    mapfile -t files < <(files_for "$TOPOLOGY_LOG")
    for f in "${files[@]}"; do
        echo "--- ${f#"$BUNDLE_ROOT"/}"
        print_topology_nodes "$f"
    done
    SECTIONS_RUN=$(( SECTIONS_RUN + 1 ))
}

# --- Log file timestamps (shared by the coverage and health sections) ----------
# awk library: ts_of(line) returns the line's leading timestamp as UTC
# "YYYY-MM-DD HH:MM:SS", or "" when the line has none (continuation lines,
# stack frames, "-->" detail lines). Only the first 100 characters are
# searched, which is where the timestamp sits in every VLR log format.
# Zone offsets are ignored (VLR logs in UTC). Recognised formats, first match
# on the line wins:
#   2026-06-11T18:08:55.210Z / 2026-06-06 20:49:28,269   most services, ISO
#   23-Jun-2026 04:18:31.862                             tomcat catalina/localhost
#   Sat Jun 6 07:25:45 PM UTC 2026                       vmware-network, hbrsrv cert
#   Jun 06, 2026 7:25:55 PM                              java/tomcat catalina.out
#   msg=audit(1782662209.651:577814)                     auditd, epoch seconds
#   1780773946 HBRSERVERSTATS ...                        hbrsrv *.stats, epoch at line start
AWK_TS_LIB='
    BEGIN {
        split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", mn, " ")
        for (i = 1; i <= 12; i++) mon[mn[i]] = sprintf("%02d", i)
    }
    # epoch seconds -> "YYYY-MM-DD HH:MM:SS" UTC, without gawk strftime
    function epoch_to_ts(e,    days, secs, z, era, doe, yoe, y, doy, mp, d, m) {
        e = int(e)
        days = int(e / 86400); secs = e - days * 86400
        z = days + 719468
        era = int(z / 146097)
        doe = z - era * 146097
        yoe = int((doe - int(doe / 1460) + int(doe / 36524) - int(doe / 146096)) / 365)
        y = yoe + era * 400
        doy = doe - (365 * yoe + int(yoe / 4) - int(yoe / 100))
        mp = int((5 * doy + 2) / 153)
        d = doy - int((153 * mp + 2) / 5) + 1
        m = (mp < 10) ? mp + 3 : mp - 9
        if (m <= 2) y++
        return sprintf("%04d-%02d-%02d %02d:%02d:%02d", y, m, d,
                       int(secs / 3600), int(secs % 3600 / 60), secs % 60)
    }
    # Only a timestamp that leads the line counts, so dates inside message
    # text (e.g. multi-line "tokenExpirationTime = Tue Jun 30 ..." entries)
    # do not stretch the window. ISO may sit up to column 40 to allow
    # "[2026-..." and JSON {"level":..,"timestamp":"2026-..."} prefixes.
    function ts_of(line,    s, p, np, h, hms) {
        line = substr(line, 1, 100)
        if (match(line, /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][T ][0-9][0-9]:[0-9][0-9]:[0-9][0-9]/) && RSTART <= 40) {
            s = substr(line, RSTART, RLENGTH)
            return substr(s, 1, 10) " " substr(s, 12)
        }
        if (match(line, /^[0-9][0-9]-[A-Z][a-z][a-z]-[0-9][0-9][0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]/)) {
            s = substr(line, RSTART, RLENGTH)
            if (!(substr(s, 4, 3) in mon)) return ""
            return substr(s, 8, 4) "-" mon[substr(s, 4, 3)] "-" substr(s, 1, 2) " " substr(s, 13)
        }
        if (match(line, /^(Mon|Tue|Wed|Thu|Fri|Sat|Sun) [A-Z][a-z][a-z] +[0-9]+ [0-9][0-9]:[0-9][0-9]:[0-9][0-9]( [AP]M)? [A-Z]+ [0-9][0-9][0-9][0-9]/)) {
            np = split(substr(line, RSTART, RLENGTH), p, / +/)
            if (!(p[2] in mon)) return ""
            h = substr(p[4], 1, 2) + 0
            if (p[5] == "PM" && h < 12) h += 12
            if (p[5] == "AM" && h == 12) h = 0
            return p[np] "-" mon[p[2]] "-" sprintf("%02d", p[3]) " " sprintf("%02d", h) substr(p[4], 3)
        }
        if (match(line, /^[A-Z][a-z][a-z] [0-9]+, [0-9][0-9][0-9][0-9] [0-9]+:[0-9][0-9]:[0-9][0-9] [AP]M/)) {
            split(substr(line, RSTART, RLENGTH), p, /[ ,]+/)
            if (!(p[1] in mon)) return ""
            split(p[4], hms, ":")
            h = hms[1] + 0
            if (p[5] == "PM" && h < 12) h += 12
            if (p[5] == "AM" && h == 12) h = 0
            return p[3] "-" mon[p[1]] "-" sprintf("%02d", p[2]) " " sprintf("%02d:%s:%s", h, hms[2], hms[3])
        }
        if (match(line, /^[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9] /))
            return epoch_to_ts(substr(line, 1, 10))
        if (match(line, /audit\([0-9]+\./))
            return epoch_to_ts(substr(line, RSTART + 6, RLENGTH - 7))
        return ""
    }
'

# read_log <file>: print the file, decompressing *.gz through zcat. With
# pipefail, a pipeline reading from this fails when zcat fails.
read_log() {
    if [[ "$1" == *.gz ]]; then
        zcat -- "$1" 2>/dev/null
    else
        cat -- "$1"
    fi
}

# One row per *.log and *.gz file under BUNDLE_ROOT (rotated logs such as
# vmware-dr-1.log.gz, messages.1.gz, envoy.log.1.gz): line count plus the
# earliest and latest timestamp found in it, so you can see the time window
# each log covers. A .gz that fails to decompress part way is still listed,
# with what could be read, and marked "(gzip error)". Binary files that happen
# to be gzipped (lastlog.N.gz) show 0 lines and no dates. Lines are counted as
# awk records, so a last line without a trailing newline counts too.
# A file with no recognised timestamp shows "-" for start and end.
section_log_coverage() {
    local name="Log files: line count and time coverage" prog f rel row rows table
    SECTIONS_TOTAL=$(( SECTIONS_TOTAL + 1 ))
    if ! have_cmds find sort awk; then
        skip_section "$name" "required command not available"
        return
    fi
    list_log_files
    if (( ${#LOG_FILES[@]} == 0 )); then
        skip_section "$name" "no '*.log' or '*.gz' files found under '$BUNDLE_ROOT'${OPT_LOG:+ matching --log '$OPT_LOG'}"
        return
    fi
    print_section "$name"
    # Run once per file; prints one row: lines start end name
    prog="$AWK_TS_LIB"'
        {
            n++
            t = ts_of($0)
            if (t == "") next
            if (first == "" || t < first) first = t
            if (last == "" || t > last) last = t
        }
        END {
            print n + 0 "\t" (first == "" ? "-" : first) "\t" (last == "" ? "-" : last) "\t" name
        }
    '
    rows=$(
        for f in "${LOG_FILES[@]}"; do
            rel="${f#"$BUNDLE_ROOT"/}"
            if ! row=$(read_log "$f" | awk -v name="$rel" "$prog"); then
                warn "could not fully decompress: $f"
                row="$row (gzip error)"
            fi
            printf '%s\n' "$row"
        done
    )
    table=$(printf '%s\n' "$rows" | awk -F '\t' '
        {
            print
            total += $1; files++
            if ($2 != "-" && (all_s == "" || $2 < all_s)) all_s = $2
            if ($3 != "-" && (all_e == "" || $3 > all_e)) all_e = $3
        }
        END {
            print total + 0 "\t" (all_s == "" ? "-" : all_s) "\t" (all_e == "" ? "-" : all_e) "\tTOTAL (" files + 0 " files)"
        }
    ')
    print_tsv $'lines\tstart\tend\tfile' "$table"
    SECTIONS_RUN=$(( SECTIONS_RUN + 1 ))
}

# --- Log health ------------------------------------------------------------------
# Per log and per day: how many events, errors, warnings, fatals and stack
# traces, the error rate, and a status, so a support engineer can see which
# log went bad on which day before opening any file.
#
# Terms:
#   log       a log family: rotations are merged, so vmware-dr.log,
#             vmware-dr-3.log.gz, hms.0000078.log.gz -> hms.log,
#             catalina.2026-06-11.log -> catalina.log, messages.3.gz -> messages
#   event     a line that starts with a timestamp. Lines without one (stack
#             frames, "-->" fault details) belong to the event above them.
#   level     the first level word in the first 120 characters of the event:
#               FATAL  FATAL CRITICAL PANIC, postgres "FATAL:"
#               ERROR  ERROR error SEVERE, JSON "level":"error"
#               WARN   WARN WARNING warning
#             syslog lines (messages, cron) carry no level and count as events only.
#   trace     one stack trace: a run of Java "\tat ...(" frames (a "Caused by:"
#             block continues the same trace), a vmacore "Backtrace:", a Go
#             "panic:" (also counted as FATAL) or a Python "Traceback".
#   err/1k    ERROR + FATAL events per 1000 events.
#   status    OK    no ERROR or FATAL
#             LOW   err/1k below 1
#             WARN  err/1k from 1 up to 10
#             CRIT  err/1k 10 or more, or any FATAL
#   SPIKE     a day with 10+ errors and at least 3x the median daily errors
#             of that log (median over the days the log has).
#   health%   share of a log's days that are OK or LOW.
#
# Duplicate files of the same log (same checksum, e.g. vmware-dr.log and
# vmware-dr-7.log in the same bundle) are read once. --from/--to drop lines
# outside the range, and lines before a file's first timestamp ("undated").
# --log limits the files.

# log_family <path>: sets LOG_FAMILY to the log name with the rotation removed
log_family() {
    local p="${1%.gz}"
    [[ "$p" =~ ^(.*)\.[0-9]+$ ]] && p="${BASH_REMATCH[1]}"                              # envoy.log.1, messages.1
    [[ "$p" =~ ^(.*)\.[0-9]{4}-[0-9]{2}-[0-9]{2}\.log$ ]] && p="${BASH_REMATCH[1]}.log" # catalina.2026-06-11.log
    [[ "$p" =~ ^(.*)\.[0-9]+\.log$ ]] && p="${BASH_REMATCH[1]}.log"                     # hms.0000079.log
    [[ "$p" =~ ^(.*)-[0-9]+\.log$ ]] && p="${BASH_REMATCH[1]}.log"                      # vmware-dr-7.log
    LOG_FAMILY="$p"
}

# Per file (-v fam=<log family>): prints tab separated records for aggregation
#   D log day lines events errors warnings fatals traces
#   S log level count first_day last_day signature
#   X log kind parent_level count first_day last_day exception
HEALTH_FILE_AWK='
    # level letter F/E/W/I of the first level word, or "" if none.
    # Sets LVL_END to the column after the level word.
    function level_of(h,    t) {
        if (!match(h, /(^|[ \[":|])(trace|TRACE|debug|DEBUG|verbose|VERBOSE|info|INFO|Info|warn|WARN|Warn|warning|WARNING|Warning|error|ERROR|Error|severe|SEVERE|fatal|FATAL|critical|CRITICAL|panic|PANIC)([ \]":|]|$)/))
            return ""
        LVL_END = RSTART + RLENGTH
        t = toupper(substr(h, RSTART, RLENGTH))
        gsub(/[^A-Z]/, "", t)
        if (t == "FATAL" || t == "CRITICAL" || t == "PANIC") return "F"
        if (t == "ERROR" || t == "SEVERE") return "E"
        if (t == "WARN" || t == "WARNING") return "W"
        return "I"
    }
    # message with the variable parts replaced, so repeats group together
    function sig_of(s) {
        s = substr(s, 1, 400)
        gsub(/[\t]/, " ", s)
        gsub(/(opID|ctxID|connID|operationID|sessionId|session|requestId)=[^] ,})]*/, "", s)
        gsub(/[0-9a-fA-F]+-[0-9a-fA-F]+-[0-9a-fA-F]+-[0-9a-fA-F]+-[0-9a-fA-F]+/, "<id>", s)
        gsub(/0x[0-9a-fA-F]+/, "<hex>", s)
        gsub(/\[[0-9a-fA-F]+\]/, "[<id>]", s)                       # [3f7] request ids
        gsub(/[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]+/, "<id>", s)  # long lowercase hex ids
        gsub(/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(:[0-9]+)?/, "<ip>", s)
        gsub(/[0-9]+/, "N", s)
        gsub(/  +/, " ", s)
        sub(/^[ :|\]-]+/, "", s)
        return substr(s, 1, 150)
    }
    # cheap pre-check: exc_of() runs regexes, so only call it on lines that can match
    function maybe_exc(l) { return index(l, "Exception") || index(l, "Error") || index(l, "ault") || index(l, "Throwable") || index(l, "Caused by") }
    # exception class named on the line, or "" if none
    function exc_of(l) {
        if (l ~ /java\.lang\.Exception: stack info/) return "java.lang.Exception: stack info (debug trace)"
        if (sub(/^Caused by: /, "", l) && match(l, /^[A-Za-z_$][A-Za-z0-9_$.]*/))
            return substr(l, RSTART, RLENGTH)
        if (match(l, /([a-z][A-Za-z0-9_$]*\.)+[A-Z][A-Za-z0-9_$]*(Exception|Error|Throwable|Fault)[A-Za-z0-9_$]*/))
            return substr(l, RSTART, RLENGTH)
        if (match(l, /([a-z][A-Za-z0-9_$]*\.)+fault\.[A-Z][A-Za-z0-9_$]*/))
            return substr(l, RSTART, RLENGTH)
        return ""
    }
    function note(kind, e,    k) {
        k = kind SUBSEP lvl SUBSEP e
        xc[k]++
        if (!(k in xf) || day < xf[k]) xf[k] = day
        if (!(k in xl) || day > xl[k]) xl[k] = day
    }
    BEGIN { OFS = "\t"; day = "undated"; lvl = "-"; ranged = (from != "" || to != "") }
    {
        t = ts_of($0)
        if (t != "") day = substr(t, 1, 10)
        if (ranged && (day == "undated" || (from != "" && day < from) || (to != "" && day > to))) {
            prev = $0; in_at = 0; next
        }
        lines[day]++
        if (t != "") {
            events[day]++
            lvl = level_of(substr($0, 1, 120))
            if (lvl == "") lvl = "-"
            last_exc = maybe_exc($0) ? exc_of($0) : ""
            if (lvl == "F" || lvl == "E" || lvl == "W") {
                if (lvl == "F") fatal[day]++
                else if (lvl == "E") err[day]++
                else warn[day]++
                k = lvl SUBSEP sig_of(substr($0, LVL_END))
                sc[k]++
                if (!(k in sf) || day < sf[k]) sf[k] = day
                if (!(k in sl) || day > sl[k]) sl[k] = day
                if (lvl != "W" && match($0, /\(([a-z]+\.)+fault\.[A-Za-z]+\)/)) note("fault", substr($0, RSTART + 1, RLENGTH - 2))
            }
            in_at = 0; prev = $0; next
        }
        # The exception class is usually on the line above the first frame, but
        # multi-line messages can push it further up, so use the last class
        # named since the event started.
        if ($0 ~ /^[ \t]+at [A-Za-z_$][^ (]*\(/) {
            if (!in_at && prev !~ /^(Caused by:|[ \t]+Suppressed:)/)
                { traces[day]++; note("trace", last_exc != "" ? last_exc : "(no exception class found)") }
            in_at = 1
        } else {
            in_at = 0
            e = maybe_exc($0) ? exc_of($0) : ""
            if (e != "") last_exc = e
            if ($0 ~ /^Caused by: /) note("cause", e != "" ? e : "(no exception class found)")
            else if ($0 ~ /Backtrace:/) { traces[day]++; note("trace", "(vmacore backtrace)") }
            else if ($0 ~ /^panic: /) { traces[day]++; fatal[day]++; note("trace", "(go panic)") }
            else if ($0 ~ /^Traceback \(most recent call last\)/) { traces[day]++; note("trace", "(python traceback)") }
            else if ((lvl == "E" || lvl == "F") && match($0, /\(([a-z]+\.)+fault\.[A-Za-z]+\)/)) note("fault", substr($0, RSTART + 1, RLENGTH - 2))
        }
        prev = $0
    }
    END {
        for (d in lines) print "D", fam, d, lines[d], events[d] + 0, err[d] + 0, warn[d] + 0, fatal[d] + 0, traces[d] + 0
        for (k in sc) { split(k, a, SUBSEP); print "S", fam, a[1], sc[k], sf[k], sl[k], a[2] }
        for (k in xc) { split(k, a, SUBSEP); print "X", fam, a[1], a[2], xc[k], xf[k], xl[k], a[3] }
    }
'

# Aggregates the D/S/X records of all files. -v mode= picks the table:
#   timeline  day lines events err warn fatal traces err/1k crit_logs status bar
#   logs      log days events err warn fatal traces err/1k worst_day ok low warn crit health%
#   logdays   log day lines events err warn fatal traces err/1k status note
#   sigs      count level log first last signature   (-v levels="EF" or "W")
#   exc       count kind level log first last exception
# Rows come out unsorted; the caller sorts them.
HEALTH_AGG_AWK='
    function status(ev, e, f,    r) {
        if (f > 0) return "CRIT"
        if (e == 0) return "OK"
        r = ev ? e * 1000 / ev : 1000
        if (r >= 10) return "CRIT"
        if (r >= 1) return "WARN"
        return "LOW"
    }
    function rate(ev, e) { return ev ? sprintf("%.2f", e * 1000 / ev) : "-" }
    function lvname(l) { return l == "F" ? "FATAL" : l == "E" ? "ERROR" : l == "W" ? "WARN" : l == "I" ? "INFO" : "none" }
    function median(f,    n, i, j, v, a, k, kk) {
        n = 0
        for (k in L) { split(k, kk, SUBSEP); if (kk[1] == f) a[++n] = ER[k] + FA[k] }
        for (i = 2; i <= n; i++) { v = a[i]; for (j = i - 1; j >= 1 && a[j] > v; j--) a[j + 1] = a[j]; a[j + 1] = v }
        if (n == 0) return 0
        return (n % 2) ? a[(n + 1) / 2] : (a[n / 2] + a[n / 2 + 1]) / 2
    }
    BEGIN { FS = OFS = "\t" }
    $1 == "D" {
        k = $2 SUBSEP $3
        L[k] += $4; EV[k] += $5; ER[k] += $6; WA[k] += $7; FA[k] += $8; TR[k] += $9
        next
    }
    $1 == "S" {
        k = $2 SUBSEP $3 SUBSEP $7
        SC[k] += $4
        if (!(k in SF) || $5 < SF[k]) SF[k] = $5
        if (!(k in SL) || $6 > SL[k]) SL[k] = $6
        next
    }
    $1 == "X" {
        k = $2 SUBSEP $3 SUBSEP $4 SUBSEP $8
        XC[k] += $5
        if (!(k in XF) || $6 < XF[k]) XF[k] = $6
        if (!(k in XL) || $7 > XL[k]) XL[k] = $7
        next
    }
    END {
        if (mode == "timeline") {
            for (k in L) {
                split(k, kk, SUBSEP); d = kk[2]
                dl[d] += L[k]; dev[d] += EV[k]; der[d] += ER[k]; dwa[d] += WA[k]; dfa[d] += FA[k]; dtr[d] += TR[k]
                if (status(EV[k], ER[k] + FA[k], FA[k]) == "CRIT") dcrit[d]++
            }
            for (d in dl) if (der[d] + dfa[d] > max) max = der[d] + dfa[d]
            for (d in dl) {
                e = der[d] + dfa[d]
                bar = ""
                n = (max > 0 && e > 0) ? int(30 * e / max + 0.999) : 0
                for (i = 0; i < n; i++) bar = bar "#"
                print d, dl[d], dev[d], der[d], dwa[d], dfa[d], dtr[d], rate(dev[d], e), dcrit[d] + 0, status(dev[d], e, dfa[d]), (bar == "" ? "." : bar)
            }
        } else if (mode == "logs") {
            for (k in L) {
                split(k, kk, SUBSEP); f = kk[1]; d = kk[2]
                fd[f]++; fev[f] += EV[k]; fer[f] += ER[k]; fwa[f] += WA[k]; ffa[f] += FA[k]; ftr[f] += TR[k]
                e = ER[k] + FA[k]
                if (!(f in worst) || e > worste[f] || (e == worste[f] && d > worst[f])) { worst[f] = d; worste[f] = e }
                st = status(EV[k], e, FA[k])
                cnt[f, st]++
            }
            for (f in fd) {
                print f, fd[f], fev[f], fer[f], fwa[f], ffa[f], ftr[f], rate(fev[f], fer[f] + ffa[f]),
                      (worste[f] > 0 ? worst[f] " (" worste[f] ")" : "-"),
                      cnt[f, "OK"] + 0, cnt[f, "LOW"] + 0, cnt[f, "WARN"] + 0, cnt[f, "CRIT"] + 0,
                      sprintf("%d%%", 100 * (cnt[f, "OK"] + cnt[f, "LOW"]) / fd[f])
            }
        } else if (mode == "logdays") {
            for (k in L) { split(k, kk, SUBSEP); if (!(kk[1] in med)) med[kk[1]] = median(kk[1]) }
            for (k in L) {
                split(k, kk, SUBSEP); f = kk[1]; d = kk[2]
                e = ER[k] + FA[k]
                st = status(EV[k], e, FA[k])
                note = (e >= 10 && e >= 3 * med[f]) ? sprintf("SPIKE (median %g/day)", med[f]) : ""
                if (!all && (st == "OK" || st == "LOW") && note == "") continue
                print f, d, L[k], EV[k], ER[k], WA[k], FA[k], TR[k], rate(EV[k], e), st, note
            }
        } else if (mode == "sigs") {
            for (k in SC) {
                split(k, kk, SUBSEP)
                if (index(levels, kk[2])) print SC[k], lvname(kk[2]), kk[1], SF[k], SL[k], kk[3]
            }
        } else if (mode == "exc") {
            for (k in XC) {
                split(k, kk, SUBSEP)
                print XC[k], kk[2], lvname(kk[3]), kk[1], XF[k], XL[k], kk[4]
            }
        }
    }
'

section_log_health() {
    local name="Log health per day" f rel sum raw rows LOG_FAMILY
    local -a dups=()
    local -A seen=()
    SECTIONS_TOTAL=$(( SECTIONS_TOTAL + 1 ))
    if ! have_cmds find sort awk; then
        skip_section "$name" "required command not available"
        return
    fi
    list_log_files
    if (( ${#LOG_FILES[@]} == 0 )); then
        skip_section "$name" "no '*.log' or '*.gz' files found under '$BUNDLE_ROOT'${OPT_LOG:+ matching --log '$OPT_LOG'}"
        return
    fi
    print_section "$name"
    echo "Range: ${OPT_FROM:-first day} .. ${OPT_TO:-last day}${OPT_LOG:+, logs matching '$OPT_LOG'}"
    raw=$(
        for f in "${LOG_FILES[@]}"; do
            rel="${f#"$BUNDLE_ROOT"/}"
            log_family "$rel"
            if have_cmds cksum; then
                sum="$LOG_FAMILY $(cksum < "$f" 2>/dev/null)"
                if [[ -n "${seen[$sum]:-}" ]]; then
                    printf 'DUP\t%s\t%s\n' "$rel" "${seen[$sum]}"
                    continue
                fi
                seen[$sum]="$rel"
            fi
            read_log "$f" | awk -v fam="$LOG_FAMILY" -v from="$OPT_FROM" -v to="$OPT_TO" "$AWK_TS_LIB$HEALTH_FILE_AWK" \
                || warn "could not fully read: $f (health counts use what was read)"
        done
    )
    mapfile -t dups < <(printf '%s\n' "$raw" | awk -F '\t' '$1 == "DUP" { print "  " $2 "  (same as " $3 ")" }')
    if (( ${#dups[@]} > 0 )); then
        echo "Skipped ${#dups[@]} duplicate file(s), same content as a file already counted:"
        printf '%s\n' "${dups[@]}"
    fi
    # here-string, not a pipe: grep -q exiting early would trip pipefail
    if ! grep -q '^D' <<< "$raw"; then
        echo "(no log lines in range)"
        SECTIONS_RUN=$(( SECTIONS_RUN + 1 ))
        return
    fi

    echo ""
    echo "--- Appliance timeline (all logs per day; bar = ERROR+FATAL events)"
    rows=$(printf '%s\n' "$raw" | awk -v mode=timeline "$HEALTH_AGG_AWK" | sort -t $'\t' -k1,1)
    print_tsv $'day\tlines\tevents\terror\twarn\tfatal\ttraces\terr/1k\tcrit_logs\tstatus\terrors' "$rows"

    echo ""
    echo "--- Per log summary (most errors first)"
    rows=$(printf '%s\n' "$raw" | awk -v mode=logs "$HEALTH_AGG_AWK" | sort -t $'\t' -k4,4nr -k6,6nr -k1,1)
    print_tsv $'log\tdays\tevents\terror\twarn\tfatal\ttraces\terr/1k\tworst_day\tok\tlow\twarn\tcrit\thealth%' "$rows"

    echo ""
    if (( OPT_ALL_DAYS )); then
        echo "--- Per log per day (all days)"
    else
        echo "--- Per log per day: WARN/CRIT days and error spikes (-a for all days)"
    fi
    rows=$(printf '%s\n' "$raw" | awk -v mode=logdays -v all="$OPT_ALL_DAYS" "$HEALTH_AGG_AWK" | sort -t $'\t' -k1,1 -k2,2)
    if [[ -n "$rows" ]]; then
        print_tsv $'log\tday\tlines\tevents\terror\twarn\tfatal\ttraces\terr/1k\tstatus\tnote' "$rows"
    else
        echo "(none: every log/day is OK or LOW)"
    fi

    echo ""
    echo "--- Top $OPT_TOP ERROR/FATAL signatures (ids, numbers, addresses masked)"
    rows=$(printf '%s\n' "$raw" | awk -v mode=sigs -v levels=EF "$HEALTH_AGG_AWK" | sort -t $'\t' -k1,1nr -k3,3 | head -n "$OPT_TOP")
    if [[ -n "$rows" ]]; then print_tsv $'count\tlevel\tlog\tfirst\tlast\tsignature' "$rows"; else echo "(none)"; fi

    echo ""
    echo "--- Top $OPT_TOP WARN signatures"
    rows=$(printf '%s\n' "$raw" | awk -v mode=sigs -v levels=W "$HEALTH_AGG_AWK" | sort -t $'\t' -k1,1nr -k3,3 | head -n "$OPT_TOP")
    if [[ -n "$rows" ]]; then print_tsv $'count\tlevel\tlog\tfirst\tlast\tsignature' "$rows"; else echo "(none)"; fi

    echo ""
    echo "--- Top $OPT_TOP exceptions, causes and faults (level = level of the event they belong to)"
    rows=$(printf '%s\n' "$raw" | awk -v mode=exc "$HEALTH_AGG_AWK" | sort -t $'\t' -k1,1nr -k4,4 | head -n "$OPT_TOP")
    if [[ -n "$rows" ]]; then print_tsv $'count\tkind\tlevel\tlog\tfirst\tlast\texception' "$rows"; else echo "(none)"; fi

    SECTIONS_RUN=$(( SECTIONS_RUN + 1 ))
}


# --- Appliance workflows ----------------------------------------------------------
# Task attempts and outcomes for the three appliance work phases, from every
# rotation of the source logs (*.log and *.gz, duplicate files read once):
#
#   Phase 1  register VLR with vCenter
#            va-config: VAMI configure/reconfigure tasks. A task is all events
#            with the same opID; it ends with "--> <Name> task succeeded|failed".
#            Also counts the Lookup Service registrations the task created and
#            the vCenter it talked to. Polling tasks ("Check Reconfigure",
#            "Reading current configuration") are left out.
#   Phase 2  site pairing
#            dr-client: UI tasks whose operation name contains "pair"
#            (pairServices), "Created new task" -> "completed successfully" or
#            "completed with error" + the fault on the following lines.
#            HMS: PairHmsTask / RepairHmsTask started/finished events.
#   Phase 3  create replication for a VM
#            dr-client: configureReplications UI tasks.
#            HMS: "Configure replication" (this site is the source) and
#            "Configure Replication Secondary" (this site is the target)
#            tasks, with the VM name and moref from the replication spec.
#   All      audited API calls ([Success]/[Failure] Method:...) from the
#            va-config, aps-service and vmware-dr audit logs.
#
# A task with a start but no end in the logs is "no result" (still running when
# the bundle was taken, or its end rotated out). --from/--to filter on the day
# the task started.

# pick_logs <family>...: set PICKED to every *.log/*.gz under BUNDLE_ROOT whose
# log family (see log_family) is one of the given paths ("*" = every log), sorted, duplicates of
# the same family (same checksum) dropped. --log does not apply here.
PICKED=()
pick_logs() {
    local f rel sum want=" $* "
    local -a all
    local -A seen=()
    PICKED=()
    if have_cmds zcat; then
        mapfile -d '' -t all < <(find "$BUNDLE_ROOT" -type f \( -name '*.log' -o -name '*.gz' \) -print0 2>/dev/null | sort -z)
    else
        mapfile -d '' -t all < <(find "$BUNDLE_ROOT" -type f -name '*.log' -print0 2>/dev/null | sort -z)
    fi
    for f in "${all[@]}"; do
        rel="${f#"$BUNDLE_ROOT"/}"
        log_family "$rel"
        [[ "$want" == " * " || "$want" == *" $LOG_FAMILY "* ]] || continue
        if have_cmds cksum; then
            sum="$LOG_FAMILY $(cksum < "$f" 2>/dev/null)"
            [[ -n "${seen[$sum]:-}" ]] && continue
            seen[$sum]=1
        fi
        PICKED+=("$f")
    done
}

# cat_logs <file>...: all files decompressed, in the given order
cat_logs() {
    local f
    for f in "$@"; do
        read_log "$f" || warn "could not fully read: $f"
    done
}

# Every parser prints task records, tab separated:
#   T phase source task id start end result detail error
# and the audit parser prints:
#   A phase method result day count first last

# va-config (vmacore format). Events carry "opID=<uuid>-<method>]".
WF_VACONFIG_AWK='
    BEGIN { OFS = "\t" }
    /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T/ {
        t = substr($1, 1, 10) " " substr($1, 12, 8)
        op = ""
        if (match($0, /opID=[^] ]+/)) op = substr($0, RSTART + 5, RLENGTH - 5)
        if (op != "" && !(op in first)) first[op] = t
        if (op != "" && !(op in vc) && match($0, /\x27[A-Za-z0-9.-]+\.[A-Za-z]+:443\x27/))
            vc[op] = substr($0, RSTART + 1, RLENGTH - 6)
        if (op != "" && $0 ~ /Create LS registration for service .* done/) ls[op]++
        if (op != "" && $0 ~ /LS registration/ && $0 ~ /[Ff]ail/) lsf[op]++
        last_t = t; last_op = op; want_err = ""
        next
    }
    want_err != "" && /^-->/ {
        s = $0; sub(/^--> */, "", s)
        if (s != "" && s !~ /^[{}(),]*$/) { err[want_err] = substr(s, 1, 160); want_err = "" }
        next
    }
    /^--> .* task (succeeded|failed)\./ {
        if (last_op == "") next
        s = $0; sub(/^--> /, "", s)
        name = s; sub(/ task (succeeded|failed)\..*/, "", name)
        if (name ~ /^(Check Reconfigure|Reading current configuration)$/) next
        res = (s ~ / task succeeded\./) ? "succeeded" : "failed"
        dur = ""
        if (match(s, /\([0-9]+ sec\)/)) dur = substr(s, RSTART + 1, RLENGTH - 2)
        n++; tname[n] = name; tid[n] = last_op; tres[n] = res; tend[n] = last_t; tdur[n] = dur
        if (res == "failed") want_err = last_op
    }
    END {
        for (i = 1; i <= n; i++) {
            op = tid[i]
            detail = "vCenter " (op in vc ? vc[op] : "?") "; LS registrations " ls[op] + 0 (lsf[op] ? ", " lsf[op] " failed" : "") (tdur[i] != "" ? "; " tdur[i] : "")
            print "T", 1, "va-config (VAMI)", tname[i], op, first[op], tend[i], tres[i], detail, err[op]
        }
    }
'

# dr-client (java). TasksFacade lines:
#   ... TasksFacade <session> <request> <operation> - Created new task 'MoRef ..., value = <task>, ...'.
#   ... TasksFacade <session> <request> <operation> - Task 'MoRef ..., value = <task>, ...' completed successfully.
# Background tasks have no operation name and are not counted.
WF_DRCLIENT_AWK='
    BEGIN { OFS = "\t" }
    /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] / {
        want_err = ""
        p = index($0, "TasksFacade ")
        if (!p) next
        t = substr($0, 1, 19)
        s = substr($0, p + 12)
        q = index(s, " - ")
        if (!q) next
        head = substr(s, 1, q - 1); body = substr(s, q + 3)
        gsub(/^ +| +$/, "", head)
        nh = split(head, h, / +/)
        opname = (nh >= 3) ? h[3] : ""
        if (!match(body, /value = [0-9a-f-]+/)) next
        id = substr(body, RSTART + 8, RLENGTH - 8)
        if (body ~ /^Created new task/) {
            if (opname == "") next
            if (!(id in op)) { order[++n] = id }
            op[id] = opname; start[id] = t
        } else if ((id in op) && match(body, /completed [a-z ]+/)) {
            r = substr(body, RSTART + 10, RLENGTH - 10)
            res[id] = (r == "successfully") ? "succeeded" : (r ~ /error/ ? "failed" : r)
            end[id] = t
            if (res[id] == "failed") want_err = id
        }
        next
    }
    want_err != "" {
        if (match($0, /^\([A-Za-z0-9_.]+\)/)) { err[want_err] = substr($0, 2, RLENGTH - 2); want_err = "" }
        else if (match($0, /^([a-z][A-Za-z0-9_$]*\.)+[A-Z][A-Za-z0-9_$]*(Exception|Fault|Error)[A-Za-z0-9_$]*(: .*)?/)) { err[want_err] = substr($0, 1, 160); want_err = "" }
    }
    END {
        for (i = 1; i <= n; i++) {
            id = order[i]; o = op[id]
            if (o ~ /[Pp]air/) ph = 2
            else if (o ~ /^configureReplication/) ph = 3
            else continue
            print "T", ph, "dr-client (UI task)", o, id, start[id], (id in end ? end[id] : "-"), (id in res ? res[id] : "no result"), "", err[id]
        }
    }
'

# HMS (java). Input is pre-filtered to task lines and replication spec lines.
#   handleHmsTaskStartedEvent[id: HTID-..; taskName: ..; ...; taskTypeId: ..; ...]
#   handleHmsTaskFinishedEvent[id: ..; taskName: ..; ...; error: <text|null>; success: true|false; result: ...]
WF_HMS_AWK='
    BEGIN { OFS = "\t" }
    function field(s, k,    p, v) {
        p = index(s, k ": ")
        if (!p) return ""
        v = substr(s, p + length(k) + 2)
        sub(/;.*/, "", v)
        return v
    }
    function phase_of(name, type) {
        if (type ~ /^(Pair|Repair|Unpair)HmsTask$/ || name ~ /^(Pair|Repair|Unpair)$/) return 2
        if (name ~ /^Configure [Rr]eplication/ || type == "ConfigureReplicationTask") return 3
        return 0
    }
    /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] / {
        t = substr($0, 1, 19)
        armed = ""
        if (match($0, /handleHmsTask(Started|Finished)Event\[.*/)) {
            s = substr($0, RSTART)
            id = field(s, "id"); name = field(s, "taskName"); type = field(s, "taskTypeId")
            ph = phase_of(name, type)
            if (!ph) next
            if (!(id in tph)) { order[++n] = id; tph[id] = ph; tname[id] = name (type != "" && type != "null" ? " (" type ")" : "") }
            if (s ~ /^handleHmsTaskStartedEvent/) { start[id] = t; next }
            end[id] = t
            if (match(s, /; success: (true|false)/)) res[id] = (substr(s, RSTART + 11, RLENGTH - 11) == "true") ? "succeeded" : "failed"
            p = index(s, "; error: "); q = index(s, "; success: ")
            if (p && q > p) { e = substr(s, p + 9, q - p - 9); if (e != "null") err[id] = substr(e, 1, 200) }
            if (match(s, /value = (GID|HMSSRV)-[^,]+/)) obj[id] = substr(s, RSTART + 8, RLENGTH - 8)
            next
        }
        if (match($0, /\[task=HTID-[^]]+\]/) && $0 ~ /(with spec|ReplicationSpec|Creating replication group)/)
            armed = substr($0, RSTART + 6, RLENGTH - 7)
        next
    }
    armed != "" && !(armed in vmname) && match($0, /^ +name = [^,]+/) { s = substr($0, RSTART, RLENGTH); sub(/^ +name = /, "", s); vmname[armed] = s }
    armed != "" && !(armed in vmid) && match($0, /type = VirtualMachine, value = [^,]+/) { vmid[armed] = substr($0, RSTART + 31, RLENGTH - 31) }
    END {
        for (i = 1; i <= n; i++) {
            id = order[i]
            if (tph[id] == 3) detail = "VM " (id in vmname ? vmname[id] : "?") " (" (id in vmid ? vmid[id] : "?") ")" (id in obj ? "; " obj[id] : "")
            else detail = (id in obj ? "remote " obj[id] : "")
            print "T", tph[id], "HMS task", tname[id], id, (id in start ? start[id] : "-"), (id in end ? end[id] : "-"), (id in res ? res[id] : "no result"), detail, err[id]
        }
    }
'

# vmacore audit logs: "... [Success] User:..., Method:<name>, From:..." (or [Failure])
WF_AUDIT_AWK='
    BEGIN { OFS = "\t" }
    match($0, /\[(Success|Failure)\]/) {
        r = substr($0, RSTART + 1, RLENGTH - 2)
        if (!match($0, /Method:[A-Za-z0-9_.]+/)) next
        m = substr($0, RSTART + 7, RLENGTH - 7)
        if (m ~ /^drConfig\.ConfigurationManager\.(configure|reconfigure|unconfigure|checkRegistration|validateConnection|findConflicts)$/) ph = 1
        else if ((m ~ /^aps\.site\.SiteManager\./ && m !~ /\.retrieveLocalSite$/) || (m ~ /[Pp]air/ && m !~ /getRunning/)) ph = 2
        else if (m ~ /[Rr]eplication/ && m ~ /[Cc]onfigure/) ph = 3
        else next
        d = substr($0, 1, 10)
        if (from != "" && d < from) next
        if (to != "" && d > to) next
        k = ph SUBSEP m SUBSEP r
        c[k]++
        if (!(k in f) || d < f[k]) f[k] = d
        if (!(k in l) || d > l[k]) l[k] = d
    }
    END { for (k in c) { split(k, a, SUBSEP); print "A", a[1], a[2], a[3], c[k], f[k], l[k] } }
'

# Aggregation: -v phase=N -v mode=summary|tasks|failed|audit
WF_AGG_AWK='
    BEGIN { FS = OFS = "\t" }
    $1 == "T" && $2 == phase {
        d = substr($6 != "-" ? $6 : $7, 1, 10)
        if (from != "" && d < from) next
        if (to != "" && d > to) next
        if (mode == "summary") {
            k = $3 SUBSEP $4
            att[k]++
            if ($8 == "succeeded") ok[k]++
            else if ($8 == "failed") bad[k]++
            else none[k]++
            ts = ($6 != "-" ? $6 : $7)
            if (!(k in fi) || ts < fi[k]) fi[k] = ts
            if (!(k in la) || ts > la[k]) la[k] = ts
        } else if (mode == "tasks" || (mode == "failed" && $8 != "succeeded")) {
            print $6, $7, $3, $4, $8, $9, $10
        }
        next
    }
    $1 == "A" && $2 == phase && mode == "audit" {
        k = $3
        if ($4 == "Success") s[k] += $5; else fl[k] += $5
        if (!(k in af) || $6 < af[k]) af[k] = $6
        if (!(k in al) || $7 > al[k]) al[k] = $7
        m[k] = 1
    }
    END {
        if (mode == "summary")
            for (k in att) { split(k, a, SUBSEP); print a[1], a[2], att[k], ok[k] + 0, bad[k] + 0, none[k] + 0, fi[k], la[k] }
        if (mode == "audit")
            for (k in m) print k, s[k] + 0, fl[k] + 0, af[k], al[k]
    }
'

# print_phase <number> <title> <records>
print_phase() {
    local ph="$1" title="$2" recs="$3" rows ntasks
    echo ""
    echo "--- Phase $ph: $title"
    rows=$(printf '%s\n' "$recs" | awk -v phase="$ph" -v mode=summary -v from="$OPT_FROM" -v to="$OPT_TO" "$WF_AGG_AWK" | sort -t $'\t' -k1,1 -k2,2)
    if [[ -z "$rows" ]]; then
        echo "(no $title tasks found in the logs${OPT_FROM:+ from $OPT_FROM}${OPT_TO:+ to $OPT_TO})"
    else
        print_tsv $'source\ttask\tattempts\tsucceeded\tfailed\tno_result\tfirst\tlast' "$rows"
        rows=$(printf '%s\n' "$recs" | awk -v phase="$ph" -v mode=tasks -v from="$OPT_FROM" -v to="$OPT_TO" "$WF_AGG_AWK" | sort -t $'\t' -k1,1 -k2,2)
        ntasks=$(printf '%s\n' "$rows" | grep -c .)
        echo ""
        if (( ntasks > 100 && ! OPT_ALL_DAYS )); then
            echo "Tasks that did not succeed ($ntasks tasks in total; -a lists all):"
            rows=$(printf '%s\n' "$recs" | awk -v phase="$ph" -v mode=failed -v from="$OPT_FROM" -v to="$OPT_TO" "$WF_AGG_AWK" | sort -t $'\t' -k1,1 -k2,2)
        else
            echo "Tasks:"
        fi
        if [[ -n "$rows" ]]; then
            print_tsv $'start\tend\tsource\ttask\tresult\tdetail\terror' "$rows"
        else
            echo "(none)"
        fi
    fi
    rows=$(printf '%s\n' "$recs" | awk -v phase="$ph" -v mode=audit "$WF_AGG_AWK" | sort -t $'\t' -k1,1)
    if [[ -n "$rows" ]]; then
        echo ""
        echo "Audited API calls:"
        print_tsv $'method\tsuccess\tfailure\tfirst\tlast' "$rows"
    fi
}

section_workflows() {
    local name="Appliance workflows: vCenter registration, site pairing, replication" recs
    SECTIONS_TOTAL=$(( SECTIONS_TOTAL + 1 ))
    if ! have_cmds find sort awk grep; then
        skip_section "$name" "required command not available"
        return
    fi
    print_section "$name"
    recs=$(
        pick_logs var/log/vmware/va-config/va-config.log
        (( ${#PICKED[@]} )) && cat_logs "${PICKED[@]}" | awk "$WF_VACONFIG_AWK"
        pick_logs var/log/vmware/dr-client/dr.log
        (( ${#PICKED[@]} )) && cat_logs "${PICKED[@]}" | awk "$WF_DRCLIENT_AWK"
        pick_logs var/log/vmware/hms/hms.log
        (( ${#PICKED[@]} )) && cat_logs "${PICKED[@]}" \
            | LC_ALL=C grep -E 'handleHmsTask(Started|Finished)Event|\[task=HTID-[^]]*\].*(with spec|ReplicationSpec|Creating replication group)|^ +name = |type = VirtualMachine, value = ' \
            | awk "$WF_HMS_AWK"
        pick_logs var/log/vmware/va-config/va-config-audit.log var/log/vmware/aps/aps-service-audit.log var/log/vmware/srm/vmware-dr-audit.log
        (( ${#PICKED[@]} )) && cat_logs "${PICKED[@]}" | awk -v from="$OPT_FROM" -v to="$OPT_TO" "$WF_AUDIT_AWK"
        true
    )
    echo "Range: ${OPT_FROM:-first day} .. ${OPT_TO:-last day} (by task start day)"
    print_phase 1 "VLR registration with vCenter" "$recs"
    print_phase 2 "site pairing" "$recs"
    print_phase 3 "replication configuration per VM" "$recs"
    SECTIONS_RUN=$(( SECTIONS_RUN + 1 ))
}


# --- Certificates ------------------------------------------------------------------
# Certificate configuration of the appliance and certificate events over time.
#
#   1. Certificates in configuration: every base64 DER ("MII...") or PEM
#      certificate in opt/vmware/etc and etc (svc-config.json vc/dpca
#      certificates and sslTrust lists, the APS ssl-trust-store host/service
#      map, hms-configuration.xml, *.properties). One row per unique
#      certificate: SHA-256 thumbprint, subject, issuer, SAN, validity, days
#      left at bundle time, status; then where each one is used.
#   2. Pinned thumbprints and certificate/TLS settings from the same files,
#      thumbprints matched to the certificates above. Passwords are never shown.
#   3. Certificate events from all logs (rotations included, duplicates read
#      once), grouped by event/target/detail with count and first/last time.
#   4. Certificates that hosts presented when a vmacore SSL probe failed
#      ("PeerCertificate" blocks), decoded: a host showing a different
#      certificate later means its certificate changed.
#   5. Every SHA-1/SHA-256 thumbprint seen in the logs with first/last seen and
#      the configured certificate it belongs to. A thumbprint that first shows
#      up part way through the logs points to a certificate change.
#
# openssl is optional: without it only thumbprints are shown (base64 + sha*sum).
# Bundle time = newest file modification time under var/log (unzip keeps it).

# thumb <algo> : colon separated upper-case hash of the DER on stdin
thumb() {
    "${1}sum" | awk '{ s = toupper($1); out = ""; for (i = 1; i <= length(s); i += 2) out = out (i > 1 ? ":" : "") substr(s, i, 2); print out }'
}

# cert_row <base64 DER> <bundle epoch>: prints
#   sha256 sha1 subject issuer san not_before not_after days_left status
# or nothing when the text is not a certificate
cert_row() {
    local b64="$1" now="$2" der sha256 sha1 info subj iss san nb na end days status
    der=$(printf '%s' "$b64" | base64 -d 2>/dev/null | od -An -v -tx1 | tr -d ' \n') || return
    [[ -n "$der" ]] || return
    sha256=$(printf '%s' "$b64" | base64 -d 2>/dev/null | thumb sha256)
    sha1=$(printf '%s' "$b64" | base64 -d 2>/dev/null | thumb sha1)
    subj="-" iss="-" san="-" nb="-" na="-" days="-" status="-"
    if command -v openssl >/dev/null 2>&1; then
        info=$(printf '%s' "$b64" | base64 -d 2>/dev/null \
            | openssl x509 -inform DER -noout -subject -issuer -startdate -enddate -ext subjectAltName -nameopt RFC2253 2>/dev/null) || return
        subj=$(sed -n 's/^subject=//p' <<< "$info")
        iss=$(sed -n 's/^issuer=//p' <<< "$info")
        nb=$(sed -n 's/^notBefore=//p' <<< "$info")
        na=$(sed -n 's/^notAfter=//p' <<< "$info")
        san=$(awk '/Subject Alternative Name/ { getline; gsub(/^ +| +$/, ""); gsub(/DNS:|IP Address:/, ""); print }' <<< "$info")
        [[ -n "$san" ]] || san="-"
        if end=$(date -u -d "$na" +%s 2>/dev/null); then
            days=$(( (end - now) / 86400 ))
            if (( end < now )); then status="EXPIRED"
            elif (( days < 30 )); then status="EXPIRING"
            else status="OK"
            fi
            nb=$(date -u -d "$nb" '+%Y-%m-%d' 2>/dev/null || echo "$nb")
            na=$(date -u -d "$na" '+%Y-%m-%d' 2>/dev/null || echo "$na")
        fi
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$sha256" "$sha1" "${subj:--}" "${iss:--}" "$san" "$nb" "$na" "$days" "$status"
}

# Config scan. Per file prints
#   C file context base64        certificate
#   P file key thumbprint        pinned thumbprint
#   S file key value             certificate/TLS setting
CERT_CFG_AWK='
    BEGIN { OFS = "\t" }
    function ctx_of(l,    k) {
        if (l ~ /^[ \t]*<Second>MII/) return "trust store: " hc_host " / " hc_svc
        if (match(l, /<[A-Za-z_.-]+>/)) return substr(l, RSTART + 1, RLENGTH - 2)
        if (match(l, /"[A-Za-z_]+"[ \t]*:/)) {
            k = substr(l, RSTART + 1, RLENGTH - 1); sub(/"[ \t]*:$/, "", k)
            return k (ref != "" ? " @ " ref : "")
        }
        if (match(l, /^[ \t]*[A-Za-z0-9_.-]+[ \t]*=/)) { k = substr(l, RSTART, RLENGTH - 1); gsub(/[ \t]/, "", k); return k }
        return lastkey "[]" (ref != "" ? " @ " ref : "")
    }
    FNR == 1 {
        f = FILENAME
        if (index(f, root "/") == 1) f = substr(f, length(root) + 2)
        lastkey = ""; ref = ""; hc_host = ""; hc_svc = ""; inpem = 0
    }
    inpem {
        if ($0 ~ /-----END CERTIFICATE-----/) {
            s = $0; sub(/-----END CERTIFICATE-----.*/, "", s); pem = pem s
            gsub(/[^A-Za-z0-9+\/=]/, "", pem)
            print "C", f, pemctx, pem
            inpem = 0
        } else pem = pem $0
        next
    }
    /-----BEGIN CERTIFICATE-----/ {
        pemctx = ctx_of($0)
        s = $0; sub(/.*-----BEGIN CERTIFICATE-----/, "", s)
        if (s ~ /-----END CERTIFICATE-----/) { sub(/-----END CERTIFICATE-----.*/, "", s); gsub(/[^A-Za-z0-9+\/=]/, "", s); print "C", f, pemctx, s }
        else { pem = s; inpem = 1 }
        next
    }
    {
        if (match($0, /"(url|host|siteName)"[ \t]*:[ \t]*"[^"]*"/)) {
            s = substr($0, RSTART, RLENGTH); sub(/^"[^"]*"[ \t]*:[ \t]*"/, "", s); sub(/"$/, "", s); ref = s
        }
        if (match($0, /<First>[^<]*<\/First>/)) hc_host = substr($0, RSTART + 7, RLENGTH - 15)
        if (match($0, /<Second>[^<M][^<]*<\/Second>/)) hc_svc = substr($0, RSTART + 8, RLENGTH - 17)
        # copy the match out before ctx_of(), whose own match() resets RSTART/RLENGTH
        if (match($0, /MII[A-Za-z0-9+\/=]+/) && RLENGTH > 300) { s = substr($0, RSTART, RLENGTH); print "C", f, ctx_of($0), s }
        if (match($0, /[0-9A-Fa-f][0-9A-Fa-f](:[0-9A-Fa-f][0-9A-Fa-f])+/) && (RLENGTH == 59 || RLENGTH == 95)) {
            s = toupper(substr($0, RSTART, RLENGTH)); print "P", f, ctx_of($0), s
        }
        if ($0 !~ /[Pp]assword|[Ss]ecret/ && match($0, /<[A-Za-z_-]*(trust-mode|legacy-hash|certificate-warning|usessl|enableSsl|ssl-enabled-protocols|ssl-context-protocol|host-certificates|CertRemaining|CertificateChecks)[A-Za-z_-]*>[^<]*</)) {
            s = substr($0, RSTART + 1, RLENGTH - 2); k = s; sub(/>.*/, "", k); sub(/^[^>]*>/, "", s)
            print "S", f, k, s
        }
        if (match($0, /"default_properties"[ \t]*:[ \t]*"[^"]*"/)) { s = substr($0, RSTART, RLENGTH); sub(/^[^:]*:[ \t]*"/, "", s); sub(/"$/, "", s); print "S", f, "default_properties", s }
        if (match($0, /^[ \t]*[A-Za-z0-9_.-]*([Cc]ert-?[Pp]ath|certificatePath|sslTrustStoreFile)[ \t]*=.*/)) { s = $0; k = s; sub(/=.*/, "", k); sub(/^[^=]*=/, "", s); gsub(/[ \t]/, "", k); print "S", f, k, s }
        if (match($0, /"[A-Za-z_]+"[ \t]*:/)) { k = substr($0, RSTART + 1, RLENGTH - 1); sub(/"[ \t]*:$/, "", k); lastkey = k }
    }
'

# Log scan over pre-filtered lines tagged "<log>\t<line>". Prints
#   E ts log event target detail
#   H thumbprint ts log                     every thumbprint occurrence
#   PC ts host base64                       certificate presented in a failed probe
CERT_LOG_AWK='
    BEGIN { OFS = "\t"; FS = "\t" }
    function ev(e, tgt, d) { evt(ts, e, tgt, d) }
    function evt(tm, e, tgt, d) { print "E", tm, lname, e, (tgt == "" ? "-" : tgt), (d == "" ? "-" : substr(d, 1, 160)) }
    # report a failed SSL probe once, with whatever its continuation lines told
    function probe_done(problem) {
        evt(probe_ts, "SSL handshake failed (untrusted)", probe, problem (probe_tp != "" ? (problem != "" ? "; " : "") "peer SHA-1 " probe_tp : ""))
        probe = ""; inpem = 0
    }
    function q1(s,    t) { if (match(s, /\x27[^\x27]+\x27/)) return substr(s, RSTART + 1, RLENGTH - 2); return "" }
    function host_of(l,    v) {
        if (match(l, /https?:\/\/[A-Za-z0-9.-]+/)) { v = substr(l, RSTART, RLENGTH); sub(/^https?:\/\//, "", v); return v }
        if (match(l, /(_lsppHost|[Hh]ost[Nn]ame|hostId|address) = "?[A-Za-z0-9.-]+/)) { v = substr(l, RSTART, RLENGTH); sub(/.* = "?/, "", v); return v }
        if (match(l, /\x27[A-Za-z0-9.-]+\.[A-Za-z]+:[0-9]+\x27/)) return substr(l, RSTART + 1, RLENGTH - 2)
        return ""
    }
    {
        lname = $1; line = substr($0, length($1) + 2)
        t = ts_of(line)
        if ((t != "" || lname != plog) && probe != "") probe_done("")
        if (t != "") { ts = t; plog = lname }
        if (ts == "") next
        if (from != "" && substr(ts, 1, 10) < from) next
        if (to != "" && substr(ts, 1, 10) > to) next

        # host a thumbprint belongs to: on the same line, or on one of the 3
        # lines before it (uri = https://..., _lsppHost = "...", hostId = ...)
        if (lname != hlog) { lasthost = ""; hlog = lname }
        hh = host_of(line)
        if (hh != "") { lasthost = hh; lasthost_nr = NR }
        s = line
        while (match(s, /[0-9A-Fa-f][0-9A-Fa-f](:[0-9A-Fa-f][0-9A-Fa-f])+/)) {
            if (RLENGTH == 59 || RLENGTH == 95) {
                tp = toupper(substr(s, RSTART, RLENGTH))
                th = (probe != "") ? probe : (hh != "") ? hh : (lasthost != "" && NR - lasthost_nr <= 3) ? lasthost : ""
                print "H", tp, ts, lname, th
            }
            s = substr(s, RSTART + RLENGTH)
        }

        # continuation lines of a failed vmacore SSL probe
        if (probe != "" && t == "") {
            if (line ~ /PeerThumbprint: [0-9A-F]/ && !inpem) { p = line; sub(/.*PeerThumbprint: /, "", p); probe_tp = p }
            else if (line ~ /PeerCertificate: -----BEGIN CERTIFICATE-----/) { inpem = 1; pem = "" }
            else if (inpem && line ~ /-----END CERTIFICATE-----/) { inpem = 0; print "PC", probe_ts, probe, pem }
            else if (inpem) { p = line; sub(/^--> */, "", p); pem = pem p }
            else if (line ~ /^--> \* /) { p = line; sub(/^--> \* /, "", p); probe_done(p) }
            next
        }

        if (line ~ /SSL client handshake to \x27[^\x27]*\x27 failed/) { probe = q1(line); probe_ts = ts; probe_tp = ""; next }
        if (line ~ /Generated new certificate|Generating vSphere Replication Server SSL certificate|[Cc]ertificate (was |has been )?(generated|regenerated|installed|replaced|imported)/)
            { p = line; sub(/.*\] */, "", p); ev("certificate generated/installed", "", p); next }
        if (line ~ /Recreating .*certificate/) { ev("service account certificate recreated", q1(line), ""); next }
        if (match(line, /File [^ ]*(cert|crt|pem|jks|p12|bcfks|truststore|keystore)[^ ]* was ENTRY_[A-Z]+/)) {
            p = substr(line, RSTART + 5, RLENGTH - 5); split(p, a, " was ")
            ev("certificate file changed", a[1], a[2]); next
        }
        if (match(line, /\[(Start|Success|Failure)\] .*Method:drConfig\.SslCertificateManager\.[A-Za-z]+/)) {
            p = substr(line, RSTART, RLENGTH); m = p; sub(/.*\./, "", m); r = p; sub(/\].*/, "", r); sub(/^\[/, "", r)
            if (m !~ /^(get|probe|retrieve)/ && r != "Start") ev("certificate change via VAMI (" r ")", "SslCertificateManager." m, "")
            next
        }
        if (match(line, /Processing request to \x27[A-Za-z]*[Cc]ertificate[A-Za-z]*\x27/)) {
            m = q1(substr(line, RSTART)); if (m !~ /^get/) ev("certificate change via UI", m, ""); next
        }
        if (line ~ /CertificateChanged/ && line !~ /registerEventHandler|handlerMap/) {
            m = line; if (match(m, /[A-Za-z]*CertificateChanged[A-Za-z]*/)) m = substr(m, RSTART, RLENGTH)
            ev("certificate change event", m, ""); next
        }
        if (line ~ /ThumbprintMismatch|[Tt]humbprint mismatch|[Tt]humbprint .*does not match/) {
            m = line; if (match(m, /[A-Za-z]+RequestHandler/)) m = substr(m, RSTART, RLENGTH); else m = ""
            ev("thumbprint mismatch", m, ""); next
        }
        if (match(line, /certificate verification failed for remote server .* at [^ ]+/)) {
            p = substr(line, RSTART, RLENGTH); sub(/.* at /, "", p); ev("certificate verification failed", p, ""); next
        }
        if (line ~ /TLS_error:.*(CERTIFICATE_UNKNOWN|BAD_CERTIFICATE|UNKNOWN_CA|CERTIFICATE_EXPIRED)/) {
            p = line; sub(/.*remote address:/, "", p); sub(/:[0-9]+,.*/, "", p)
            r = line; sub(/.*OPENSSL_internal:/, "", r); sub(/:TLS_error_end.*|\|.*/, "", r)
            ev("client rejected appliance certificate", p, r); next
        }
        if (line ~ /PKIX path (building|validation) failed|unable to find valid certification path|SSLHandshakeException/) {
            p = line; sub(/.*(PKIX|unable to find|SSLHandshakeException)/, "&", p); ev("Java TLS trust failure", "", p); next
        }
        if (line ~ /SrmCertificateExpir|[Cc]ertificate (has )?expired|[Cc]ertificate (is )?expiring|will expire/ && line !~ /Event Id:/) {
            p = line; sub(/.*\] */, "", p); ev("certificate expiring/expired", "", p); next
        }
        if (match(line, /Added thumbprint \x27[^\x27]+\x27/)) { ev("new thumbprint trusted", q1(substr(line, RSTART)), ""); next }
    }
    END { if (probe != "") probe_done("") }
'

section_certificates() {
    local name="Certificates: configuration, events and changes" now newest recs rows b64 row key file ctx
    local -A CERT=() TP_LABEL=()
    local -a cfg_files=()
    SECTIONS_TOTAL=$(( SECTIONS_TOTAL + 1 ))
    if ! have_cmds find sort awk grep; then
        skip_section "$name" "required command not available"
        return
    fi
    if ! command -v base64 >/dev/null 2>&1 || ! command -v sha256sum >/dev/null 2>&1; then
        skip_section "$name" "base64/sha256sum not available"
        return
    fi
    print_section "$name"
    newest=$(find "$BUNDLE_ROOT/var/log" -type f -printf '%T@\n' 2>/dev/null | sort -n | tail -1)
    now=${newest%.*}
    [[ -n "$now" ]] || now=$(date -u +%s)
    echo "Bundle time: $(date -u -d "@$now" '+%Y-%m-%d %H:%M UTC' 2>/dev/null || echo "$now") (newest log file; days_left is counted from here)"
    command -v openssl >/dev/null 2>&1 || echo "openssl not found: subject, issuer and dates are not shown, only thumbprints"

    # 1+2: configuration files
    mapfile -d '' -t cfg_files < <(find "$BUNDLE_ROOT/opt/vmware/etc" "$BUNDLE_ROOT/etc" -type f \
        \( -name '*.json' -o -name '*.xml' -o -name '*.properties' -o -name '*.conf' -o -name '*.cfg' -o -name '*.pem' -o -name '*.crt' -o -name '*.cer' \) \
        ! -path '*/messages/*' ! -path '*/mockdata/*' ! -path '*/metadata/*' -print0 2>/dev/null | sort -z)
    recs=""
    (( ${#cfg_files[@]} )) && recs=$(awk -v root="$BUNDLE_ROOT" "$CERT_CFG_AWK" "${cfg_files[@]}" 2>/dev/null)

    echo ""
    echo "--- Certificates in configuration"
    rows=""
    while IFS=$'\t' read -r _ file ctx b64; do
        [[ -n "$b64" ]] || continue
        [[ -n "${CERT[$b64]:-}" ]] || CERT[$b64]=$(cert_row "$b64" "$now")
    done < <(grep '^C' <<< "$recs")
    for b64 in "${!CERT[@]}"; do
        row="${CERT[$b64]}"
        [[ -n "$row" ]] || continue
        IFS=$'\t' read -r sha256 sha1 subj _ <<< "$row"
        TP_LABEL[$sha256]="$subj"; TP_LABEL[$sha1]="$subj"
        rows+="$row"$'\n'
    done
    if [[ -n "$rows" ]]; then
        print_tsv $'sha256\tsha1\tsubject\tissuer\tsan\tvalid_from\tvalid_to\tdays_left\tstatus' "$(printf '%s' "$rows" | sort -t $'\t' -k3,3)"
        echo ""
        echo "Where each certificate is used:"
        rows=$(while IFS=$'\t' read -r _ file ctx b64; do
                   [[ -n "$b64" ]] || continue
                   row="${CERT[$b64]:-}"; [[ -n "$row" ]] || continue
                   printf '%s\t%s\t%s\n' "${row%%$'\t'*}" "$file" "$ctx"
               done < <(grep '^C' <<< "$recs") | sort -u | awk -F '\t' 'BEGIN { OFS = "\t" } { print substr($1, 1, 23) "...", $2, $3 }')
        print_tsv $'sha256\tfile\tused as' "$rows"
    else
        echo "(no certificates found in configuration files)"
    fi

    echo ""
    echo "--- Pinned thumbprints in configuration"
    rows=$(grep '^P' <<< "$recs" | while IFS=$'\t' read -r _ file key tp; do
               printf '%s\t%s\t%s\t%s\n' "$file" "$key" "$tp" "${TP_LABEL[$tp]:-(no configured certificate with this thumbprint)}"
           done | sort -u)
    if [[ -n "$rows" ]]; then print_tsv $'file\tsetting\tthumbprint\tmatches certificate' "$rows"; else echo "(none)"; fi

    echo ""
    echo "--- Certificate and TLS settings"
    rows=$(grep '^S' <<< "$recs" | cut -f2- | sort -u)
    if [[ -n "$rows" ]]; then
        print_tsv $'file\tsetting\tvalue' "$rows"
        grep -q $'\thms-trust-mode\t1$' <<< "$rows" && echo "hms-trust-mode 1 = lenient: a remote certificate is accepted when its thumbprint matches vSphere (0 = strict: also expiry, hostname, CA chain)"
    else
        echo "(none)"
    fi

    # 3-5: logs
    pick_logs '*'
    recs=$(
        for f in "${PICKED[@]}"; do
            rel="${f#"$BUNDLE_ROOT"/}"; rel="${rel#var/log/vmware/}"
            read_log "$f" \
                | LC_ALL=C grep -E 'ertificat|humbprint|handshake|TLS_error|PKIX|SSLHandshake|CERTIFICATE|checkPscCredentials|FileWatcher|^--> [A-Za-z0-9+/=]{20,}$|^--> \* |https?://|_lsppHost = |hostId = |address = |([0-9A-Fa-f]{2}:){19}[0-9A-Fa-f]{2}' \
                | LC_ALL=C grep -v 'notifyHandshake' \
                | awk -v lname="$rel" 'BEGIN { OFS = "\t" } { print lname, $0 }'
        done | awk -v from="$OPT_FROM" -v to="$OPT_TO" "$AWK_TS_LIB$CERT_LOG_AWK"
    )

    echo ""
    echo "--- Certificate events in logs${OPT_FROM:+ from $OPT_FROM}${OPT_TO:+ to $OPT_TO}"
    rows=$(grep '^E' <<< "$recs" | awk -F '\t' 'BEGIN { OFS = "\t" }
        { k = $4 SUBSEP $5 SUBSEP $6; c[k]++; if (!(k in f) || $2 < f[k]) f[k] = $2; if (!(k in l) || $2 > l[k]) l[k] = $2
          if (index(" " lg[k] " ", " " $3 " ") == 0) lg[k] = (lg[k] == "" ? "" : lg[k] " ") $3 }
        END { for (k in c) { split(k, a, SUBSEP); print f[k], l[k], c[k], a[1], a[2], a[3], lg[k] } }' | sort -t $'\t' -k1,1)
    if [[ -n "$rows" ]]; then
        print_tsv $'first\tlast\tcount\tevent\ttarget\tdetail\tlogs' "$rows"
    else
        echo "(no certificate events found)"
    fi

    echo ""
    echo "--- Certificates presented by hosts in failed SSL probes (a change per host = certificate changed)"
    rows=$(grep '^PC' <<< "$recs" | while IFS=$'\t' read -r _ t host b64; do
               row=$(cert_row "$b64" "$now"); [[ -n "$row" ]] || continue
               IFS=$'\t' read -r sha256 _ subj _ _ nb na _ <<< "$row"
               printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$host" "$t" "$sha256" "$subj" "$nb" "$na"
           done | awk -F '\t' 'BEGIN { OFS = "\t" }
               { k = $1 SUBSEP $3; c[k]++; if (!(k in f) || $2 < f[k]) f[k] = $2; if (!(k in l) || $2 > l[k]) l[k] = $2; s[k] = $4 "\t" $5 "\t" $6 }
               END { for (k in c) { split(k, a, SUBSEP); print a[1], f[k], l[k], c[k], a[2], s[k] } }' | sort -t $'\t' -k1,1 -k2,2)
    if [[ -n "$rows" ]]; then
        print_tsv $'host\tfirst\tlast\tprobes\tsha256\tsubject\tvalid_from\tvalid_to' "$rows"
        awk -F '\t' '{ n[$1]++ } END { for (h in n) if (n[h] > 1) print "CHANGED: " h " presented " n[h] " different certificates" }' <<< "$rows"
    else
        echo "(none)"
    fi

    echo ""
    echo "--- Thumbprints seen in logs (first seen after the logs start = possibly a new certificate)"
    rows=$(grep '^H' <<< "$recs" | awk -F '\t' 'BEGIN { OFS = "\t" }
               { c[$2]++; if (!($2 in f) || $3 < f[$2]) f[$2] = $3; if (!($2 in l) || $3 > l[$2]) l[$2] = $3
                 if (index(" " lg[$2] " ", " " $4 " ") == 0) { lg[$2] = (lg[$2] == "" ? "" : lg[$2] " ") $4; nl[$2]++ }
                 if ($5 != "") hc[$2, $5]++ }
               END {
                   for (k in hc) { split(k, a, SUBSEP); if (hc[k] > best[a[1]]) { best[a[1]] = hc[k]; host[a[1]] = a[2] } nh[a[1]]++ }
                   for (t in c) print f[t], l[t], c[t], t, (t in host ? host[t] (nh[t] > 1 ? " (+" nh[t] - 1 " more)" : "") : "-"), (nl[t] > 3 ? nl[t] " logs" : lg[t])
               }' | sort -t $'\t' -k1,1 \
           | while IFS=$'\t' read -r f l c tp h lg; do
                 printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$f" "$l" "$c" "$tp" "$h" "${TP_LABEL[$tp]:-(not a configured certificate)}" "$lg"
             done)
    if [[ -n "$rows" ]]; then
        print_tsv $'first\tlast\tcount\tthumbprint\tseen with host\tconfigured certificate\tlogs' "$rows"
    else
        echo "(none)"
    fi
    SECTIONS_RUN=$(( SECTIONS_RUN + 1 ))
}

print_summary() {
    local item
    print_section "Summary"
    echo "Bundle root:  $BUNDLE_ROOT"
    echo "Sections run: $SECTIONS_RUN/$SECTIONS_TOTAL"
    echo "Missing files/commands: ${#MISSING[@]}"
    for item in "${MISSING[@]}"; do echo "  - $item"; done
    echo "Skipped sections: ${#SKIPPED[@]}"
    for item in "${SKIPPED[@]}"; do echo "  - $item"; done
}

# --- Main ----------------------------------------------------------------------
main() {
    parse_args "$@"
    if [[ ! -d "$BUNDLE_ROOT" || ! -r "$BUNDLE_ROOT" ]]; then
        usage_error "bundle root '$BUNDLE_ROOT' is not a readable directory"
    fi
    echo "This is VLR 9.0.5 log bundel parser results"
    echo "Bundle root: $BUNDLE_ROOT"
    echo "Sections:    ${OPT_SECTIONS:-all}"

    check_required_files
    check_required_cmds

    if want_section build;     then section_build; fi
    if want_section network;   then section_network; fi
    if want_section services;  then section_services; fi
    if want_section endpoints; then section_endpoints; fi
    if want_section topology;  then
        section_topology_vcenters
        section_topology_vlr
        section_topology_nodes
    fi
    if want_section certificates; then section_certificates; fi
    if want_section coverage;  then section_log_coverage; fi
    if want_section health;    then section_log_health; fi
    if want_section workflows; then section_workflows; fi

    print_summary
    if (( SECTIONS_RUN == 0 )); then
        echo "ERROR: no section could run - is '$BUNDLE_ROOT' a VLR bundle root?" >&2
        exit 1
    fi
    exit 0
}

main "$@"
