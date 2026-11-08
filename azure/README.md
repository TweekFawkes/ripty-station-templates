# Ripty Station on Azure

Puts one Station on one Azure virtual machine. The VM installs the Station from your Headquarters
(the installer Headquarters serves at `/connector/v1/install.sh`), starts it, and enrolls it with the
join token. Add Station in Headquarters lists these files under Templates after you choose Generate.

| File | What it is |
| --- | --- |
| `main.bicep` | The source. |
| `azuredeploy.json` | The ARM template compiled from `main.bicep`, committed. The Deploy to Azure button opens the hosted copy of this file. |
| `station-templates.json` | The manifest Headquarters reads to list the two templates above. |

Headquarters also builds a values file for the Station you added (`station.parameters.json`, an ARM
parameters file). It holds the join token, which works once and expires after one day, so keep it out
of source control. The template itself holds no secret.

## What it creates

All of it goes in the resource group you pick:

- A virtual network (`10.60.0.0/24`) with one subnet.
- A network security group. It allows inbound TCP 80, 8080 and 8000 (the Meeting Sites) and 22000 and
  33890 (the Signal Sites for ssh and RDP) from `allowedCidr`. It allows TCP 22 from `sshCidr` when
  `sshCidr` is set, and UDP and TCP 53 from `allowedCidr` when `dnsZone` is set. Azure's default rules
  allow outbound traffic, so the VM reaches Headquarters and the Internet.
- A static Standard public IPv4 address, a network interface, and one Ubuntu 24.04 LTS VM
  (`ripty-station`, size `Standard_B1s` by default, a 30 GB Standard SSD). It logs in by SSH key only.
  The VM, its disk and its network interface are deleted with it; delete the resource group to remove
  everything.

The VM's custom data runs the installer as root at first boot, with no prompt. The Station installs,
starts and enrolls itself, and shows on the Stations page a few minutes later. The log is
`/var/log/ripty-install.log`.

## Parameters

| Parameter | Default | Notes |
| --- | --- | --- |
| `consoleUrl` | none | The Station address of Headquarters, for example `https://203.0.113.7:12199`. |
| `joinToken` | none | `rtt_` plus 43 characters. A `secureString`, so the deployment history does not show it. |
| `consolePin`, `consoleSpki` | empty | The certificate pin and the public key pin from Add Station. Set both or neither. |
| `dnsZone` | empty | A DNS Station zone. Opens port 53 and passes `--dns-zone` to the installer. |
| `adminSshPublicKey` | none | Your SSH public key. The values file from Headquarters does not hold it; enter it yourself. |
| `adminUsername` | `azureuser` | The admin user the key belongs to. |
| `allowedCidr` | `*` | Who may reach the Meeting Sites and Signal Sites. `*` faces whoever can reach the host, like a default install. For an internal deception host, narrow it to your internal ranges. |
| `sshCidr` | empty | Who may SSH in. There is no SSH rule when it is empty. |
| `vmSize` | `Standard_B1s` | An x86_64 size: the Station binary is linux-x64. One vCPU and 1 GiB is the Station minimum (`docs/QUICKSTART.md`); the installer adds a 1 GiB swap file on a host with under 1.5 GiB. |
| `location` | the resource group's | The Azure region. |

The values reach the install script as base64, so a value with a quote or any other shell character
cannot change the script (Bicep has no pattern check like CloudFormation's `AllowedPattern`).

## Deploy from the portal

1. In Headquarters, finish Add Station and choose Generate. Under Templates, choose Deploy to Azure.
   The button shows only when the hosted copy of the template answers. Without it, download
   `azuredeploy.json` and use Build your own template in the editor on the portal's Custom deployment
   page instead.
2. Azure cannot prefill parameters from the link. On the custom deployment page choose Edit
   parameters, then Load file, and pick the downloaded `station.parameters.json`; or type the values
   Headquarters shows next to the button.
3. Choose a subscription and a resource group, enter `adminSshPublicKey`, then Review + create.

## Deploy from the command line

```
az group create --name ripty-station --location westus3
az deployment group create --resource-group ripty-station \
  --template-file azuredeploy.json \
  --parameters @station.parameters.json \
  --parameters adminSshPublicKey="$(cat ~/.ssh/id_ed25519.pub)"
```

## Network needs on your side

- Headquarters must accept the Station channel from the new VM. Add its public address (the
  `publicIpAddress` output) to Headquarters' firewall for the Station port.
- A DNS Station answers with the VM's private address by default. On Azure the public address is a
  separate resource, so give the installer `--dns-answer-ip <public address>` afterwards
  (`docs/dns-station.md`).
- The VM needs outbound Internet for the first start, which downloads uv and the Python packages.

## Rebuild `azuredeploy.json`

`azuredeploy.json` records the Bicep version that built it, so rebuild it with Bicep CLI 0.48.1
(`brew install azure/bicep/bicep`, or `az bicep install --version v0.48.1`):

```
bicep build deploy/azure/main.bicep --outfile deploy/azure/azuredeploy.json
```

To check that the committed file is current:

```
diff <(bicep build deploy/azure/main.bicep --stdout) deploy/azure/azuredeploy.json
```

`az bicep build --file deploy/azure/main.bicep --outfile deploy/azure/azuredeploy.json` does the same
with the Azure CLI's copy of Bicep. Check the template against a scratch resource group with
`az deployment group validate`, with the same `--template-file` and `--parameters` as the command
line deploy above.
