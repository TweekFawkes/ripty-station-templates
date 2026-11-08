# Ripty Station on Google Cloud

## Welcome

<walkthrough-tutorial-duration duration="10"></walkthrough-tutorial-duration>

This tutorial puts a Ripty Station on one Compute Engine VM. The script `deploy.sh` makes the
firewall rules and an Ubuntu 24.04 LTS VM. The VM installs the Station from your Headquarters,
starts it and enrolls it. You do not need ssh.

You need:

- A Google Cloud project with billing on.
- A Station you added in Headquarters: on the Stations page choose Add Station, answer the
  questions and choose Generate. Keep that page open.
- A network path from the VM to Headquarters: the Station dials the address Headquarters gave
  you, so that address must be one the VM can reach.

The join token on the Generate page works once and expires after one day. Do the steps below
within that day.

Choose **Start**.

## Pick the project

<walkthrough-project-setup billing="true"></walkthrough-project-setup>

Set the project for this terminal and turn on the Compute Engine API:

```bash
gcloud config set project <walkthrough-project-id/>
gcloud services enable compute.googleapis.com
```

If `gcloud` says it has no credentialed account, run `gcloud auth login` and follow the link it
prints. Cloud Shell opens a repository it does not know in a temporary session, which does not
carry your sign-in.

## Paste the values from Headquarters

On the Generate page of Add Station, find the Google Cloud row in the Templates list and choose
**Download values**. The file is `station.env`. Open it in any editor and copy its lines.

In the terminal below, run `set -a`, paste the lines, then run `set +a`:

```bash
set -a
```

Paste the lines of `station.env` here. They look like `RIPTY_HQ_URL='https://...'` and
`RIPTY_JOIN_TOKEN='rtt_...'`. A pin (`RIPTY_HQ_PIN` and `RIPTY_HQ_SPKI`) and a DNS callback zone
(`RIPTY_DNS_ZONE`) are in the file only when you set them for this Station.

```bash
set +a
```

The values stay in this terminal session only. The join token is a secret until it is spent, so
keep `station.env` out of source control and delete it when you are done.

## Check the plan

Print the `gcloud` commands the script would run. This makes nothing:

```bash
bash deploy.sh --dry-run
```

Read the output. There is one firewall rule for the Meeting Sites and the Signal Sites, one VM
and its startup script. The join token shows as `rtt_REDACTED` in this output.

Useful options, all optional:

- `--zone us-central1-a` is the default. Pick the zone nearest to the network you want to watch.
- `--machine-type e2-small` is the default, 2 GB of memory. It is the same size as the AWS
  template's default.
- `--allowed-cidr 0.0.0.0/0` is who may reach the Station's decoy services. It is open to
  whoever can reach the VM, like a default install. For an internal deception host, narrow it to
  your internal ranges.
- `--ssh-cidr 203.0.113.7/32` adds an ssh rule for that range. There is none without it.
- `--name ripty-station` is the VM name. Use another name for a second Station in the same
  project.

## Create the Station

Run the script, with any options you chose:

```bash
bash deploy.sh
```

It creates the firewall rules and the VM, then prints the VM's name and external IP address.

## Check the Station in Headquarters

The VM needs a few minutes to download the Station and its Python packages, install and enroll.
Then open the Fleet page in Headquarters. The Station shows there with the name you gave it.

If it does not show after ten minutes:

- Headquarters must accept the Station channel from the VM's external address. Open that port
  to the VM in the firewall of the host that runs Headquarters.
- Read the install log on the VM. A project's default network usually has an ssh rule already.
  If yours has none, add one with `--ssh-cidr` when you run the script. Then:

```bash
gcloud compute ssh ripty-station --zone us-central1-a --command 'sudo cat /var/log/ripty-install.log'
```

- An expired join token ends the log with a refusal. In Headquarters choose New join command
  for the Station and paste the new values as before (`set -a`, the lines, `set +a`). A VM name
  can exist only once, so delete the old VM, then run the script again:

```bash
gcloud compute instances delete ripty-station --zone us-central1-a
bash deploy.sh
```

  The script keeps a firewall rule that already exists, so the rules of the first run stay as
  they were. Delete a rule first to change its range. To keep the old VM instead, pass another
  name to the script, for example `bash deploy.sh --name ripty-station-2`.

- If the script stopped before it made the VM (a zone with no free capacity, for example), run it
  again, with `--zone` set to another zone if you like. No delete is needed then.

## Clean up

Once the Station shows on the Fleet page, remove the spent join token from the VM's metadata:

```bash
gcloud compute instances remove-metadata ripty-station --zone us-central1-a --keys startup-script
```

Delete `station.env` if you saved it.

To remove the Station later, delete the VM and its firewall rules in Google Cloud, and remove
the Station from the Stations page in Headquarters:

```bash
gcloud compute instances delete ripty-station --zone us-central1-a
gcloud compute firewall-rules delete ripty-station-allow-station
```

The script also made `ripty-station-allow-dns` when you set a DNS zone and `ripty-station-allow-ssh`
when you passed `--ssh-cidr`. Delete those the same way.

<walkthrough-conclusion-trophy></walkthrough-conclusion-trophy>

Your Station is running on Google Cloud.
