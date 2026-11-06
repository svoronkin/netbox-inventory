#!/usr/bin/env bash
# netbox_proxmox_vms.sh - inventory of Proxmox VE virtual machines into NetBox (Virtualization).
# Runs on any node of a Proxmox cluster as root: VMs of the whole cluster are read with pvesh,
# interface names and IP addresses come from the QEMU guest agent when it runs in the VM.
# Requires: bash 4+, curl, jq, pvesh. Installs nothing by itself. Help: ./netbox_proxmox_vms.sh --help

set -euo pipefail
export LC_ALL=C

SCRIPT_VERSION=1.0.0

# ---------- settings (env or arguments) ----------
NETBOX_URL=${NETBOX_URL:-https://netbox.p4el.net}
NETBOX_TOKEN=${NETBOX_TOKEN:-}
NETBOX_TOKEN_FILE=${NETBOX_TOKEN_FILE:-}
NETBOX_CACERT=${NETBOX_CACERT:-}
NETBOX_RESOLVE=${NETBOX_RESOLVE:-}
NETBOX_TAG=${NETBOX_TAG:-auto-inventory}
CLUSTER_NAME=${CLUSTER_NAME:-}
TENANT_NAME=${TENANT_NAME:-}
VM_FILTER=${VM_FILTER:-}          # regex on the VM name; empty = all VMs
ROLE_RULES=()                     # "REGEX=Role" - role of a new VM, first match wins
PLATFORM_RULES=()                 # "REGEX=Platform" - platform of a new VM, first match wins
INCLUDE_TEMPLATES=0
INSECURE=0
DRY_RUN=0
COLLECT_ONLY=0
NO_IPV6=0
NO_DNS=0
DEBUG=${DEBUG:-0}

# ---------- output ----------
if [[ -t 2 ]]; then C_R=$'\e[31m' C_G=$'\e[32m' C_Y=$'\e[33m' C_B=$'\e[36m' C_0=$'\e[0m'; else C_R= C_G= C_Y= C_B= C_0=; fi
log()   { printf '%s\n' "$*" >&2; }
ok()    { printf '%s%s%s\n' "$C_G" "$*" "$C_0" >&2; }
warn()  { printf '%sWARN: %s%s\n' "$C_Y" "$*" "$C_0" >&2; }
err()   { printf '%sERROR: %s%s\n' "$C_R" "$*" "$C_0" >&2; }
die()   { err "$*"; exit 1; }
dbg()   { if [[ $DEBUG == 1 ]]; then printf '%sDEBUG: %s%s\n' "$C_B" "$*" "$C_0" >&2; fi; }
change(){ printf '%s%s %s%s\n' "$C_B" "$([[ $DRY_RUN == 1 ]] && echo '[dry-run]' || echo '*')" "$*" "$C_0" >&2; }

usage() {
    cat <<EOF
netbox_proxmox_vms.sh $SCRIPT_VERSION - adds/updates Proxmox VE virtual machines in NetBox (Virtualization).
Run on any node of the Proxmox cluster as root; VMs of all nodes are processed.

Usage: $0 --cluster NAME [options]

Connection:
  -u, --url URL            NetBox URL (default: $NETBOX_URL)
      --token-file FILE    file with the API token (mode 600). Or env NETBOX_TOKEN.
      --cacert FILE        CA certificate for TLS verification
      --resolve H:P:ADDR   connect to ADDR instead of the DNS address (like curl --resolve)
      --insecure           do not verify the TLS certificate (not recommended)

Virtual machines:
  -c, --cluster NAME       NetBox cluster of the VMs (required; looked up, never created)
      --tenant TENANT      tenant of new VMs and their IP addresses (looked up, never created)
  -f, --filter REGEX       only VMs whose name matches REGEX (default: all)
      --role 'REGEX=ROLE'  role of a new VM whose name matches REGEX (repeatable, first match wins)
      --platform 'REGEX=P' platform of a new VM whose name matches REGEX (repeatable)
      --include-templates  also add VM templates (skipped by default)

Modes:
      --dry-run            only read NetBox and show what would be changed
      --collect-only       only collect VM data and print it as JSON (no NetBox)
      --no-ipv6            do not add IPv6 addresses
      --no-dns             do not look up DNS names (PTR) of the addresses
      --debug              verbose output
  -h, --help               this help

The VM is placed on the NetBox device named like its Proxmox node (lab01), if that device is in
the cluster. Cluster, tenant and node devices are never created; roles and platforms are.
Everything the script creates is tagged '$NETBOX_TAG'. Nothing is deleted.

Example:
  $0 --token-file /root/.netbox-token --cluster Lab --tenant LAB --filter '^talos-' \\
     --role '^talos-cp=k8s control plane' --role '^talos-wrk-=k8s worker' --platform '^talos-=Talos Linux' --dry-run
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -u|--url)            NETBOX_URL=$2; shift 2 ;;
            --token-file)        NETBOX_TOKEN_FILE=$2; shift 2 ;;
            -t|--token)          die "--token is unsafe (visible in ps and shell history). Use --token-file or env NETBOX_TOKEN" ;;
            --cacert)            NETBOX_CACERT=$2; shift 2 ;;
            --resolve)           NETBOX_RESOLVE=$2; shift 2 ;;
            --insecure)          INSECURE=1; shift ;;
            -c|--cluster)        CLUSTER_NAME=$2; shift 2 ;;
            --tenant)            TENANT_NAME=$2; shift 2 ;;
            -f|--filter)         VM_FILTER=$2; shift 2 ;;
            --role)              [[ $2 == *=* ]] || die "--role expects 'REGEX=ROLE'"; ROLE_RULES+=("$2"); shift 2 ;;
            --platform)          [[ $2 == *=* ]] || die "--platform expects 'REGEX=PLATFORM'"; PLATFORM_RULES+=("$2"); shift 2 ;;
            --include-templates) INCLUDE_TEMPLATES=1; shift ;;
            --dry-run)           DRY_RUN=1; shift ;;
            --collect-only)      COLLECT_ONLY=1; shift ;;
            --no-ipv6)           NO_IPV6=1; shift ;;
            --no-dns)            NO_DNS=1; shift ;;
            --debug)             DEBUG=1; shift ;;
            -h|--help)           usage; exit 0 ;;
            *)                   usage >&2; die "unknown argument: $1" ;;
        esac
    done
}

check_deps() {
    local missing=() c
    for c in curl jq pvesh awk sed; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        die "not found: ${missing[*]}. Run the script on a Proxmox VE node (the script installs nothing itself)."
    fi
    if (( BASH_VERSINFO[0] < 4 )); then die "bash 4+ is required"; fi
    if [[ $EUID -ne 0 ]]; then die "run as root: pvesh needs it"; fi
}

# ---------- helpers ----------
uri()     { jq -rn --arg v "$1" '$v|@uri'; }
slugify() {
    local s
    s=$(printf '%s' "${1,,}" | sed -E 's/[^a-z0-9_]+/-/g; s/^-+//; s/-+$//')
    printf '%s' "${s:0:100}"
}
# First rule "REGEX=VALUE" whose REGEX matches the name -> VALUE
match_rule() {
    local name=$1 r; shift
    for r in "$@"; do
        if [[ $name =~ ${r%%=*} ]]; then printf '%s' "${r#*=}"; return 0; fi
    done
}
# Proxmox size "50G" / "512M" / "1T" -> MB (NetBox 4.1+ stores VM memory and disk sizes in MB)
size_mb() {
    local s=$1 n u
    n=${s%[KMGTkmgt]}; u=${s:${#n}}
    case ${u^^} in
        K) echo $(( n / 1024 )) ;;
        M|'') echo "$n" ;;
        G) echo $(( n * 1024 )) ;;
        T) echo $(( n * 1024 * 1024 )) ;;
    esac
}
ptr_name() {
    [[ $NO_DNS == 1 ]] && return 0
    getent hosts "$1" 2>/dev/null | awk 'NR==1 && $2 ~ /\./ {sub(/\.$/, "", $2); print $2}' || true
}

# ======================================================================
#  Collect: VMs of the Proxmox cluster
# ======================================================================
# One VM -> JSON: name, vmid, node, status, template, vcpus, memory_mb, disks[], nics[]
collect_vm() {
    local node=$1 vmid=$2 status=$3 template=$4 cfg agent='{}' disks nics
    cfg=$(pvesh get "/nodes/$node/qemu/$vmid/config" --output-format json)
    # Guest agent (only for running VMs with the agent enabled); interfaces are matched to NICs by MAC
    if [[ $status == running && $(jq -r '.agent // "" | tostring' <<<"$cfg") =~ (^|enabled=)1 ]]; then
        agent=$(timeout 15 pvesh get "/nodes/$node/qemu/$vmid/agent/network-get-interfaces" --output-format json 2>/dev/null) \
            || { warn "VM $vmid: guest agent does not answer - no interface names and IP addresses"; agent='{}'; }
    fi
    disks=$(jq -c '
        [ to_entries[]
          | select(.key | test("^(scsi|virtio|sata|ide)[0-9]+$"))
          | select(.value | test("media=cdrom") | not)
          | select(.value | test("size="))
          | {name: .key, storage: (.value | split(",")[0]),
             size: (.value | capture("size=(?<s>[0-9]+[KMGTkmgt]?)").s)} ]' <<<"$cfg")
    nics=$(jq -c --argjson a "$agent" --argjson noipv6 "$NO_IPV6" '
        def agent_if($mac): ($a.result // []) | map(select((."hardware-address" // "" | ascii_downcase) == $mac)) | first;
        [ to_entries[] | select(.key | test("^net[0-9]+$"))
          | (.value | split(",")) as $p
          | ($p[0] | split("=")) as $m
          | ($m[1] // "" | ascii_downcase) as $mac
          | agent_if($mac) as $g
          | {key: .key, model: $m[0], mac: ($mac | ascii_upcase),
             bridge: ([$p[] | select(startswith("bridge=")) | sub("bridge=";"")] | first // ""),
             vlan: ([$p[] | select(startswith("tag=")) | sub("tag=";"")] | first // ""),
             ifname: ($g.name // .key),
             addresses: [ ($g."ip-addresses" // [])[]
                          | select(."ip-address-type" == "ipv4" or ($noipv6 == 0 and ."ip-address-type" == "ipv6"))
                          | select(."ip-address" | test("^(127\\.|169\\.254\\.|::1$|fe80:)") | not)
                          | "\(."ip-address")/\(.prefix)" ] } ]' <<<"$cfg")
    jq -cn --argjson cfg "$cfg" --arg node "$node" --argjson vmid "$vmid" --arg status "$status" \
        --argjson template "$template" --argjson disks "$disks" --argjson nics "$nics" '
        {name: $cfg.name, vmid: $vmid, node: $node, status: $status, template: ($template == 1),
         vcpus: (if $cfg.vcpus then ($cfg.vcpus|tonumber) else (($cfg.sockets // 1)|tonumber) * (($cfg.cores // 1)|tonumber) end),
         memory: ($cfg.memory // "512" | tostring), balloon: ($cfg.balloon // null),
         disks: $disks, nics: $nics}'
}

collect_vms() {
    local list node vmid status template name out='[]' vm
    list=$(pvesh get /cluster/resources --type vm --output-format json)
    while IFS=$'\t' read -r node vmid status template name; do
        if [[ $template == 1 && $INCLUDE_TEMPLATES == 0 ]]; then dbg "skip template $vmid $name"; continue; fi
        if [[ -n $VM_FILTER && ! $name =~ $VM_FILTER ]]; then dbg "skip $vmid $name (filter)"; continue; fi
        dbg "collect $node/$vmid $name"
        vm=$(collect_vm "$node" "$vmid" "$status" "$template")
        # sizes to MB here: jq has no unit parser
        vm=$(jq -c '.' <<<"$vm")
        local d sized='[]' n s
        while IFS=$'\t' read -r n s d; do
            sized=$(jq -c --arg n "$n" --argjson mb "$(size_mb "$s")" --arg st "$d" '. + [{name:$n, size_mb:$mb, storage:$st}]' <<<"$sized")
        done < <(jq -r '.disks[] | [.name, .size, .storage] | @tsv' <<<"$vm")
        vm=$(jq -c --argjson d "$sized" '.disks = $d | .memory_mb = (.memory|tonumber) | del(.memory)' <<<"$vm")
        out=$(jq -c --argjson v "$vm" '. + [$v]' <<<"$out")
    done < <(jq -r '.[] | select(.type == "qemu") | [.node, .vmid, .status, (.template // 0), .name] | @tsv' <<<"$list" | sort -k5)
    echo "$out"
}

# ======================================================================
#  NetBox API (same conventions as netbox_inventory.sh)
# ======================================================================
TMPDIR_NB=""
AUTH_HEADER_FILE=""
NB_VERSION=""
TAG_JSON='[]'
cleanup() { if [[ -n $TMPDIR_NB ]]; then rm -rf "$TMPDIR_NB"; fi; }
trap cleanup EXIT

setup_api() {
    if [[ -z $NETBOX_TOKEN && -n $NETBOX_TOKEN_FILE ]]; then
        [[ -r $NETBOX_TOKEN_FILE ]] || die "cannot read $NETBOX_TOKEN_FILE"
        NETBOX_TOKEN=$(tr -d '\r\n' <"$NETBOX_TOKEN_FILE")
    fi
    NETBOX_TOKEN=$(sed -E 's/^[[:space:]]*(Bearer|Token)[[:space:]]+//I; s/[[:space:]]//g' <<<"$NETBOX_TOKEN")
    [[ -n $NETBOX_TOKEN ]] || die "no API token: set NETBOX_TOKEN or --token-file"
    TMPDIR_NB=$(mktemp -d)
    chmod 700 "$TMPDIR_NB"
    local scheme=Token
    if [[ $NETBOX_TOKEN == nbt_* ]]; then scheme=Bearer; fi
    AUTH_HEADER_FILE=$TMPDIR_NB/auth
    ( umask 077; printf 'Authorization: %s %s\n' "$scheme" "$NETBOX_TOKEN" >"$AUTH_HEADER_FILE" )
    CURL_OPTS=(--silent --show-error --connect-timeout 10 --max-time 60 --retry 2 --retry-delay 2
               -H "@$AUTH_HEADER_FILE" -H 'Accept: application/json' -H 'Content-Type: application/json')
    if [[ -n $NETBOX_CACERT ]]; then CURL_OPTS+=(--cacert "$NETBOX_CACERT"); fi
    if [[ -n $NETBOX_RESOLVE ]]; then CURL_OPTS+=(--resolve "$NETBOX_RESOLVE"); fi
    if [[ $INSECURE == 1 ]]; then warn "TLS verification disabled (--insecure)"; CURL_OPTS+=(-k); fi
}

# nb METHOD PATH [JSON] -> response body on stdout; exit code 1 on error
nb() {
    local method=$1 path=${2#/} data=${3:-} out code
    if [[ $method != GET && $DRY_RUN == 1 ]]; then
        dbg "$method /api/$path $data"
        printf '{"id":0}'
        return 0
    fi
    out=$TMPDIR_NB/resp
    dbg "$method /api/$path ${data:0:300}"
    if [[ -n $data ]]; then
        code=$(curl "${CURL_OPTS[@]}" -o "$out" -w '%{http_code}' -X "$method" --data "$data" "${NETBOX_URL%/}/api/$path") || { err "curl: $method /api/$path"; return 1; }
    else
        code=$(curl "${CURL_OPTS[@]}" -o "$out" -w '%{http_code}' -X "$method" "${NETBOX_URL%/}/api/$path") || { err "curl: $method /api/$path"; return 1; }
    fi
    if [[ $code -eq 401 || $code -eq 403 ]] && grep -qiE 'token|credentials' "$out"; then
        err "HTTP $code: token rejected ($(head -c 200 "$out")). Check the token and its permissions."
        return 2
    fi
    if [[ $code -ge 400 || $code -eq 0 ]]; then
        err "HTTP $code: $method /api/$path: $(head -c 500 "$out")"
        return 1
    fi
    cat "$out"
}

nb_find() {
    local path=$1 query=$2 resp count
    resp=$(nb GET "${path}?${query}&limit=2") || return 1
    count=$(jq -r '.count' <<<"$resp")
    if [[ $count -gt 1 ]]; then warn "found $count objects $path?$query, using the first one"; fi
    jq -c '.results[0] // empty' <<<"$resp"
}
nb_find_id() { local o; o=$(nb_find "$@") || return 1; jq -r '.id // empty' <<<"$o"; }

nb_ensure_named() {
    local path=$1 name=$2 extra=${3:-'{}'} id slug obj
    slug=$(slugify "$name")
    id=$(nb_find_id "$path" "slug=$(uri "$slug")") || return 1
    [[ -n $id ]] || id=$(nb_find_id "$path" "name__ie=$(uri "$name")") || return 1
    if [[ -n $id ]]; then echo "$id"; return 0; fi
    obj=$(jq -cn --arg n "$name" --arg s "$slug" --argjson e "$extra" --argjson t "$TAG_JSON" \
        '{name:$n, slug:$s, tags:$t} + $e')
    change "create ${path%/} '$name'"
    nb POST "$path" "$obj" | jq -r '.id'
}

nb_lookup_named() {
    local path=$1 name=$2 id
    id=$(nb_find_id "$path" "name__ie=$(uri "$name")") || return 1
    [[ -n $id ]] || id=$(nb_find_id "$path" "slug=$(uri "$(slugify "$name")")") || return 1
    echo "$id"
}

version_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" == "$2" ]]; }

check_netbox() {
    local status rc=0
    status=$(nb GET "status/") || rc=$?
    if [[ $rc -eq 2 ]]; then exit 1; fi
    if [[ $rc -ne 0 ]]; then die "NetBox is unreachable: $NETBOX_URL"; fi
    NB_VERSION=$(jq -r '."netbox-version" // empty' <<<"$status")
    NB_VERSION=${NB_VERSION%%-*}
    version_ge "$NB_VERSION" 4.2 || die "NetBox 4.2+ is required (MAC address objects, VM sizes in MB); found $NB_VERSION"
    ok "NetBox $NB_VERSION ($NETBOX_URL)"
    if [[ $DRY_RUN == 0 ]]; then
        nb_ensure_named "extras/tags/" "$NETBOX_TAG" '{"color":"9e9e9e","description":"Created by netbox-inventory scripts"}' >/dev/null
    fi
    TAG_JSON=$(jq -cn --arg s "$(slugify "$NETBOX_TAG")" '[{slug:$s}]')
}

# ======================================================================
#  Sync one VM
# ======================================================================
CLUSTER_ID=""
TENANT_ID=""
declare -A NODE_DEVICE=()   # Proxmox node -> NetBox device id in the cluster (or empty)

node_device() {
    local node=$1 dev
    if [[ -z ${NODE_DEVICE[$node]+x} ]]; then
        dev=$(nb_find "dcim/devices/" "name=$(uri "$node")") || return 1
        if [[ -z $dev ]]; then
            warn "no NetBox device '$node' - VMs of this node are not placed on a device"
            NODE_DEVICE[$node]=""
        elif [[ $(jq -r '.cluster.id // 0' <<<"$dev") != "$CLUSTER_ID" ]]; then
            warn "device '$node' is not in cluster '$CLUSTER_NAME' - its VMs are not placed on it (add the device to the cluster in NetBox)"
            NODE_DEVICE[$node]=""
        else
            NODE_DEVICE[$node]=$(jq -r .id <<<"$dev")
        fi
    fi
    printf '%s' "${NODE_DEVICE[$node]}"
}

sync_vm() {
    local vm=$1 name vmid node status nbstatus dev_id cur vm_id body patch role platform role_id platform_id
    name=$(jq -r .name <<<"$vm"); vmid=$(jq -r .vmid <<<"$vm"); node=$(jq -r .node <<<"$vm")
    status=$(jq -r .status <<<"$vm")
    case $status in running) nbstatus=active ;; *) nbstatus=offline ;; esac
    dev_id=$(node_device "$node") || return 1

    cur=$(nb_find "virtualization/virtual-machines/" "name=$(uri "$name")&cluster_id=$CLUSTER_ID") || return 1
    if [[ -z $cur ]]; then
        role=$(match_rule "$name" "${ROLE_RULES[@]+"${ROLE_RULES[@]}"}")
        platform=$(match_rule "$name" "${PLATFORM_RULES[@]+"${PLATFORM_RULES[@]}"}")
        role_id=""; platform_id=""
        if [[ -n $role ]]; then role_id=$(nb_ensure_named "dcim/device-roles/" "$role" '{"color":"9e9e9e","vm_role":true}') || return 1; fi
        if [[ -n $platform ]]; then platform_id=$(nb_ensure_named "dcim/platforms/" "$platform") || return 1; fi
        body=$(jq -cn --argjson v "$vm" --arg st "$nbstatus" --argjson c "$CLUSTER_ID" --arg d "$dev_id" --arg t "$TENANT_ID" \
            --arg r "$role_id" --arg p "$platform_id" --argjson tags "$TAG_JSON" '
            {name:$v.name, cluster:$c, status:$st, vcpus:$v.vcpus, memory:$v.memory_mb, serial:($v.vmid|tostring), tags:$tags}
            + (if $d != "" then {device:($d|tonumber)} else {} end)
            + (if $t != "" then {tenant:($t|tonumber)} else {} end)
            + (if $r != "" and $r != "0" then {role:($r|tonumber)} else {} end)
            + (if $p != "" and $p != "0" then {platform:($p|tonumber)} else {} end)')
        change "create VM '$name' (vmid $vmid on $node)"
        vm_id=$(nb POST "virtualization/virtual-machines/" "$body" | jq -r .id) || return 1
        cur='{}'
    else
        vm_id=$(jq -r .id <<<"$cur")
        # What Proxmox knows is synced: status, vCPU, memory, node (after migration), VMID if empty.
        # Role, platform, tenant, description and comments are left as they are in NetBox.
        patch=$(jq -cn --argjson c "$cur" --argjson v "$vm" --arg st "$nbstatus" --arg d "$dev_id" '
            {}
            + (if ($c.status.value // "") != $st then {status:$st} else {} end)
            + (if (($c.vcpus // 0)|tonumber) != $v.vcpus then {vcpus:$v.vcpus} else {} end)
            + (if ($c.memory // 0) != $v.memory_mb then {memory:$v.memory_mb} else {} end)
            + (if ($c.serial // "") == "" then {serial:($v.vmid|tostring)} else {} end)
            + (if $d != "" and (($c.device.id // 0)|tostring) != $d then {device:($d|tonumber)} else {} end)')
        if [[ $patch != '{}' ]]; then
            change "update VM '$name': $patch"
            nb PATCH "virtualization/virtual-machines/$vm_id/" "$patch" >/dev/null || return 1
        else
            log "  VM '$name' up to date"
        fi
    fi
    sync_disks "$vm" "$vm_id" "$name"
    sync_nics "$vm" "$vm_id" "$name" "$cur"
}

sync_disks() {
    local vm=$1 vm_id=$2 name=$3 dname size cur
    while IFS=$'\t' read -r dname size; do
        if [[ ! $vm_id =~ ^[1-9] ]]; then change "  disk $dname ${size} MB"; continue; fi
        cur=$(nb_find "virtualization/virtual-disks/" "virtual_machine_id=$vm_id&name=$(uri "$dname")") || return 1
        if [[ -z $cur ]]; then
            change "  create disk $name/$dname ${size} MB"
            nb POST "virtualization/virtual-disks/" "$(jq -cn --argjson v "$vm_id" --arg n "$dname" --argjson s "$size" \
                --argjson t "$TAG_JSON" '{virtual_machine:$v, name:$n, size:$s, tags:$t}')" >/dev/null || return 1
        elif [[ $(jq -r .size <<<"$cur") != "$size" ]]; then
            change "  disk $name/$dname: $(jq -r .size <<<"$cur") -> $size MB"
            nb PATCH "virtualization/virtual-disks/$(jq -r .id <<<"$cur")/" "{\"size\":$size}" >/dev/null || return 1
        fi
    done < <(jq -r '.disks[] | [.name, .size_mb] | @tsv' <<<"$vm")
}

sync_nics() {
    local vm=$1 vm_id=$2 name=$3 cur_vm=$4 nic ifname mac if_cur iid primary4="" first=1
    while IFS= read -r nic; do
        ifname=$(jq -r .ifname <<<"$nic"); mac=$(jq -r .mac <<<"$nic")
        if [[ ! $vm_id =~ ^[1-9] ]]; then
            change "  interface $ifname $mac $(jq -r '.addresses | join(" ")' <<<"$nic")"
            continue
        fi
        if_cur=$(nb_find "virtualization/interfaces/" "virtual_machine_id=$vm_id&name=$(uri "$ifname")") || return 1
        if [[ -z $if_cur ]]; then
            change "  create interface $name/$ifname"
            iid=$(nb POST "virtualization/interfaces/" "$(jq -cn --argjson v "$vm_id" --arg n "$ifname" --argjson t "$TAG_JSON" \
                --arg d "$(jq -r '[.bridge, (if .vlan != "" then "vlan \(.vlan)" else empty end)] | map(select(. != "")) | join(", ")' <<<"$nic")" \
                '{virtual_machine:$v, name:$n, enabled:true, tags:$t} + (if $d != "" then {description:$d} else {} end)')" | jq -r .id) || return 1
            if_cur='{}'
        else
            iid=$(jq -r .id <<<"$if_cur")
        fi
        sync_mac "$iid" "$mac" "$if_cur" "$name/$ifname"
        local addr ip_cur ip_id dns owner
        while IFS= read -r addr; do
            [[ -n $addr ]] || continue
            ip_cur=$(nb_find "ipam/ip-addresses/" "address=$(uri "$addr")&vrf_id=null") || return 1
            if [[ -n $ip_cur ]]; then
                ip_id=$(jq -r .id <<<"$ip_cur")
                owner=$(jq -r '.assigned_object.virtual_machine.id // .assigned_object.device.id // empty' <<<"$ip_cur")
                if [[ -n $owner && $(jq -r '.assigned_object_id // 0' <<<"$ip_cur") != "$iid" ]]; then
                    warn "IP $addr is already assigned to $(jq -r '.assigned_object.virtual_machine.name // .assigned_object.device.name' <<<"$ip_cur") - leaving it"
                    continue
                fi
                if [[ -z $owner ]]; then
                    change "  IP $addr -> $name/$ifname"
                    nb PATCH "ipam/ip-addresses/$ip_id/" "{\"assigned_object_type\":\"virtualization.vminterface\",\"assigned_object_id\":$iid}" >/dev/null || return 1
                fi
            else
                dns=$(ptr_name "${addr%/*}")
                change "  create IP $addr${dns:+ ($dns)} on $name/$ifname"
                ip_id=$(nb POST "ipam/ip-addresses/" "$(jq -cn --arg a "$addr" --argjson i "$iid" --arg d "$dns" --arg t "$TENANT_ID" \
                    --argjson tags "$TAG_JSON" '{address:$a, status:"active", assigned_object_type:"virtualization.vminterface",
                     assigned_object_id:$i, tags:$tags} + (if $d != "" then {dns_name:$d} else {} end)
                     + (if $t != "" then {tenant:($t|tonumber)} else {} end)')" | jq -r .id) || return 1
            fi
            if [[ $first == 1 && $addr != *:* && -z $primary4 ]]; then primary4=$ip_id; fi
        done < <(jq -r '.addresses[]' <<<"$nic")
        first=0
    done < <(jq -c '.nics[]' <<<"$vm")

    # primary_ip4: the first IPv4 of the first NIC, set only if empty (a manual choice is not overwritten)
    if [[ $primary4 =~ ^[1-9] && $(jq -r '.primary_ip4.id // 0' <<<"$cur_vm") == 0 ]]; then
        change "  VM '$name' primary IPv4 -> $primary4"
        nb PATCH "virtualization/virtual-machines/$vm_id/" "{\"primary_ip4\":$primary4}" >/dev/null || true
    fi
}

sync_mac() {
    local iid=$1 mac=$2 cur=$3 label=$4 found mid
    [[ -n $mac ]] || return 0
    if [[ ! $iid =~ ^[1-9] ]]; then change "  MAC $mac -> $label"; return 0; fi
    found=$(nb_find "dcim/mac-addresses/" "mac_address=$(uri "$mac")&vminterface_id=$iid") || return 0
    if [[ -n $found ]]; then
        mid=$(jq -r .id <<<"$found")
    else
        change "  MAC $mac -> $label"
        mid=$(nb POST "dcim/mac-addresses/" "$(jq -cn --arg m "$mac" --argjson i "$iid" --argjson t "$TAG_JSON" \
            '{mac_address:$m, assigned_object_type:"virtualization.vminterface", assigned_object_id:$i, tags:$t}')" | jq -r .id) || return 0
    fi
    if [[ $(jq -r '.primary_mac_address.id // 0' <<<"$cur") == 0 && $mid =~ ^[1-9] ]]; then
        nb PATCH "virtualization/interfaces/$iid/" "{\"primary_mac_address\":$mid}" >/dev/null || true
    fi
}

# ======================================================================
print_summary() {
    jq -r '.[] | "\(.name)  vmid \(.vmid) on \(.node), \(.status)\(if .template then " (template)" else "" end), \(.vcpus) vCPU, \(.memory_mb) MB, disks: \([.disks[] | "\(.name) \(.size_mb) MB"] | join(", ")), nics: \([.nics[] | "\(.ifname) \(.mac) \(.addresses | join(" "))"] | join("; "))"' <<<"$1" >&2
}

main() {
    parse_args "$@"
    check_deps
    log "Collecting VMs of the Proxmox cluster..."
    local vms vm
    vms=$(collect_vms)
    if [[ $COLLECT_ONLY == 1 ]]; then
        jq . <<<"$vms"
        return 0
    fi
    [[ -n $CLUSTER_NAME ]] || die "--cluster is required (NetBox cluster of the VMs)"
    print_summary "$vms"
    [[ $(jq length <<<"$vms") -gt 0 ]] || { warn "no VMs to process"; return 0; }
    if [[ $DRY_RUN == 1 ]]; then warn "--dry-run mode: changes are only printed"; fi

    setup_api
    check_netbox
    CLUSTER_ID=$(nb_lookup_named "virtualization/clusters/" "$CLUSTER_NAME") || exit 1
    [[ -n $CLUSTER_ID ]] || die "cluster '$CLUSTER_NAME' not found in NetBox"
    if [[ -n $TENANT_NAME ]]; then
        TENANT_ID=$(nb_lookup_named "tenancy/tenants/" "$TENANT_NAME") || exit 1
        [[ -n $TENANT_ID ]] || die "tenant '$TENANT_NAME' not found"
    fi
    while IFS= read -r vm; do
        log "VM $(jq -r '"\(.name) (vmid \(.vmid), \(.node))"' <<<"$vm")"
        sync_vm "$vm" || err "VM $(jq -r .name <<<"$vm"): failed, continuing with the next one"
    done < <(jq -c '.[]' <<<"$vms")
    ok "Done: $(jq length <<<"$vms") VM(s)$([[ $DRY_RUN == 1 ]] && echo ' (dry-run, nothing changed)')"
}

if [[ -z ${BASH_SOURCE[0]:-} || ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
