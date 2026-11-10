# Ripty Station on DigitalOcean

Two ways to put a Station on a DigitalOcean droplet. Both install the Station from your Headquarters
at the droplet's first boot and enroll it with a join token. Add Station in Headquarters prints every
value.

| File | What it is |
| --- | --- |
| `deploy.sh` | A Bash script that runs `doctl`: it creates the droplet, then a cloud firewall on the droplet's tag. |
| `station-templates.json` | Tells Headquarters about the two ways above: the "Create on DigitalOcean" button and the script download. |

## Quick launch: "Create on DigitalOcean"

After Generate in Add Station, the first row of buttons holds **Create on DigitalOcean**. It opens
`https://cloud.digitalocean.com/droplets/new` with Ubuntu 24.04, `s-1vcpu-2gb` and `nyc3` asked for.
The link carries no join token. Under the button Headquarters shows the user data for this Station.

1. Click **Create on DigitalOcean**. Check the image is Ubuntu 24.04 (LTS) x64, and that the size has
   at least 2 GiB of memory (see "Size" below). Choose a region.
2. Open **Advanced options**, tick **Add initialization scripts (free)**, and paste the user data
   from Headquarters into the box.
3. Under **Authentication**, choose an SSH key if you want to log in. The Station does not need it.
4. Click **Create Droplet**.
5. Open the droplet's **Networking** tab, then **Firewalls**, and add a firewall that allows inbound
   TCP 80, 8080, 8000, 22000 and 33890 from the ranges you want to deceive, and all outbound traffic.
   A droplet with no firewall answers on every port it listens on. `deploy.sh` does this step for
   you.

The Station enrolls within a few minutes and shows on the Stations page. The install log is
`/var/log/station-install.log` on the droplet (the user data from Headquarters writes it). The
`deploy.sh` script writes `/var/log/ripty-install.log` instead.

The user data holds the join token. The token works once and expires after one day, and DigitalOcean
keeps the user data with the droplet, so it is safe after the Station has enrolled.

## The script: `deploy.sh`

Needs [`doctl`](https://docs.digitalocean.com/reference/doctl/how-to/install/) logged in
(`doctl auth init`) and Bash 3.2 or later.

1. In Add Station, choose **Download values** for this template. It saves `station.env`.
2. Run:

   ```
   set -a; . ./station.env; set +a
   bash deploy.sh --dry-run
   bash deploy.sh
   ```

`--dry-run` prints the user data (with the join token hidden) and the `doctl` commands, and creates
nothing. The values are environment variables, so the token is on no command line:

| Variable | Meaning |
| --- | --- |
| `RIPTY_HQ_URL` | The Station address of Headquarters, `https://HOST:PORT`. The droplet must reach it. |
| `RIPTY_JOIN_TOKEN` | The join token from Add Station. |
| `RIPTY_HQ_PIN`, `RIPTY_HQ_SPKI` | The certificate pin and its key form. Set both or neither. |
| `RIPTY_DNS_ZONE` | Optional. Makes the Station a DNS Station for this zone and opens port 53. |

| Option | Default | Meaning |
| --- | --- | --- |
| `--region` | `nyc3` | Droplet region. |
| `--size` | `s-1vcpu-2gb` | Droplet size. |
| `--name` | `ripty-station` | Droplet name, and the tag the firewall attaches to. |
| `--ssh-key` | none | ID or fingerprint of a DigitalOcean SSH key for the `root` account. |
| `--allowed-cidr` | `0.0.0.0/0` | Who may reach the Station's ports. Narrow it for an internal host. |
| `--ssh-cidr` | none | Who may SSH in. There is no SSH rule unless `--ssh-key` is set too. |
| `--dry-run` | | Print the commands, change nothing. |

### The firewall

The firewall opens the same ports as the AWS template (`deploy/aws/ripty-connector.yaml`):

| Port | Service |
| --- | --- |
| 80, 8080, 8000 | Meeting Sites |
| 22000 | ssh Signal Site |
| 33890 | RDP Signal Site |
| 22 | SSH for you, only with `--ssh-key` and `--ssh-cidr` |
| 53, TCP and UDP | DNS callbacks, only with `RIPTY_DNS_ZONE`; open to everyone, because resolvers are anywhere |

Port 53 is closed unless `RIPTY_DNS_ZONE` is set when the script runs. A zone set later from
Headquarters (Stations page, DNS callback zone) is unreachable until you open it, and the script prints the
command when it leaves it closed:

```
doctl compute firewall add-rules FIREWALL_ID \
  --inbound-rules 'protocol:udp,ports:53,address:0.0.0.0/0 protocol:tcp,ports:53,address:0.0.0.0/0'
```

A DigitalOcean cloud firewall blocks all outbound traffic that no rule allows. The AWS security group
does not, so the script adds outbound rules for TCP, UDP and ICMP: the droplet has to reach
Headquarters and download the installer's files.

To remove the Station: delete the droplet and the firewall (`doctl compute droplet delete NAME`,
`doctl compute firewall delete FIREWALL_ID`), then remove the Station on the Stations page.

## Size

The droplet default is `s-1vcpu-2gb` (2 GiB), the size of the AWS template's smallest type. The
installer adds a 1 GiB swap file by itself on a host with under 1.5 GiB of memory and no swap, so
`s-1vcpu-1gb` works as well; pass `--size s-1vcpu-1gb` to save money.

## Notes from the check of DigitalOcean's documentation (2026-11-04)

- **Why not a "Deploy to DigitalOcean" button?** That button deploys an App Platform app from a public
  Git repository. App Platform's limits page says it exposes one public HTTP port per service
  (HTTP and HTTPS through its edge), keeps extra ports internal to the app, and cannot open SSH or
  SFTP ports. A Station needs raw TCP on 80, 8080, 8000, 22000 and 33890 and, for DNS callbacks, port
  53 over UDP and TCP. A droplet is the product that fits, so the button here opens the droplet create
  page.
- **Query parameters of the create page.** DigitalOcean documents none. Vendor links use
  `?image=<slug>`, and the link here adds `size` and `region` the same way. The page ignores a
  parameter it does not know, so at worst you pick the size and region by hand.
- **User data cannot be passed in the link.** The create page has no parameter for it, so the panel
  shows the user data to paste, and the script passes it with `--user-data-file`.
- **Marketplace 1-Click app.** Not offered: it needs the vendor program and a Packer image.
