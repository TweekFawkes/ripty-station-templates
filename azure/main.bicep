// Ripty Station on one Azure virtual machine. The VM installs the Station from your Headquarters
// (the installer Headquarters serves at /connector/v1/install.sh), starts it, and enrolls it with the
// join token. Add Station in Headquarters prints the value for every parameter below.
//
// This file is the source. azuredeploy.json is its compiled output, committed beside it; the command
// that rebuilds it is in README.md.

@description('The Station address of Headquarters, for example https://203.0.113.7:12199, with no trailing slash. The VM must reach it on that port, and the address must be one the VM can resolve and dial.')
@minLength(9)
@maxLength(300)
param consoleUrl string

@description('The join token from Add Station (rtt_ plus 43 characters). It works once and expires after one day; enrollment spends it. Create a new join command in Headquarters if it has expired.')
@secure()
@minLength(47)
@maxLength(47)
param joinToken string

@description('The certificate pin from Add Station (sha256: plus 64 hex digits). Leave empty when the Station address of Headquarters has a public certificate. Set it together with consoleSpki.')
@maxLength(71)
param consolePin string = ''

@description('The public key pin from Add Station (sha256// plus 43 characters and an equals sign). Leave empty when consolePin is empty. Set it together with consolePin.')
@maxLength(52)
param consoleSpki string = ''

@description('Optional. The DNS zone this Station answers for (a DNS Station, for Synthetic Markers). When set, the network security group also opens UDP and TCP port 53 to allowedCidr. Leave empty for no DNS Station.')
@maxLength(253)
param dnsZone string = ''

@description('The SSH public key for the admin user, for example the contents of ~/.ssh/id_ed25519.pub. The VM takes no password.')
@minLength(32)
param adminSshPublicKey string

@description('The admin user on the VM. It logs in with adminSshPublicKey.')
@minLength(1)
@maxLength(32)
param adminUsername string = 'azureuser'

@description('Who may reach the Meeting Sites on ports 80, 8080 and 8000 and the Signal Sites on 22000 (ssh) and 33890 (RDP): an IPv4 CIDR range, or * for anyone. The default, *, faces whoever can reach the host, like a default install. For an internal deception host, narrow it to your internal ranges.')
param allowedCidr string = '*'

@description('Optional. The range allowed to SSH in (port 22), an IPv4 CIDR range. There is no SSH rule when this is empty.')
param sshCidr string = ''

@description('An x86_64 size. The Station binary is linux-x64 only. Standard_B1s has one vCPU and 1 GiB of memory, the minimum for a Station; the installer adds a 1 GiB swap file on a host that small.')
@allowed([
  'Standard_B1s'
  'Standard_B1ms'
  'Standard_B2s'
  'Standard_B2ms'
  'Standard_D2s_v5'
])
param vmSize string = 'Standard_B1s'

@description('The Azure region. Defaults to the resource group\'s.')
param location string = resourceGroup().location

var name = 'ripty-station'
var hasSshRule = !empty(sshCidr)
var hasDns = !empty(dnsZone)

var stationRule = {
  name: 'ripty-station-ports'
  properties: {
    priority: 100
    direction: 'Inbound'
    access: 'Allow'
    protocol: 'Tcp'
    sourceAddressPrefix: allowedCidr
    sourcePortRange: '*'
    destinationAddressPrefix: '*'
    destinationPortRanges: ['80', '8080', '8000', '22000', '33890']
  }
}
var sshRule = {
  name: 'ripty-ssh'
  properties: {
    priority: 110
    direction: 'Inbound'
    access: 'Allow'
    protocol: 'Tcp'
    sourceAddressPrefix: sshCidr
    sourcePortRange: '*'
    destinationAddressPrefix: '*'
    destinationPortRange: '22'
  }
}
var dnsRule = {
  name: 'ripty-dns'
  properties: {
    priority: 120
    direction: 'Inbound'
    access: 'Allow'
    protocol: '*'
    sourceAddressPrefix: allowedCidr
    sourcePortRange: '*'
    destinationAddressPrefix: '*'
    destinationPortRange: '53'
  }
}
var securityRules = concat([stationRule], hasSshRule ? [sshRule] : [], hasDns ? [dnsRule] : [])

// The values reach the script as base64, so a value with a quote or any other shell character cannot
// change the script. The token is a secure parameter: the deployment history does not show it.
var installScript = join(
  [
    '#!/bin/bash'
    'CONSOLE_URL_B64="${base64(consoleUrl)}"'
    'JOIN_TOKEN_B64="${base64(joinToken)}"'
    'CONSOLE_PIN_B64="${base64(consolePin)}"'
    'CONSOLE_SPKI_B64="${base64(consoleSpki)}"'
    'DNS_ZONE_B64="${base64(dnsZone)}"'
    '''
# Installs the Station from Headquarters and enrolls it. The log is /var/log/ripty-install.log.
(umask 077; : >>/var/log/ripty-install.log)
exec >>/var/log/ripty-install.log 2>&1
echo "ripty-install: start $(date -u +%Y-%m-%dT%H:%M:%SZ)"
CONSOLE_URL=$(printf '%s' "$CONSOLE_URL_B64" | base64 -d)
JOIN_TOKEN=$(printf '%s' "$JOIN_TOKEN_B64" | base64 -d)
CONSOLE_PIN=$(printf '%s' "$CONSOLE_PIN_B64" | base64 -d)
CONSOLE_SPKI=$(printf '%s' "$CONSOLE_SPKI_B64" | base64 -d)
DNS_ZONE=$(printf '%s' "$DNS_ZONE_B64" | base64 -d)
if [ -n "$CONSOLE_PIN" ] && [ -z "$CONSOLE_SPKI" ]; then
  echo "ripty-install: consolePin needs consoleSpki too (copy both from Add Station)"
  exit 2
fi
if [ -z "$CONSOLE_PIN" ] && [ -n "$CONSOLE_SPKI" ]; then
  echo "ripty-install: consoleSpki needs consolePin too (copy both from Add Station)"
  exit 2
fi
set -- --role connector --console-url "$CONSOLE_URL" --join-token "$JOIN_TOKEN"
CURL_CONFIG=/root/ripty-curl.conf
(umask 077; : >"$CURL_CONFIG")
if [ -n "$CONSOLE_PIN" ]; then
  set -- "$@" --console-pin "$CONSOLE_PIN" --console-spki "$CONSOLE_SPKI"
  printf 'insecure\npinnedpubkey = "%s"\n' "$CONSOLE_SPKI" >"$CURL_CONFIG"
fi
if [ -n "$DNS_ZONE" ]; then
  set -- "$@" --dns-zone "$DNS_ZONE"
fi
INSTALLER=/root/ripty-install.sh
# The token goes to curl on its stdin, so it is on no command line. A cut transfer leaves a partial
# file, so curl's exit status is checked as well as the file. Six tries, ten seconds apart.
TRY=0
while :; do
  if printf 'Authorization: Bearer %s\n' "$JOIN_TOKEN" | curl -fsS -K "$CURL_CONFIG" -H @- -o "$INSTALLER" "$CONSOLE_URL/connector/v1/install.sh" && [ -s "$INSTALLER" ]; then
    break
  fi
  TRY=$((TRY + 1))
  if [ "$TRY" -ge 6 ]; then
    rm -f "$INSTALLER" "$CURL_CONFIG"
    echo "ripty-install: could not fetch the installer from $CONSOLE_URL/connector/v1/install.sh"
    exit 24
  fi
  sleep 10
done
rm -f "$CURL_CONFIG"
bash "$INSTALLER" "$@"
STATUS=$?
rm -f "$INSTALLER"
echo "ripty-install: installer exit $STATUS"
exit $STATUS
'''
  ],
  '\n'
)

resource network 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: '${name}-vnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: ['10.60.0.0/24']
    }
    subnets: [
      {
        name: 'default'
        properties: {
          addressPrefix: '10.60.0.0/26'
        }
      }
    ]
  }
}

resource securityGroup 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: '${name}-nsg'
  location: location
  properties: {
    securityRules: securityRules
  }
}

resource publicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: '${name}-ip'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: '${name}-nic'
  location: location
  properties: {
    networkSecurityGroup: {
      id: securityGroup.id
    }
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: network.properties.subnets[0].id
          }
          publicIPAddress: {
            id: publicIp.id
          }
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: name
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: 'ubuntu-24_04-lts'
        sku: 'server'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        deleteOption: 'Delete'
        diskSizeGB: 30
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
    }
    osProfile: {
      computerName: name
      adminUsername: adminUsername
      customData: base64(installScript)
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: adminSshPublicKey
            }
          ]
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
          properties: {
            deleteOption: 'Delete'
          }
        }
      ]
    }
  }
}

@description('The virtual machine. It shows on the Stations page once it enrolls.')
output vmName string = vm.name

@description('The VM\'s public IPv4 address.')
output publicIpAddress string = publicIp.properties.ipAddress

@description('The VM\'s private IPv4 address.')
output privateIpAddress string = nic.properties.ipConfigurations[0].properties.privateIPAddress
