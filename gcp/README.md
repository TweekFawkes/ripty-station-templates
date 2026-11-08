# Ripty Station on Google Cloud

These files put one Ripty Station on a Google Compute Engine VM. They hold no secret: the join
token and the other values come from Add Station in Headquarters when you run them.

| File | What it is |
| --- | --- |
| `deploy.sh` | A Bash script that makes the firewall rules and the VM with `gcloud`. |
| `tutorial.md` | A Google Cloud Shell tutorial that walks through the script. |
| `station-templates.json` | The list Headquarters reads to offer these files. |

## Open in Cloud Shell

After Generate in Add Station, the quick-launch row shows **Open in Cloud Shell**. It opens
Google Cloud Shell on the public repository that holds these files, at the tag for your
Headquarters' version, with `tutorial.md` beside the terminal. The link names no value: you
paste the Station's values into the terminal, so the join token never goes into a URL.

Cloud Shell opens a repository Google does not own in a temporary session, and it asks you to
confirm that you trust the repository. That session has no sign-in of yours: if `gcloud` says it
has no credentialed account, run `gcloud auth login`.

## Run the script yourself

Use Cloud Shell, or any shell where `gcloud` is signed in:

```bash
set -a; source station.env; set +a      # station.env: Download values on the Templates list
bash deploy.sh --project my-project --dry-run
bash deploy.sh --project my-project
```

The script reads five values from the environment. Each has a flag of the same name too, but a
flag stays in shell history, so prefer the variable.

| Variable | Value |
| --- | --- |
| `RIPTY_HQ_URL` | The Station address of Headquarters, for example `https://203.0.113.7:12199`. |
| `RIPTY_JOIN_TOKEN` | The join token. It works once and expires after one day. |
| `RIPTY_HQ_PIN` | The certificate pin. Empty when Headquarters has a public certificate. |
| `RIPTY_HQ_SPKI` | The public key pin. Set it with `RIPTY_HQ_PIN`. |
| `RIPTY_DNS_ZONE` | Optional. A DNS callback zone; the script then opens DNS (port 53) too. |

Options: `--project`, `--zone` (default `us-central1-a`), `--machine-type` (default `e2-small`,
2 GB of memory, the size of the AWS template's default), `--allowed-cidr` (default `0.0.0.0/0`),
`--ssh-cidr` (no ssh rule without it), `--network`, `--subnet`, `--name` and `--dry-run`.

What it makes, matching `deploy/aws/ripty-connector.yaml`:

- A firewall rule, on a network tag named after the VM, that opens the Meeting Sites (80, 8080,
  8000) and the Signal Sites (ssh on 22000, RDP on 33890) to `--allowed-cidr`. The default,
  `0.0.0.0/0`, faces whoever can reach the host, like a default install.
- An ssh rule (port 22) only when you pass `--ssh-cidr`, and a DNS rule (port 53) only when you set a
  DNS zone.
- An Ubuntu 24.04 LTS VM with a 20 GB disk and an external address. Its startup script runs the
  installer that Headquarters serves at `/connector/v1/install.sh`, as root and with no prompt, with
  the same flags as the AWS template. It writes `/var/log/ripty-install.log` and a marker file, so a
  reboot does not run the install a second time.

A rule that already exists is kept, so a run that stopped before the VM (a zone with no free
capacity) can be run again. A VM name can exist only once: delete the old VM, or pass another
`--name`, to make a new one.

The VM must reach Headquarters' Station channel, and the Internet for the first start, which
downloads uv and the Python packages. Headquarters must accept the channel from the VM's address.
The script prints the VM's name and external IP.

The join token is in the VM's `startup-script` metadata until you remove it. It is spent when the
Station enrolls, so it is harmless then, but tidy:

```bash
gcloud compute instances remove-metadata ripty-station --zone us-central1-a --keys startup-script
```

## Deployment Manager

There is no Cloud Deployment Manager configuration here. Google ended support for Deployment
Manager on 2026-03-31 and no longer takes deployments with it. Its replacement is Infrastructure
Manager, which runs Terraform. Use the Google Cloud Terraform configuration in the Station
templates (the Terraform group): it runs under Infrastructure Manager as well as under `terraform`
and `tofu`.
