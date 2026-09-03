# Testing the AWS workflow, from scratch

Written for someone with **no AWS account at all**. Companion to
[TESTING.md](TESTING.md), which covers Azure.

## Read this first: how AWS differs

Same case lifecycle, same console, but three things are genuinely different
and all three have bitten before.

**1. The host has no public IP, so the subnet must have a NAT Gateway.**
This is *the* AWS failure mode. AWS's default VPC has an Internet Gateway,
which only works for instances that *have* a public IP - and this one
deliberately doesn't. A subnet with only an IGW route will happily launch an
instance that then never reaches SSM or GitHub, never becomes manageable, and
bills the whole time. `[2]` now checks for this and refuses, but you still
have to create the NAT Gateway (Step 5), and **it is the main cost of testing
AWS: about $0.045/hour plus data processing.**

**2. Connection is SSM Session Manager, not RDP.** No inbound port is opened
anywhere and there is no allowlist to manage - the agent makes an outbound
connection and the console tunnels RDP through it. That needs the Session
Manager plugin locally, which `[1]` installs.

**3. Windows Server 2025 on AWS is unverified.** The AMI is selected through
an AWS-managed SSM parameter, and the exact 2025 parameter name could not be
confirmed from AWS's documentation. `[2]` checks it exists in your region
before applying and tells you how to fix it if not.

## What this costs

| | |
|---|---|
| `t3.xlarge` Windows | ~$0.24/hr |
| NAT Gateway | ~$0.045/hr + $0.045/GB |
| gp3 root volume, 150 GB | ~$12/month (billed even when stopped) |
| S3 evidence storage | pennies |

Roughly **$0.60-0.70 for a couple of hours**, most of it the instance. AWS
free tier does not cover Windows instances of this size.

---

## Step 1 - Create an AWS account

Go to [aws.amazon.com](https://aws.amazon.com) and sign up. You need a card
and a phone verification. Choose the **Basic (free)** support plan.

Then create an IAM user for day-to-day use rather than using the root
account - AWS is emphatic about this and so is
[SECURITY.md](SECURITY.md):

1. Sign in as root, open **IAM** > **Users** > **Create user**.
2. Name it something like `ir-cloud`, and **do not** grant console access.
3. Attach the `AdministratorAccess` policy for this test. (Narrower is
   possible - see README.md's accounts section - but a scoped policy is a
   distraction while you are proving the workflow.)
4. Open the user > **Security credentials** > **Create access key** >
   **Command Line Interface**. Save the key ID and secret.
5. Turn on MFA for the root account while you are here, then stop using root.

## Step 2 - Local tools

Open PowerShell **as Administrator**:

```powershell
cd C:\Tools\Projects\ir-endpoint-investigations\infra
```

```powershell
.\Start-CloudConsole.ps1
```

Pick **`[1] First-time setup`**. It installs Terraform, the AWS CLI and the
**Session Manager plugin** - that last one is what makes `[4] Connect` work
and is easy to forget. Quit with `Q`, then:

```powershell
aws configure --profile ir-cloud
```

Enter the access key, the secret, `us-east-1`, and `json`. The profile name
`ir-cloud` matters - it is what every script defaults to.

Confirm it works:

```powershell
aws sts get-caller-identity --profile ir-cloud
```

Re-run `[1]`; you want `AWS CLI OK`, `AWS auth (profile: ir-cloud) OK` and
`AWS Session Manager Plugin OK`.

## Step 3 - Confirm the Windows Server 2025 AMI exists in your region

```powershell
aws ssm get-parameters-by-path --path /aws/service/ami-windows-latest --region us-east-1 --query "Parameters[].Name" --output text --profile ir-cloud | Select-String 2025-English-Full
```

You want `/aws/service/ami-windows-latest/Windows_Server-2025-English-Full-Base`.
If it is absent, note what *is* there (`...2022-English-Full-Base` will be)
and set `windows_ami_ssm_parameter` in
`modules/aws/investigation-host/variables.tf`. `[2]` also checks this, so you
can let it tell you.

## Step 4 - Check your vCPU quota

New accounts often start with a low On-Demand vCPU limit. `t3.xlarge` needs 4.

```powershell
aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A --region us-east-1 --query "Quota.Value" --profile ir-cloud
```

If that returns less than 4, request an increase in the console (Service
Quotas > EC2 > *Running On-Demand Standard instances*), or pick `t3.large`
(2 vCPU) at `[2]`.

## Step 5 - Create a test VPC with a NAT Gateway

In the console: **`[8] Case networking`** > AWS > *Create it*.

It creates a VPC (`10.30.0.0/16`), a public and a private subnet, an Internet
Gateway, an Elastic IP, and a **NAT Gateway in the public subnet serving the
private one** - then waits for that NAT Gateway to actually become available
before adding the private subnet's `0.0.0.0/0` route, since the route cannot
be created until it is. It prints the VPC and private subnet IDs you need at
Step 8.

Three things it exists to get right: the NAT Gateway belongs in the **public**
subnet even though it serves the private one, the route must wait for it, and
DNS hostnames must be enabled on the VPC or SSM cannot resolve its endpoints.

**The NAT Gateway bills from the moment it is created** (~$0.045/hr). Tear the
whole network down with `[8]` > AWS > *Delete it*.

Everything is tagged `Project=ir-endpoint-investigations`, which is how the
delete finds it - it will not touch a VPC you created another way.

At the end, `[8]` asks you to paste back the private subnet ID it printed. That
is not busywork: it saves it to `infra\.prereqs.json` and offers it as the
**default** at Step 8, so you never retype it.

<details>
<summary>Prefer the console? (equivalent click-through)</summary>

**VPC** > **Create VPC** > **VPC and more**: name `ir-test`, IPv4
`10.30.0.0/16`, **1** AZ, **1** public subnet, **1** private subnet,
**NAT gateways: In 1 AZ**. Use the *private* subnet at Step 8.

</details>

You do not need to note IDs by hand - `[2]` lists VPCs and subnets and marks
which subnets have egress.

## Step 6 - (Optional) Stage KAPE in S3

Skip to prove the infrastructure; do it for a host that can actually parse.

In the console: **`[9] Tools storage`** > AWS > *Create it*, giving it the path
to your licensed `kape.zip` when prompted.

It creates a private bucket with a random suffix (bucket names are globally
unique), blocks public access on it explicitly, and uploads the zip. The
instance role gets read-only access to this bucket alone. As with `[8]`, paste
the bucket name back when asked and Step 8 will offer it as the default.

To replace the zip later without recreating the bucket, use `[9]` >
*Upload/replace kape.zip*.

## Step 7 - Get a Velociraptor binary

Download the `windows-amd64.exe` asset from the
[latest release](https://github.com/Velocidex/velociraptor/releases) to
`C:\Tools\velociraptor.exe`.

## Step 8 - Create the case

In the console, **`[2] Create a new case`**:

| Prompt | Answer |
|---|---|
| Case ID | `awstest-01` |
| Cloud provider | `AWS` |
| Enable immutability? | `n` |
| Days before cold storage | Enter (30) |
| AWS region | `us-east-1` |
| AWS CLI profile | Enter (`ir-cloud`) |
| VPC | pick `ir-test` from the list |
| Subnet | **pick one marked `egress OK`** - the private subnet |
| Instance type | Enter (`t3.xlarge`) |
| Tools S3 bucket | your bucket from Step 6, or blank |
| Run terraform apply now? | `y` |

Before applying it checks the AMI parameter, the subnet's egress, and that
the bootstrap script is reachable on GitHub. Apply takes ~2-3 minutes; then
**wait another 10-15 minutes** for boot and bootstrap.

## Step 9 - Connect

**`[4] Connect to the investigation host`**. It starts an SSM port-forwarding
tunnel in its own window, prints the local Administrator password, and
launches `mstsc` against `localhost:13389`.

If it reports the instance is not a managed node, SSM has not registered it
yet - that is the classic symptom of no subnet egress. Confirm with:

```powershell
aws ssm describe-instance-information --region us-east-1 --profile ir-cloud --query "InstanceInformationList[].InstanceId" --output text
```

Your instance ID should appear. If it never does, the subnet has no NAT route.

## Step 10 - Verify on the host

```powershell
type C:\ir-case-mount.txt
```

Then check `D:\` is your S3 bucket, and that
`C:\ir-repo\ir-endpoint-investigations-main\` exists. KAPE is present only if
you did Step 6.

## Step 11 - Build and test a collector

**`[3]`**, giving it the Velociraptor path. On AWS this mints a real STS
`AssumeRole` session - a genuine temporary credential, write-only, scoped to
this case's bucket - and bakes it into the collector. Run the built exe
elevated on your own machine, then:

```powershell
aws s3 ls s3://ir-case-awstest-01/ --profile ir-cloud
```

## Step 12 - Tear down

Everything below is a console option. Nothing here needs a hand-typed command.

### Delete the case (host and evidence)

**`[D] Delete a case completely`**, pick the case, and type the case ID to
confirm.

That destroys the investigation host and its volumes, empties and deletes the
evidence bucket, removes the Terraform workspace, and deletes the local case
record. It is irreversible, which is why it asks you to type the ID.

Emptying the bucket is a separate act from destroying it, on purpose. The
module sets no `force_destroy`, so a stray `terraform destroy` can never take
evidence with it - which also means Terraform cannot remove a bucket with
anything in it. `[D]` empties it first, then lets Terraform delete the empty
bucket, so state stays consistent.

If you only want to stop paying for compute and keep the evidence, use
**`[5] Destroy the investigation host`** or **`[6] Archive this case`**
instead.

### Delete the shared network

**`[8] Case networking`** > AWS > *Delete it*.

This is the one that matters most for cost: the NAT Gateway bills ~$0.045/hr
from creation, and the Elastic IP keeps billing once it is no longer
associated. The delete does them in the order AWS requires - NAT Gateway
first (waiting for it to actually go), then the Elastic IP, then subnets,
route tables, Internet Gateway, and finally the VPC.

Leave the network up if you plan to test again shortly; a VPC itself is free,
but the NAT Gateway inside it is not.

### Delete the tools bucket

**`[9] Tools storage`** > AWS > *Delete it*. Optional - a ~50 MB zip costs
pennies a month, and keeping it saves re-uploading KAPE next time.

### Confirm you are not still being billed

**`[C] Check what is still billing`** > AWS (or Both), and say yes to the
all-regions sweep.

That checks the things that bill quietly rather than obviously - EBS volumes
(billed attached **or** detached), Elastic IPs (billed precisely when *not*
associated), NAT Gateways (billed until the state actually reads `deleted`),
snapshots, and any `ir-case-*` / `ir-tools-*` S3 bucket. Free leftovers like
VPCs are reported separately so they do not look like charges.

The all-regions sweep takes about a minute and is the one that matters:
something created in a region you have since forgotten about is the usual way
a "torn down" account keeps charging.

Clear output is `Nothing billable found. You are clear.`

> **A note on checking by hand.** If you write your own filter, quote the
> string: `--query "NatGateways[?State!='deleted'].NatGatewayId"`. Without
> the inner quotes, JMESPath reads bare `deleted` as a *field name*, which
> matches every gateway including deleted ones - so a fully torn-down account
> reports a NAT Gateway that is not there. `[C]` avoids this entirely by
> filtering in PowerShell rather than JMESPath.

## Troubleshooting

| Symptom | Cause |
|---|---|
| Apply fails on the AMI data source | Step 3 - the 2025 parameter is not in that region. |
| `[4]` says the instance is not a managed node | No subnet egress (Step 5), or SSM has not registered yet - give it 5 minutes. |
| `[4]` fails with SSM tunnel exit code 252 | AWS CLI exit 252 means invalid parameters. The console now prints the tunnel's own stderr, and keeps it at `%TEMP%\ssm-tunnel-<case>.err.log`. |
| `VcpuLimitExceeded` | Step 4 - request a quota increase or use `t3.large`. |
| Bootstrap log shows download failures | Subnet egress again. Check the route table points `0.0.0.0/0` at a NAT Gateway, not an IGW. |
| `terraform destroy` fails on the bucket | Versioned bucket still holding objects - empty it first (Step 12). |
| `D:` is not the evidence drive | The bootstrap records the letter it used in `C:\ir-case-mount.txt`. |

## Known-unverified on AWS

Honest list - these could not be tested without a live account:

- **The local Administrator password.** EC2Launch v2 randomises it during
  boot, and this module sets it afterwards from `user_data` (there is no key
  pair, since SSM is the only intended path). If sign-in fails, that ordering
  is the first suspect; `aws ec2 get-password-data` will not help without a
  key pair.
- **Windows Server 2025 AMI availability** per region (Step 3 checks it).
- **SSM registration timing** on first boot.
- **`aws s3 cp` onto itself** for the immediate-archive path in `[6]`.
