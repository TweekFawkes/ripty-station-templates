#!/usr/bin/env bash
# Ripty Station on one Google Compute Engine VM.
#
# Creates the firewall rules and one Ubuntu 24.04 LTS VM. The VM's startup script installs the Station
# from your Headquarters (the installer Headquarters serves at /connector/v1/install.sh), starts it and
# enrolls it with the join token. Add Station in Headquarters prints every value this script needs, and
# Download values on its Templates list saves them as station.env.
#
# Run it in Google Cloud Shell, or anywhere gcloud is signed in:
#
#   set -a; source station.env; set +a
#   bash deploy.sh --project my-project --dry-run    # print the gcloud commands only
#   bash deploy.sh --project my-project
#
# It mirrors deploy/aws/ripty-connector.yaml: the same ports, the same install line, a VM of 2 GB.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: deploy.sh [options]

Values (environment variables; the flag of the same name overrides it):
  RIPTY_HQ_URL        The Station address of Headquarters, for example https://203.0.113.7:12199
  RIPTY_JOIN_TOKEN    The join token from Add Station (works once, expires after one day)
  RIPTY_HQ_PIN        The certificate pin, sha256: and 64 hex digits. Empty when Headquarters has a
                      public certificate. Set it together with RIPTY_HQ_SPKI.
  RIPTY_HQ_SPKI       The public key pin, sha256// and 43 characters and "=". Set it with RIPTY_HQ_PIN.
  RIPTY_DNS_ZONE      Optional. A DNS callback zone; makes the Station a DNS Station and opens port 53.

Options:
  --project ID        The Google Cloud project (default: the project gcloud is set to)
  --zone ZONE         The zone of the VM (default us-central1-a)
  --machine-type T    The machine type (default e2-small, 2 GB of memory; the same size as the AWS
                      template's default)
  --allowed-cidr C    Who may reach the Meeting Sites and Signal Sites (default 0.0.0.0/0)
  --ssh-cidr C        Optional. Allow ssh (port 22) from this range. There is no ssh rule without it.
  --network N         The VPC network (default "default")
  --subnet S          Optional. The subnet, for a custom-mode network
  --name NAME         The VM name, and the prefix of its firewall rules and network tag
                      (default ripty-station)
  --hq-url URL        Same as RIPTY_HQ_URL
  --join-token T      Same as RIPTY_JOIN_TOKEN (prefer the variable: a flag stays in shell history)
  --hq-pin PIN        Same as RIPTY_HQ_PIN
  --hq-spki KEY       Same as RIPTY_HQ_SPKI
  --dns-zone ZONE     Same as RIPTY_DNS_ZONE
  --dry-run           Print the gcloud commands (and the startup script, the token hidden) and run none
  -h, --help          This text
EOF
}

die() {
  printf 'deploy.sh: %s\n' "$*" >&2
  exit 2
}

HQ_URL=${RIPTY_HQ_URL:-}
JOIN_TOKEN=${RIPTY_JOIN_TOKEN:-}
HQ_PIN=${RIPTY_HQ_PIN:-}
HQ_SPKI=${RIPTY_HQ_SPKI:-}
DNS_ZONE=${RIPTY_DNS_ZONE:-}
PROJECT=
ZONE=us-central1-a
MACHINE_TYPE=e2-small
ALLOWED_CIDR=0.0.0.0/0
SSH_CIDR=
NETWORK=default
SUBNET=
NAME=ripty-station
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --dry-run) DRY_RUN=1; shift; continue ;;
  esac
  [ $# -ge 2 ] || die "$1 needs a value (see --help)"
  case "$1" in
    --project) PROJECT=$2 ;;
    --zone) ZONE=$2 ;;
    --machine-type) MACHINE_TYPE=$2 ;;
    --allowed-cidr) ALLOWED_CIDR=$2 ;;
    --ssh-cidr) SSH_CIDR=$2 ;;
    --network) NETWORK=$2 ;;
    --subnet) SUBNET=$2 ;;
    --name) NAME=$2 ;;
    --hq-url) HQ_URL=$2 ;;
    --join-token) JOIN_TOKEN=$2 ;;
    --hq-pin) HQ_PIN=$2 ;;
    --hq-spki) HQ_SPKI=$2 ;;
    --dns-zone) DNS_ZONE=$2 ;;
    *) die "unknown option $1 (see --help)" ;;
  esac
  shift 2
done

# The checks are the AWS template's AllowedPattern values, so no value holds a quote or a shell
# character: the startup script puts them between single quotes.
check() { # check LABEL VALUE ERE MESSAGE
  [[ $2 =~ $3 ]] || die "$1: $4"
}

[ -n "$HQ_URL" ] || die "RIPTY_HQ_URL is empty: copy the Station address from Add Station in Headquarters"
[ -n "$JOIN_TOKEN" ] || die "RIPTY_JOIN_TOKEN is empty: copy the join token from Add Station"
check RIPTY_HQ_URL "$HQ_URL" '^https://[]A-Za-z0-9._~:/[-]*[]A-Za-z0-9._~:[-]$' \
  "an https address with no trailing slash"
check RIPTY_JOIN_TOKEN "$JOIN_TOKEN" '^rtt_[A-Za-z0-9_-]{43}$' \
  "the join token, rtt_ followed by 43 letters, digits, underscores or hyphens"
if [ -n "$HQ_PIN" ]; then
  check RIPTY_HQ_PIN "$HQ_PIN" '^sha256:[0-9a-f]{64}$' "sha256 and a colon, then 64 lowercase hex digits"
fi
if [ -n "$HQ_SPKI" ]; then
  check RIPTY_HQ_SPKI "$HQ_SPKI" '^sha256//[A-Za-z0-9+/]{43}=$' \
    "sha256// followed by 43 base64 characters and an equals sign"
fi
if [ -n "$HQ_PIN" ] && [ -z "$HQ_SPKI" ]; then
  die "RIPTY_HQ_PIN needs RIPTY_HQ_SPKI too (copy both from Add Station)"
fi
if [ -z "$HQ_PIN" ] && [ -n "$HQ_SPKI" ]; then
  die "RIPTY_HQ_SPKI needs RIPTY_HQ_PIN too (copy both from Add Station)"
fi
if [ -n "$DNS_ZONE" ]; then
  DNS_ZONE=$(printf '%s' "$DNS_ZONE" | tr 'A-Z' 'a-z')
  DNS_ZONE=${DNS_ZONE%.}
  check RIPTY_DNS_ZONE "$DNS_ZONE" '^[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?$' "a DNS name such as cb.example.com"
fi
CIDR='^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$'
check --allowed-cidr "$ALLOWED_CIDR" "$CIDR" "an IPv4 CIDR range, for example 10.0.0.0/8"
if [ -n "$SSH_CIDR" ]; then
  check --ssh-cidr "$SSH_CIDR" "$CIDR" "an IPv4 CIDR range, for example 203.0.113.7/32"
fi
check --name "$NAME" '^[a-z]([-a-z0-9]{0,40}[a-z0-9])?$' "lower-case letters, digits and hyphens, starting with a letter"
check --zone "$ZONE" '^[a-z]+-[a-z]+[0-9]+-[a-z]$' "a zone such as us-central1-a"
check --machine-type "$MACHINE_TYPE" '^[a-z0-9][a-z0-9-]{0,40}$' "a machine type such as e2-small"
check --network "$NETWORK" '^[A-Za-z0-9][A-Za-z0-9/_.-]{0,200}$' "a network name"
if [ -n "$SUBNET" ]; then
  check --subnet "$SUBNET" '^[A-Za-z0-9][A-Za-z0-9/_.-]{0,200}$' "a subnet name"
fi

if [ -z "$PROJECT" ]; then
  PROJECT=${CLOUDSDK_CORE_PROJECT:-}
fi
if [ -z "$PROJECT" ] && command -v gcloud >/dev/null 2>&1; then
  PROJECT=$(gcloud config get-value project 2>/dev/null || true)
fi
if [ -z "$PROJECT" ]; then
  if [ "$DRY_RUN" = 1 ]; then
    PROJECT=YOUR_PROJECT_ID
  else
    die "no project: pass --project ID, or run gcloud config set project ID"
  fi
fi
check --project "$PROJECT" '^[a-zA-Z0-9][a-zA-Z0-9:._-]{0,100}$' "a project ID"

# The Meeting Sites (80, 8080, 8000) and the Signal Sites (ssh 22000, RDP 33890), the ports of the AWS
# security group. Port 22 is the VM's own sshd: it opens only for --ssh-cidr.
STATION_RULES=tcp:80,tcp:8080,tcp:8000,tcp:22000,tcp:33890
# A DNS Station answers on port 53 over udp and tcp.
DNS_RULES=tcp:53,udp:53
SSH_RULES=tcp:22

# The startup script. Google runs it as root at every boot, so it leaves a marker file after the first
# good install and does nothing after that. $1 is the join token to write ("rtt_REDACTED" for a dry
# run). The parts that hold no value are the AWS template's user data, line for line.
write_startup_script() {
  printf '#!/bin/bash\n'
  printf "CONSOLE_URL='%s'\n" "$HQ_URL"
  printf "JOIN_TOKEN='%s'\n" "$1"
  printf "CONSOLE_PIN='%s'\n" "$HQ_PIN"
  printf "CONSOLE_SPKI='%s'\n" "$HQ_SPKI"
  printf "DNS_ZONE='%s'\n" "$DNS_ZONE"
  cat <<'EOF'
# Installs the Station from Headquarters and enrolls it. The log is /var/log/ripty-install.log.
DONE=/var/lib/ripty-install.done
if [ -e "$DONE" ]; then
  exit 0
fi
(umask 077; : >>/var/log/ripty-install.log)
exec >>/var/log/ripty-install.log 2>&1
echo "ripty-install: start $(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [ -n "$CONSOLE_PIN" ] && [ -z "$CONSOLE_SPKI" ]; then
  echo "ripty-install: RIPTY_HQ_PIN needs RIPTY_HQ_SPKI too (copy both from Add Station)"
  exit 2
fi
if [ -z "$CONSOLE_PIN" ] && [ -n "$CONSOLE_SPKI" ]; then
  echo "ripty-install: RIPTY_HQ_SPKI needs RIPTY_HQ_PIN too (copy both from Add Station)"
  exit 2
fi
set -- --role connector --console-url "$CONSOLE_URL" --join-token "$JOIN_TOKEN"
PIN_OPTS=""
if [ -n "$CONSOLE_PIN" ]; then
  set -- "$@" --console-pin "$CONSOLE_PIN" --console-spki "$CONSOLE_SPKI"
  PIN_OPTS="-k --pinnedpubkey $CONSOLE_SPKI"
fi
if [ -n "$DNS_ZONE" ]; then
  set -- "$@" --dns-zone "$DNS_ZONE"
  # A cloud host answers with its private address unless it is told its public one.
  ANSWER_IP=$(curl -fsS --max-time 5 -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip)
  if printf '%s' "$ANSWER_IP" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
    set -- "$@" --dns-answer-ip "$ANSWER_IP"
  fi
fi
INSTALLER=/root/ripty-install.sh
# The token goes to curl on its stdin, so it is on no command line. A cut transfer (curl exit 18 or
# 56, which --retry does not retry) leaves a partial file, so curl's exit status is checked as well as
# the file.
if ! printf 'Authorization: Bearer %s\n' "$JOIN_TOKEN" | curl -fsS --retry 5 --retry-delay 10 --retry-connrefused $PIN_OPTS -H @- -o "$INSTALLER" "$CONSOLE_URL/connector/v1/install.sh" || [ ! -s "$INSTALLER" ]; then
  rm -f "$INSTALLER"
  echo "ripty-install: could not fetch the installer from $CONSOLE_URL/connector/v1/install.sh"
  exit 24
fi
bash "$INSTALLER" "$@"
STATUS=$?
rm -f "$INSTALLER"
echo "ripty-install: installer exit $STATUS"
if [ "$STATUS" -eq 0 ]; then
  (umask 077; : >"$DONE")
fi
exit $STATUS
EOF
}

# Print one gcloud command (dry run) or run it.
show() {
  local out=gcloud arg
  for arg in "$@"; do
    case "$arg" in
      '' | *[!A-Za-z0-9_@%+=:,./-]*) out="$out '$(printf '%s' "$arg" | sed "s/'/'\\\\''/g")'" ;;
      *) out="$out $arg" ;;
    esac
  done
  printf '%s\n' "$out"
}

gc() {
  if [ "$DRY_RUN" = 1 ]; then
    show "$@"
  else
    gcloud "$@"
  fi
}

STARTUP_FILE=startup-script.sh
if [ "$DRY_RUN" != 1 ]; then
  command -v gcloud >/dev/null 2>&1 || die "gcloud is not installed: run this in Google Cloud Shell"
  STARTUP_FILE=$(mktemp)
  trap 'rm -f "$STARTUP_FILE"' EXIT
  write_startup_script "$JOIN_TOKEN" >"$STARTUP_FILE"
fi

# Create a firewall rule, or keep the one an earlier run made: a rerun after a failed VM create (a zone
# out of capacity, say) must go on to the VM. A dry run asks gcloud nothing.
ensure_rule() { # ensure_rule RULE create-options...
  local rule=$1
  shift
  if [ "$DRY_RUN" != 1 ] && gcloud compute firewall-rules describe "$rule" --project "$PROJECT" >/dev/null 2>&1; then
    echo "Firewall rule $rule exists: kept."
    return 0
  fi
  gc compute firewall-rules create "$rule" --project "$PROJECT" "$@"
}

ensure_rule "$NAME-allow-station" --network "$NETWORK" \
  --direction INGRESS --action ALLOW --rules "$STATION_RULES" --source-ranges "$ALLOWED_CIDR" \
  --target-tags "$NAME" --description "Ripty Station: Meeting Sites and Signal Sites"
if [ -n "$DNS_ZONE" ]; then
  ensure_rule "$NAME-allow-dns" --network "$NETWORK" \
    --direction INGRESS --action ALLOW --rules "$DNS_RULES" --source-ranges "$ALLOWED_CIDR" \
    --target-tags "$NAME" --description "Ripty Station: DNS callback zone"
fi
if [ -n "$SSH_CIDR" ]; then
  ensure_rule "$NAME-allow-ssh" --network "$NETWORK" \
    --direction INGRESS --action ALLOW --rules "$SSH_RULES" --source-ranges "$SSH_CIDR" \
    --target-tags "$NAME" --description "Ripty Station: ssh"
fi

CREATE_ARGS=(compute instances create "$NAME" --project "$PROJECT" --zone "$ZONE"
  --machine-type "$MACHINE_TYPE" --image-family ubuntu-2404-lts-amd64 --image-project ubuntu-os-cloud
  --boot-disk-size 20GB --boot-disk-type pd-balanced --network "$NETWORK" --tags "$NAME"
  --no-service-account --no-scopes
  --metadata-from-file "startup-script=$STARTUP_FILE"
  --format 'value(name,networkInterfaces[0].accessConfigs[0].natIP)')
if [ -n "$SUBNET" ]; then
  CREATE_ARGS+=(--subnet "$SUBNET")
fi

if [ "$DRY_RUN" = 1 ]; then
  show "${CREATE_ARGS[@]}"
  echo "# $STARTUP_FILE, as the VM runs it (the join token is hidden here):"
  write_startup_script rtt_REDACTED | sed 's/^/# /'
  exit 0
fi

RESULT=$(gcloud "${CREATE_ARGS[@]}")
VM_NAME=
EXTERNAL_IP=
read -r VM_NAME EXTERNAL_IP <<<"$RESULT" || true
echo
echo "VM name:      ${VM_NAME:-$NAME}"
echo "External IP:  ${EXTERNAL_IP:-none (the VM has no external address)}"
echo
echo "The Station installs itself in a few minutes and then shows on the Fleet page in Headquarters."
echo "Headquarters must accept the Station channel (the port in RIPTY_HQ_URL) from the VM's address."
echo "The install log on the VM is /var/log/ripty-install.log."
echo "Once the Station shows up, remove the spent join token from the VM's metadata:"
echo "  gcloud compute instances remove-metadata $NAME --project $PROJECT --zone $ZONE --keys startup-script"
