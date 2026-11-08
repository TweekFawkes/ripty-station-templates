# Pulumi programs for a Station

One Pulumi program per cloud. Each makes the same Station as the AWS CloudFormation template
(`deploy/aws/ripty-connector.yaml`): one small Ubuntu 24.04 LTS virtual machine with a public
address, firewall rules for the Meeting Sites and Signal Sites, and a startup script that installs
the Station from your Headquarters and enrolls it with the join token.

| Cloud | Directory | Default size | Credentials |
| --- | --- | --- | --- |
| AWS | `aws/` | `t3.small` (2 GiB) in `us-east-1` | the AWS CLI's credentials, or `AWS_PROFILE` |
| Azure | `azure/` | `Standard_B1ms` (2 GiB) in `eastus` | `az login` |
| Google Cloud | `gcp/` | `e2-small` (2 GB) in `us-central1` | `gcloud auth application-default login` and `pulumi config set gcp:project <id>` |
| DigitalOcean | `digitalocean/` | `s-1vcpu-2gb` in `nyc3` | `DIGITALOCEAN_TOKEN` |

The programs are Pulumi YAML (`runtime: yaml`), so you need the Pulumi CLI and nothing else: no
Node.js, Python or Go. Pulumi downloads the cloud's provider plugin by itself the first time.

## Use

1. In Headquarters, open Add Station, choose Generate, and find your cloud under Templates.
2. Choose Download template (a `.zip` with the program and this file) and unzip it.
3. Choose Download values: a `station-pulumi-config.sh` file that holds this Station's
   `pulumi config set` commands. The join token is set with `--secret`, so Pulumi stores it
   encrypted. The token works once and expires after one day, so do the next steps today.
4. In the cloud's directory, start a stack and run the values file:

   ```sh
   cd aws                                # or azure, gcp, digitalocean
   pulumi login --local                  # skip this line to use Pulumi Cloud
   pulumi stack init station
   sh ../station-pulumi-config.sh        # wherever you saved the values file
   pulumi up
   ```

5. The Station appears on the Stations page of Headquarters a few minutes after `pulumi up`
   ends, once the machine has booted and the installer has finished. The startup script logs to `/var/log/ripty-install.log` on the machine.

`pulumi destroy` removes the machine, the firewall and the network the program made. Remove the
Station in Headquarters as well.

## Configuration

Every program takes the same keys.

| Key | Required | Default | What it is |
| --- | --- | --- | --- |
| `consoleUrl` | yes | | The Station address of Headquarters, for example `https://203.0.113.7:12199`. |
| `joinToken` | yes, secret | | The join token from Add Station. |
| `consolePin` | no | empty | The certificate pin. Set it together with `consoleSpki`. |
| `consoleSpki` | no | empty | The public key pin. Set it together with `consolePin`. |
| `dnsZone` | no | empty | A callback zone. The Station then also answers DNS for it. |
| `region` | no | per cloud | The region. The machine goes in the first available zone of it. |
| `instanceSize` | no | per cloud | The machine size. Keep at least 2 GiB of memory and an x86_64 CPU. |
| `sshPublicKey` | Azure only | empty | An SSH public key line. |
| `allowedCidr` | no | `0.0.0.0/0` | Who may reach ports 80, 8080, 8000, 22000, 33890 and 53. |
| `sshCidr` | no | `192.0.2.1/32` | Who may reach port 22. |

Notes:

- Add Station's values file sets `consoleUrl`, `joinToken`, `consolePin`, `consoleSpki` and
  `dnsZone`. Set the rest yourself with `pulumi config set <key> <value>`.
- The default `allowedCidr` faces whoever can reach the host, like a default install. For an
  internal deception host, narrow it.
- A Pulumi YAML program has no conditions, so the SSH rule always exists. Its default range,
  `192.0.2.1/32`, is the documentation address nobody connects from: port 22 stays closed until you
  set `sshCidr`. Set `sshPublicKey` as well to be able to sign in (Azure requires a key).
- Port 53 is open to `allowedCidr` on every cloud, but nothing listens on it unless `dnsZone` is set.
- The join token also sits in the startup script, so it is in the machine's user data (visible to
  whoever can read the machine's metadata) until the Station spends it. Pulumi keeps the script
  encrypted in the stack state because the token is a secret.
- A new join token changes the startup script, and `pulumi up` then replaces the machine with a
  new Station. Set a new token only when you want that.
- Values must hold no single quote: the script puts them in single quotes. It also refuses a
  `consoleUrl` that is not an `https://` address or a `joinToken` that is not `rtt_` plus 43
  characters, and logs why.

## Per cloud

- **AWS.** The program uses the default VPC and the first default subnet the API lists in the
  region (any zone, so a region or account with no zone `a` works). An account with no default VPC
  needs the CloudFormation template, which takes a VPC and a subnet.
  The AMI is Canonical's Ubuntu 24.04, read from its public SSM parameter.
- **Azure.** The program makes a resource group, a virtual network, a public address and a network
  security group. `sshPublicKey` is required, for the user `azureuser`.
- **Google Cloud.** The program puts the machine in the first zone of the region that is up (read
  with `gcp:compute:getZones`, because not every region has a zone `a`). It makes its own network
  (not the `default` one) and three firewall rules for the instance's `ripty-station` tag. The
  startup script runs once: a marker file, `/var/lib/ripty-install.done`, stops a later boot from
  running it again.
- **DigitalOcean.** The firewall blocks everything it does not allow, so it also allows all
  outbound traffic (the Station downloads uv and the Python packages on its first start).

## What was checked

`pulumi preview` ran on each program (Pulumi CLI 3.274.0, local backend, throwaway credentials, the
provider plugins `aws` 7.53.0, `azure-native` 3.30.0, `gcp` 10.2.2 and `digitalocean` 4.84.2). The
engine accepted every resource type, every property and every config entry, and planned all the
resources: 3 on AWS (a security group, the instance and the provider), 7 on Azure, 5 on Google
Cloud, 3 on DigitalOcean. It did reject two things, both fixed: a `description` field on a config
entry (the YAML language host warns about any field but `type`, `default`, `secret`, `items`, `name`
and `value`, so the text is a comment above each key) and the Google Cloud firewall names (the
automatic name kept the capitals of the resource name, which Google Cloud refuses; each rule now has
a lowercase name that starts from the network's name).

## Not checked here

With dummy credentials, `pulumi preview` cannot call a cloud. The four data lookups
(`aws:ssm:getParameter`, `aws:ec2:getVpc`, `aws:ec2:getSubnets` and `gcp:compute:getZones`) did not
run: the AWS ones were checked only against the provider schema (their names, arguments and the
fields the program reads), and the Google Cloud one reached the provider, which accepted its
arguments and then failed on the credentials. The AWS and Google Cloud plans above ran with those
lookups replaced by fixed values. No `pulumi up` has run against a cloud, so the image names, the
machine sizes, a region's quota and the startup scripts on a real machine are untested. Run
`pulumi preview` with your own credentials first and report what it says.
