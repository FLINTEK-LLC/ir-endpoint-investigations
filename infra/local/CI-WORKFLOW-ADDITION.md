# CI workflow addition - apply this by hand

The automation that built this PR pushes through a GitHub OAuth App token
scoped without the `workflow` permission, so it cannot push a change to
any file under `.github/workflows/` itself (GitHub rejects that push with
"refusing to allow an OAuth App to create or update workflow ... without
`workflow` scope"). Every other file in this PR is unaffected - this is
purely a token-scope limitation on *this* file.

**Action needed from `ctrlaltdean` (or anyone with full `workflow` scope):**
replace the contents of `.github/workflows/selftest.yml` with the version
below (or apply it as a small manual edit - it is an additive change: one
new `packer` job, one new line in the existing console smoke-test step).
Delete this file once that's done; it exists only to carry the change
through review.

```yaml
name: Self-test

# The self-test is offline by design - no cloud credentials, no network - so it
# can run on every push without secrets and without costing anything. Anything
# that needs a real AWS or Azure account is deliberately out of scope here and
# lives in infra/TESTING.md and infra/TESTING-AWS.md as a manual procedure.
on:
  push:
    branches: [main]
  pull_request:
  workflow_dispatch:

jobs:
  selftest:
    # windows-latest, not ubuntu: these are Windows PowerShell 5.1 scripts and
    # several checks depend on Windows-only behaviour (the PowerShell AST
    # parser, CRLF handling, ConsoleHost detection).
    runs-on: windows-latest

    steps:
      - uses: actions/checkout@v4

      - name: Run offline self-test
        shell: powershell
        run: .\scripts\Invoke-SelfTest.ps1

      - name: Verify both consoles start and quit
        shell: powershell
        run: |
          # Piped stdin means Read-Choice takes its numbered fallback, which is
          # exactly the path a CI runner and any scripted caller use. If the
          # fallback ever stopped accepting a typed value, 'Q' would not quit
          # and this step would hang until the job timed out.
          $ErrorActionPreference = 'Stop'
          'Q' | powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Start-IRConsole.ps1 | Out-Null
          'Q' | powershell -NoProfile -ExecutionPolicy Bypass -File .\infra\Start-CloudConsole.ps1 | Out-Null
          'Q' | powershell -NoProfile -ExecutionPolicy Bypass -File .\infra\local\Start-LocalConsole.ps1 | Out-Null
          Write-Host "All three consoles started and quit cleanly."

  terraform:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: "1.9.8"

      - name: terraform fmt
        run: terraform fmt -check -recursive infra

      - name: terraform validate
        # -backend=false so init needs no credentials and no state backend.
        # validate checks the configuration is internally consistent; it cannot
        # and does not talk to AWS or Azure.
        shell: bash
        run: |
          set -e
          for d in infra/environments/*/; do
            echo "== $d"
            terraform -chdir="$d" init -backend=false -input=false >/dev/null
            terraform -chdir="$d" validate
          done

  packer:
    runs-on: ubuntu-latest
    # Same "no live apply" policy as the terraform job above: packer fmt and
    # validate both need no VMware Workstation install, no Windows ISO, and
    # no network beyond fetching the vmware plugin itself - a real
    # `packer build` needs all three and stays a manual procedure, see
    # infra/local/TESTING.md.
    steps:
      - uses: actions/checkout@v4

      - uses: hashicorp/setup-packer@v3
        with:
          version: "1.11.2"

      - name: packer fmt
        run: packer fmt -check -diff infra/local/packer

      - name: packer init
        run: packer init infra/local/packer/golden-image.pkr.hcl

      - name: packer validate
        # Dummy values for the required variables with no default - validate
        # checks the configuration is internally consistent, it never reads
        # the ISO or contacts a hypervisor.
        run: |
          packer validate \
            -var "iso_url=/tmp/placeholder.iso" \
            -var "iso_checksum=sha256:0000000000000000000000000000000000000000000000000000000000000000" \
            -var "winrm_password=PlaceholderCiOnly!" \
            infra/local/packer/golden-image.pkr.hcl
```

This exact content was verified locally before being handed off here:
`packer fmt -check`, `packer init`, and `packer validate` all pass against
`infra/local/packer/golden-image.pkr.hcl` with the dummy variables shown
above (no real ISO or VMware Workstation install needed for any of the
three), and `Invoke-SelfTest.ps1` passes with the local console's syntax
and wiring checks included.
