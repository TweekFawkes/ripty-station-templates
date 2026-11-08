#!/usr/bin/env bash
# Puts a Ripty Station on one DigitalOcean droplet, and a cloud firewall around it, with doctl.
#
# The droplet installs the Station from your Headquarters at its first boot and enrolls it with the
# join token. The firewall opens the same ports as the AWS template (deploy/aws/ripty-connector.yaml).
# The values come from Add Station in Headquarters; its "Download values" button on this template
# writes them as station.env. Load that file, then run the script:
#
#   set -a; . ./station.env; set +a
#   bash deploy.sh --dry-run
#   bash deploy.sh
#
# Environment (RIPTY_HQ_URL and RIPTY_JOIN_TOKEN are required):
#   RIPTY_HQ_URL       the Station address of Headquarters, https://HOST:PORT, no trailing slash
#   RIPTY_JOIN_TOKEN   the one-time token from Add Station (works once, expires after one day)
#   RIPTY_HQ_PIN       certificate pin, sha256: and 64 hex digits; set it together with RIPTY_HQ_SPKI
#   RIPTY_HQ_SPKI      public key pin, sha256// and 43 characters and an equals sign
#   RIPTY_DNS_ZONE     optional; makes the Station a DNS Station for this zone and opens port 53
#
# Options:
#   --region SLUG      droplet region (default nyc3)
#   --size SLUG        droplet size (default s-1vcpu-2gb: 2 GiB, like the AWS template's t3.small)
#   --name NAME        droplet name, and the tag the firewall attaches to (default ripty-station)
#   --ssh-key KEY      optional; the ID or fingerprint of a DigitalOcean SSH key for the root account
#   --allowed-cidr C   who may reach the Station's ports (default 0.0.0.0/0, like a default install)
#   --ssh-cidr C       optional; who may SSH in (port 22). No SSH rule unless --ssh-key is set too
#   --dry-run          print the doctl commands and the user data (token hidden); change nothing
#   -h, --help         this text
#
# Needs doctl, logged in (doctl auth init). The script is for bash 3.2 and later.

set -euo pipefail

die() {
	echo "deploy.sh: $*" >&2
	exit 2
}

usage() {
	sed -n '2,/^# Needs doctl/p' "$0" | sed 's/^# \{0,1\}//; s/^#$//'
}

REGION=nyc3
SIZE=s-1vcpu-2gb
IMAGE=ubuntu-24-04-x64
NAME=ripty-station
SSH_KEY=""
ALLOWED_CIDR=0.0.0.0/0
SSH_CIDR=""
DRY_RUN=0

set_option() {
	case "$1" in
	--region) REGION=$2 ;;
	--size) SIZE=$2 ;;
	--name) NAME=$2 ;;
	--ssh-key) SSH_KEY=$2 ;;
	--allowed-cidr) ALLOWED_CIDR=$2 ;;
	--ssh-cidr) SSH_CIDR=$2 ;;
	esac
}

while [ "$#" -gt 0 ]; do
	case "$1" in
	--region | --size | --name | --ssh-key | --allowed-cidr | --ssh-cidr)
		[ "$#" -ge 2 ] || die "$1 needs a value"
		set_option "$1" "$2"
		shift 2
		;;
	--region=* | --size=* | --name=* | --ssh-key=* | --allowed-cidr=* | --ssh-cidr=*)
		set_option "${1%%=*}" "${1#*=}"
		shift
		;;
	--dry-run)
		DRY_RUN=1
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*) die "unknown option: $1 (try --help)" ;;
	esac
done

HQ_URL=${RIPTY_HQ_URL:-}
JOIN_TOKEN=${RIPTY_JOIN_TOKEN:-}
HQ_PIN=${RIPTY_HQ_PIN:-}
HQ_SPKI=${RIPTY_HQ_SPKI:-}
DNS_ZONE=${RIPTY_DNS_ZONE:-}

# The values go into the user data between single quotes, so each is checked first. The patterns are
# the AWS template's AllowedPattern ones, written as extended regular expressions.
URL_RE='^https://[]A-Za-z0-9._~:/[-]*[]A-Za-z0-9._~:[-]$'
TOKEN_RE='^rtt_[A-Za-z0-9_-]{43}$'
PIN_RE='^sha256:[0-9a-f]{64}$'
SPKI_RE='^sha256//[A-Za-z0-9+/]{43}=$'
ZONE_RE='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'
CIDR_RE='^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$'
SLUG_RE='^[a-z0-9][a-z0-9-]{0,62}$'
NAME_RE='^[A-Za-z0-9][A-Za-z0-9-]{0,62}$'
KEY_RE='^[A-Za-z0-9:.-]{1,100}$'

[ -n "$HQ_URL" ] || die "RIPTY_HQ_URL is not set (the Station address from Add Station)"
[ -n "$JOIN_TOKEN" ] || die "RIPTY_JOIN_TOKEN is not set (the join token from Add Station)"
[[ $HQ_URL =~ $URL_RE ]] || die "RIPTY_HQ_URL must be an https address with no trailing slash"
[[ $JOIN_TOKEN =~ $TOKEN_RE ]] || die "RIPTY_JOIN_TOKEN must be rtt_ followed by 43 characters"
if [ -n "$HQ_PIN" ] && [ -z "$HQ_SPKI" ]; then
	die "RIPTY_HQ_PIN needs RIPTY_HQ_SPKI too (copy both from Add Station)"
fi
if [ -z "$HQ_PIN" ] && [ -n "$HQ_SPKI" ]; then
	die "RIPTY_HQ_SPKI needs RIPTY_HQ_PIN too (copy both from Add Station)"
fi
if [ -n "$HQ_PIN" ]; then
	[[ $HQ_PIN =~ $PIN_RE ]] || die "RIPTY_HQ_PIN must be sha256: and 64 lowercase hex digits"
	[[ $HQ_SPKI =~ $SPKI_RE ]] || die "RIPTY_HQ_SPKI must be sha256// and 43 characters and ="
fi
if [ -n "$DNS_ZONE" ]; then
	[[ $DNS_ZONE =~ $ZONE_RE ]] || die "RIPTY_DNS_ZONE must be a lowercase zone name, e.g. oob.example.com"
fi
[[ $REGION =~ $SLUG_RE ]] || die "--region must be a region slug such as nyc3"
[[ $SIZE =~ $SLUG_RE ]] || die "--size must be a size slug such as s-1vcpu-2gb"
[[ $NAME =~ $NAME_RE ]] || die "--name may hold letters, digits and hyphens only"
[[ $ALLOWED_CIDR =~ $CIDR_RE ]] || die "--allowed-cidr must be an IPv4 CIDR range such as 10.0.0.0/8"
if [ -n "$SSH_CIDR" ]; then
	[[ $SSH_CIDR =~ $CIDR_RE ]] || die "--ssh-cidr must be an IPv4 CIDR range"
fi
if [ -n "$SSH_KEY" ]; then
	[[ $SSH_KEY =~ $KEY_RE ]] || die "--ssh-key must be a DigitalOcean SSH key ID or fingerprint"
fi
if [ -n "$SSH_KEY" ] && [ -z "$SSH_CIDR" ]; then
	echo "deploy.sh: note: --ssh-key without --ssh-cidr, so the firewall keeps port 22 closed" >&2
fi
if [ -z "$SSH_KEY" ] && [ -n "$SSH_CIDR" ]; then
	echo "deploy.sh: note: --ssh-cidr without --ssh-key, so there is no SSH rule" >&2
fi

# The user data: the AWS template's install script, with the values filled in.
IFS= read -r -d '' USER_DATA_TEMPLATE <<'USERDATA' || true
#!/bin/bash
# Installs the Station from Headquarters and enrolls it. The log is /var/log/ripty-install.log.
# The values were checked before this file was made, so they hold no quote or shell character.
(umask 077; : >>/var/log/ripty-install.log)
exec >>/var/log/ripty-install.log 2>&1
echo "ripty-install: start $(date -u +%Y-%m-%dT%H:%M:%SZ)"
CONSOLE_URL='@HQ_URL@'
JOIN_TOKEN='@JOIN_TOKEN@'
CONSOLE_PIN='@HQ_PIN@'
CONSOLE_SPKI='@HQ_SPKI@'
DNS_ZONE='@DNS_ZONE@'
set -- --role connector --hq-url "$CONSOLE_URL" --join-token "$JOIN_TOKEN"
PIN_OPTS=""
if [ -n "$CONSOLE_PIN" ]; then
  set -- "$@" --hq-pin "$CONSOLE_PIN" --hq-spki "$CONSOLE_SPKI"
  PIN_OPTS="-k --pinnedpubkey $CONSOLE_SPKI"
fi
if [ -n "$DNS_ZONE" ]; then
  set -- "$@" --dns-zone "$DNS_ZONE"
fi
INSTALLER=/root/ripty-install.sh
# The token goes to curl on its stdin, so it is on no command line. A cut transfer
# (curl exit 18 or 56, which --retry does not retry) leaves a partial file, so curl's
# exit status is checked as well as the file.
if ! printf 'Authorization: Bearer %s\n' "$JOIN_TOKEN" | curl -fsS --retry 5 --retry-delay 10 --retry-connrefused $PIN_OPTS -H @- -o "$INSTALLER" "$CONSOLE_URL/connector/v1/install.sh" || [ ! -s "$INSTALLER" ]; then
  rm -f "$INSTALLER"
  echo "ripty-install: could not fetch the installer from $CONSOLE_URL/connector/v1/install.sh"
  exit 24
fi
bash "$INSTALLER" "$@"
STATUS=$?
rm -f "$INSTALLER"
echo "ripty-install: installer exit $STATUS"
exit $STATUS
USERDATA

# render TOKEN: the user data with the values filled in and TOKEN as the join token.
render() {
	local text=$USER_DATA_TEMPLATE
	text=${text//@HQ_URL@/$HQ_URL}
	text=${text//@JOIN_TOKEN@/$1}
	text=${text//@HQ_PIN@/$HQ_PIN}
	text=${text//@HQ_SPKI@/$HQ_SPKI}
	text=${text//@DNS_ZONE@/$DNS_ZONE}
	printf '%s' "$text"
}

# The Station's ports, as in the AWS security group (deploy/aws/ripty-connector.yaml): the Meeting
# Sites on 80, 8080 and 8000, and the Signal Sites on 22000 (ssh) and 33890 (RDP).
STATION_PORTS="80 8080 8000 22000 33890"
INBOUND=""
for port in $STATION_PORTS; do
	INBOUND="$INBOUND protocol:tcp,ports:$port,address:$ALLOWED_CIDR"
done
# A DNS Station answers resolvers anywhere, so port 53 is open to everyone when the zone is set.
if [ -n "$DNS_ZONE" ]; then
	INBOUND="$INBOUND protocol:udp,ports:53,address:0.0.0.0/0 protocol:tcp,ports:53,address:0.0.0.0/0"
fi
# The SSH rule exists only when both an SSH key and a range are given, as in the AWS template.
if [ -n "$SSH_KEY" ] && [ -n "$SSH_CIDR" ]; then
	INBOUND="$INBOUND protocol:tcp,ports:22,address:$SSH_CIDR"
fi
INBOUND=${INBOUND# }
# A DigitalOcean cloud firewall denies all outbound traffic that no rule allows, unlike the AWS
# security group. The droplet must reach Headquarters, the installer's downloads and DNS.
OUTBOUND="protocol:tcp,ports:all,address:0.0.0.0/0 protocol:udp,ports:all,address:0.0.0.0/0 protocol:icmp,address:0.0.0.0/0"

# show WORDS...: one command line, quoted so that it can be pasted.
show() {
	local word out=""
	for word in "$@"; do
		case $word in
		'' | *[!A-Za-z0-9_./:,=@%+-]*) out="$out '$word'" ;;
		*) out="$out $word" ;;
		esac
	done
	printf '%s\n' "${out# }"
}

USER_DATA_FILE=station-user-data.sh
if [ "$DRY_RUN" -eq 0 ]; then
	command -v doctl >/dev/null 2>&1 || die "doctl is not installed (https://docs.digitalocean.com/reference/doctl/how-to/install/)"
	USER_DATA_FILE=$(mktemp "${TMPDIR:-/tmp}/ripty-station-user-data.XXXXXX")
	trap 'rm -f "$USER_DATA_FILE"' EXIT
	render "$JOIN_TOKEN" >"$USER_DATA_FILE"
fi

DROPLET_CMD=(doctl compute droplet create "$NAME" --image "$IMAGE" --size "$SIZE" --region "$REGION"
	--user-data-file "$USER_DATA_FILE" --tag-names "$NAME" --wait
	--format ID,Name,PublicIPv4,Region,Status)
if [ -n "$SSH_KEY" ]; then
	DROPLET_CMD+=(--ssh-keys "$SSH_KEY")
fi
FIREWALL_CMD=(doctl compute firewall create --name "$NAME-fw" --tag-names "$NAME"
	--inbound-rules "$INBOUND" --outbound-rules "$OUTBOUND" --format ID,Name,Status)

if [ "$DRY_RUN" -eq 1 ]; then
	echo "# Dry run: nothing is created. The first lines make the user data file a real run writes to a"
	echo "# private temporary file. The join token is hidden here."
	echo "cat >$USER_DATA_FILE <<'USERDATA'"
	render "rtt_<hidden>"
	echo "USERDATA"
	show "${DROPLET_CMD[@]}"
	show "${FIREWALL_CMD[@]}"
	exit 0
fi

echo "deploy.sh: creating droplet $NAME ($SIZE, $REGION)" >&2
"${DROPLET_CMD[@]}"
echo "deploy.sh: creating firewall $NAME-fw for the tag $NAME" >&2
if ! "${FIREWALL_CMD[@]}"; then
	echo "deploy.sh: the droplet exists but the firewall was not created: it is open to everyone." >&2
	echo "deploy.sh: fix the error above and run the second doctl command by hand, or delete the droplet." >&2
	exit 1
fi
echo "deploy.sh: done. The Station installs at first boot and shows on the Stations page in a few minutes."
echo "deploy.sh: its log is /var/log/ripty-install.log on the droplet."
# A zone set later from Headquarters needs port 53 too, and only the zone given here opens it (ticket 001185).
if [ -z "$DNS_ZONE" ]; then
	echo "deploy.sh: note: port 53 is closed. To make this a DNS Station later from Headquarters, open UDP and TCP 53 first:" >&2
	echo "deploy.sh:   doctl compute firewall add-rules FIREWALL_ID --inbound-rules 'protocol:udp,ports:53,address:0.0.0.0/0 protocol:tcp,ports:53,address:0.0.0.0/0'" >&2
	echo "deploy.sh: (FIREWALL_ID is the ID printed for $NAME-fw above; doctl compute firewall list shows it again)." >&2
fi
