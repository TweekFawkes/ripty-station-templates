# Terraform configurations for a Station

One self-contained configuration per cloud. Each one makes the same Station the AWS
CloudFormation template (`deploy/aws/ripty-connector.yaml`) makes: one Ubuntu 24.04 LTS server of
2 GiB of memory, a firewall that opens the Meeting Sites (80, 8080, 8000) and the Signal Sites
(22000 ssh, 33890 RDP) to `allowed_cidr`, and user data that downloads the installer from your
Headquarters, installs the Station and enrolls it with the join token.

| Directory | Cloud | Default size | Default region |
| --- | --- | --- | --- |
| `aws/` | AWS EC2 | `t3.small` | `us-east-1` |
| `azure/` | Azure VM | `Standard_B1ms` | `eastus` |
| `gcp/` | Google Cloud Compute Engine | `e2-small` | `us-central1` |
| `digitalocean/` | DigitalOcean droplet | `s-1vcpu-2gb` | `nyc3` |

Each directory holds `versions.tf` (pinned provider versions), `variables.tf`, `main.tf` and
`outputs.tf`. They run on Terraform 1.5.7 or later and on OpenTofu; use `tofu` for `terraform` below
if you prefer it. The lock file is not committed: `init` writes it.

## Use one

1. In Headquarters, choose Add Station, answer the questions and choose Generate.
2. On the Templates list, download the Terraform entry for your cloud and the values file for this
   Station. The entry is a `.zip` that holds this README and the cloud's directory (`aws/`,
   `azure/`, `gcp/` or `digitalocean/`); unzip it and run the commands below beside this README.
   The values file is `station.auto.tfvars`.
   Terraform reads any `*.auto.tfvars` file in the directory on its own, so you do not pass
   `-var-file`. Keep it out of source control: it holds the join token.
3. Put the values file in the cloud's directory, sign in to the cloud (see the table below), and run:

```
terraform -chdir=aws init
terraform -chdir=aws apply
```

4. The Station shows on the Stations page a few minutes after `apply` ends. The first start
   downloads uv and the Python packages. The install log on the server is `/var/log/ripty-install.log`.
   `apply` prints `instance_id`, `public_ip` and `private_ip`.

The join token works once and expires after one day. Terraform keeps it in the state file and in the
server's user data until it is spent, so keep the state private. If the token expired, create a new
join command in Headquarters and run `apply` again with the new values file: new user data replaces
the server on all four clouds. To replace the server without a change, use
`terraform apply -replace=<resource address>` (`aws_instance.station`,
`azurerm_linux_virtual_machine.station`, `google_compute_instance.station` or
`digitalocean_droplet.station`).

## Variables

Every configuration takes these. The values file fills the first five.

| Variable | Default | Meaning |
| --- | --- | --- |
| `console_url` | none | The Station address of Headquarters, for example `https://203.0.113.7:12199`. |
| `join_token` | none | The join token from Add Station (`sensitive`). |
| `console_pin`, `console_spki` | empty | The certificate pin and public key pin from Add Station. Set both or neither. |
| `dns_zone` | empty | A DNS callback zone. When set, the firewall also opens UDP and TCP port 53. |
| `region` | per cloud | The cloud's region. |
| `instance_size` | per cloud | The server size. Keep at least 2 GiB of memory: the installer warns below 1.5 GiB. The Station binary is linux-x64, so use an x86_64 size. |
| `ssh_public_key` | empty | An SSH public key. Empty means no key pair. |
| `allowed_cidr` | `0.0.0.0/0` | Who may reach the Station's ports. The default faces whoever can reach the server, like a default install. For an internal deception host, narrow it. |
| `ssh_cidr` | empty | Who may SSH in on port 22. There is no SSH rule unless `ssh_public_key` and `ssh_cidr` are both set. |
| `station_name` | `ripty-station` | The name of the resources. Change it to run a second Station in one account, subscription or project. |

Extra variables, one cloud each:

| Cloud | Variable | Meaning |
| --- | --- | --- |
| AWS | `subnet_id` | A subnet for the server. Empty uses the first default-VPC subnet in a zone that offers `instance_size`. |
| Azure | `subscription_id` | The subscription. Empty uses `ARM_SUBSCRIPTION_ID` or the `az login` subscription. |
| Google Cloud | `project_id` | The project. Empty uses `GOOGLE_PROJECT`. Infrastructure Manager needs it set. |
| DigitalOcean | `ssh_key_name` | The name of an SSH key already in the account, used in place of `ssh_public_key`. It counts as the key for the SSH rule. |

`console_url`, `join_token`, `console_pin`, `console_spki` and `dns_zone` are checked against the
patterns Add Station produces. That check keeps a quote or shell character out of the user data.

## Sign in to the cloud

| Cloud | Sign in |
| --- | --- |
| AWS | The usual AWS credentials: `aws configure`, `AWS_PROFILE`, or `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`. |
| Azure | `az login`, and `export ARM_SUBSCRIPTION_ID=<id>` (or set `subscription_id`). |
| Google Cloud | `gcloud auth application-default login`, and `export GOOGLE_PROJECT=<project id>` (or set `project_id`). The project needs the Compute Engine API on. |
| DigitalOcean | `export DIGITALOCEAN_TOKEN=<a token with read and write scope>`. |

Notes by cloud:

- **AWS.** The server takes a public IPv4 address. For an internal host in a private subnet, use the
  CloudFormation template, which has `AssignPublicIp`. The AMI is read from Canonical's public SSM
  parameter when the server is made. Terraform ignores later AMI releases, so a later `apply` does
  not replace an enrolled Station.
- **Azure.** Azure needs an SSH key on every Linux VM. With `ssh_public_key` empty, Terraform makes a
  throwaway key (its private half is in the state, and nothing uses it), so the VM still comes up
  with no SSH rule. The `ripty` user is the admin user.
- **Google Cloud.** The VM goes in the first available zone of `region`. It gets an ephemeral public
  address. Compute Engine runs a startup script at every boot, so the script stops at once after an
  install that succeeded (it leaves `/var/lib/ripty-install.done`).
- **DigitalOcean.** DigitalOcean refuses to add a key that is already in the account ("SSH Key is
  already in use on your account"), so for such a key set `ssh_key_name` to its name in the account
  (`doctl compute ssh-key list`) and leave `ssh_public_key` empty; Terraform reads the key and adds
  nothing. Use `ssh_public_key` only for a key the account does not have yet. With neither set,
  DigitalOcean emails the account owner a root password. The cloud firewall is part of the
  configuration.

When `dns_zone` is set, the user data also passes the server's public address to the installer as the
DNS answer address (AWS, Google Cloud and DigitalOcean read it from the metadata service; Azure writes
in the address of its static public IP). See `docs/dns-station.md` for the
records the zone needs.

## Google Cloud Infrastructure Manager

Google's Infrastructure Manager runs Terraform for you, and replaces Deployment Manager. `gcp/` runs
there as it is: it needs Terraform 1.5.7 and the `google` provider only. Checked against Google's
reference for `gcloud infra-manager deployments apply` on 2026-11-04; run
`gcloud infra-manager deployments apply --help` if a flag has moved.

1. Turn on the API and make a service account for the deployment. It needs `roles/config.agent` and
   the Compute Engine roles that create a network, a firewall and a VM (for example
   `roles/compute.admin`):

```
gcloud services enable config.googleapis.com compute.googleapis.com --project=PROJECT_ID
gcloud iam service-accounts create ripty-station-deployer --project=PROJECT_ID
gcloud projects add-iam-policy-binding PROJECT_ID \
  --member=serviceAccount:ripty-station-deployer@PROJECT_ID.iam.gserviceaccount.com \
  --role=roles/config.agent
gcloud projects add-iam-policy-binding PROJECT_ID \
  --member=serviceAccount:ripty-station-deployer@PROJECT_ID.iam.gserviceaccount.com \
  --role=roles/compute.admin
```

2. Make one inputs file from the Station's values and the project. Infrastructure Manager takes
   `--inputs-file` (a `.tfvars` file) or `--input-values`, never both:

```
cp station.auto.tfvars inputs.tfvars
printf 'project_id = "PROJECT_ID"\n' >> inputs.tfvars
```

3. Create the deployment from the `gcp/` directory:

```
gcloud infra-manager deployments apply \
  projects/PROJECT_ID/locations/us-central1/deployments/ripty-station \
  --service-account=projects/PROJECT_ID/serviceAccounts/ripty-station-deployer@PROJECT_ID.iam.gserviceaccount.com \
  --local-source=gcp \
  --inputs-file=inputs.tfvars
```

The `locations/us-central1` part is where Infrastructure Manager keeps the deployment; the VM's
region is `region` in the inputs file. Read the outputs with
`gcloud infra-manager deployments describe projects/PROJECT_ID/locations/us-central1/deployments/ripty-station`.
Remove the Station with `gcloud infra-manager deployments delete` on the same path. The inputs file
holds the join token: delete it once the Station has enrolled.

## Remove a Station

`terraform destroy` in the same directory removes the server and its firewall. Then remove the
Station on its page in Headquarters.
