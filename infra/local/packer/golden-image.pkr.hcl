// Packer template for the local VMware Workstation golden IR analyst
// image. Builds a Windows VM, provisions it with this repo's own
// scripts\Setup-Workstation.ps1 (reused, not reimplemented - see
// infra\local\README.md), and leaves it powered off, ready for
// New-GoldenSnapshot.ps1 to snapshot as `golden-clean`.
//
// WHY vmware-iso and not vagrant/vmware-vmx: there is no existing base box
// to start from, so this has to build Windows from a real installer ISO,
// which is what the vmware-iso builder is for.
//
// WHY an .iso the user must supply, not a scripted download: Microsoft's
// Windows 11 Pro ISO is behind an official download page with no stable,
// scriptable URL - the same shape as this project's own KAPE licensing
// gate (see root README.md's Prerequisites and infra\README.md's
// "Getting KAPE onto the host"). This template never tries to fetch one;
// `iso_url` below is a required variable with no default, so `packer
// build` fails fast with a clear message instead of silently trying (and
// failing) to scrape a vendor's download page.
//
// Get the ISO from:
//   https://www.microsoft.com/software-download/windows11
// (Windows 11 Pro - chosen over Windows Server 2022/2025 because this is
// a single-analyst workstation, not a server role. Unlike an evaluation
// build, Pro requires appropriate licensing; the generic setup key below
// selects Pro without providing a license or retail activation.)

packer {
  required_plugins {
    vmware = {
      version = "= 2.1.7"
      source  = "github.com/hashicorp/vmware"
    }
  }
}

variable "iso_url" {
  type        = string
  description = "Local path or URL to the Windows 11 Pro ISO. No default on purpose - see the file header comment for why this can't be fetched automatically."
}

variable "iso_checksum" {
  type        = string
  description = "e.g. sha256:<hash>. Compute it yourself after downloading (Get-FileHash -Algorithm SHA256) - Microsoft's download page does not reliably publish one next to the ISO."
}

variable "product_key" {
  type        = string
  sensitive   = true
  default     = "W269N-WFGWX-YVC9B-4J6C9-T83GX"
  description = "Windows 11 Pro setup key, rendered into the answer file. The default is Microsoft's public Pro KMS client key; activation requires a licensed KMS environment or a suitable replacement key. Supply real keys via a gitignored var file or environment variable."
}

variable "vm_name" {
  type    = string
  default = "ir-golden"
}

variable "computer_name" {
  type    = string
  default = "ir-golden"
  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9-]{0,14}$", var.computer_name)) && !can(regex("^[0-9]+$", var.computer_name))
    error_message = "Computer name must be 1-15 ASCII letters, digits or hyphens, start with a letter or digit, and not be entirely numeric."
  }
}

variable "output_directory" {
  type        = string
  default     = "output-ir-golden"
  description = "Where Packer writes the built VM. New-GoldenSnapshot.ps1's default -VmxPath assumes this stays in sync with infra/local/README.md's Quick start."
}

variable "disk_size_mb" {
  type = number
  validation {
    condition     = var.disk_size_mb >= 65536 && floor(var.disk_size_mb) == var.disk_size_mb
    error_message = "Disk size must be an integer of at least 65536 (Windows 11 minimum storage)."
  }
  default = 81920 # 80 GB - KAPE + EZ Tools GUI suite + Sysinternals + Autopsy + Volatility3/MemProcFS/ImHex + Windows itself, with real headroom for case evidence copied in during provisioning tests.
}

variable "memory_mb" {
  type    = number
  default = 8192
}

variable "cpus" {
  type    = number
  default = 4
}

variable "winrm_username" {
  type        = string
  default     = "ir-analyst"
  description = "Local administrator rendered into autounattend.xml and used for WinRM and RDP."
  validation {
    condition     = can(regex("^[A-Za-z][A-Za-z0-9_-]{0,19}$", var.winrm_username)) && !contains(["administrator", "guest"], lower(var.winrm_username))
    error_message = "WinRM username must be 1-20 letters/digits/underscores/hyphens, start with a letter, and not be Administrator or Guest."
  }
}

variable "winrm_password" {
  type        = string
  sensitive   = true
  description = "Password rendered into the floppy answer file for the local administrator and AutoLogon. Required; no committed password default. Treat build artifacts containing the answer file as credentials."
  validation {
    condition     = length(var.winrm_password) >= 12
    error_message = "Use a winrm_password of at least 12 characters that satisfies Windows password complexity requirements."
  }
}

// A local kape.zip is NOT fetched by this template - same licensing gate
// as everywhere else in this repo. Point -var kape_zip_path at your own
// licensed copy and the provisioner stages it to C:\Tools\kape before
// running Setup-Workstation.ps1, exactly like the cloud module's optional
// tools-storage step (see infra\README.md's "Getting KAPE onto the host").
// Leave it unset and the golden image comes up with everything EXCEPT the
// KAPE-coupled parsing toolchain (EZ Tools CLI, Hayabusa, Chainsaw,
// Hindsight, RegRipper) - Setup-Workstation.ps1 itself reports this
// clearly rather than failing the whole build.
variable "vmware_tools_iso_path" {
  type        = string
  default     = ""
  description = "Optional absolute host path to VMware Tools windows.iso. If empty, use windows.iso in Workstation's installation directory. Required when that installation does not bundle the Tools ISO."
}

variable "kape_zip_path" {
  type    = string
  default = ""
}

// XML-escape text before rendering; passwords containing &, < or quotes
// must not corrupt the answer file. Keep the raw variables for WinRM.
locals {
  unattend_values = {
    for key, value in {
      product_key    = var.product_key
      computer_name  = var.computer_name
      winrm_username = var.winrm_username
      winrm_password = var.winrm_password
    } : key => replace(replace(replace(replace(replace(value, "&", "&amp;"), "<", "&lt;"), ">", "&gt;"), "\"", "&quot;"), "'", "&apos;")
  }
  // Leave 4 MiB for alignment/metadata. The final recovery partition grows
  // into the remaining space; the Windows partition size follows disk_size_mb.
  windows_partition_mb = var.disk_size_mb - 300 - 16 - 1536 - 4
}

source "vmware-iso" "golden" {
  vm_name          = var.vm_name
  output_directory = var.output_directory
  iso_url          = var.iso_url
  iso_checksum     = var.iso_checksum

  disk_size     = var.disk_size_mb
  memory        = var.memory_mb
  cpus          = var.cpus
  guest_os_type = "windows9-64" # Workstation's internal id for Windows 10/11 64-bit guests.
  // Visible while building - needed for boot_command keystrokes to reach
  // the guest at all (see the boot_command comment below). A `vmrun start
  // ... gui` hang (upstream packer-plugin-vmware#280) was the actual cause
  // of an earlier "stuck at Powering on virtual machine" failure, NOT
  // anything about this flag or EFI firmware - that hang only reproduces
  // when VMware Workstation's own application isn't already running
  // before `packer build` starts. Launch Workstation yourself first (see
  // TESTING.md) rather than going headless to work around it.
  headless = false
  version  = 19 // Supported by Workstation 17.6+ (version 19 originated with Workstation 16.2).
  // E1000E has an inbox Windows driver: WinRM must work BEFORE Tools can
  // be uploaded. Packer does not automatically install VMware Tools.
  network_adapter_type = "e1000e"
  network              = "nat"

  // Keep the controller that made the disk visible in this VM's WinPE.
  // SATA/AHCI works with EFI and does not require a VMware SCSI driver.
  disk_adapter_type  = "sata"
  cdrom_adapter_type = "sata"

  // Render at build time, keeping account/key settings in one place.
  floppy_content = {
    "autounattend.xml" = templatefile("http/autounattend.xml", merge(local.unattend_values, {
      windows_partition_mb = local.windows_partition_mb
    }))
  }

  // Set firmware explicitly through VMX. Must match the GPT/ESP layout
  // in autounattend.xml; no guest-profile-dependent firmware default.
  // EFI's Windows Boot Manager entry is created by Setup in NVRAM - no
  // vmx-level boot-order key is needed or honored under EFI firmware
  // (bios.bootOrder only applies to legacy BIOS and was removed here).
  vmx_data = {
    "firmware"                = "efi"
    "uefi.secureBoot.enabled" = "FALSE"
  }

  // The ISO's "Press any key to boot from CD or DVD" prompt has a very
  // short accept-window (observed: a couple seconds), and it starts
  // essentially as soon as the VM begins booting. Minimal boot_wait, then
  // dense, closely-spaced keystrokes starting almost immediately, so SOME
  // keystroke lands inside the brief window regardless of exactly when it
  // opens (varies with host boot speed). IMPORTANT PREREQUISITE: VMware
  // Workstation's own application must already be running before
  // `packer build` starts, or `vmrun start ... gui` can hang indefinitely
  // at "Powering on virtual machine" before ever reaching VNC/boot_command
  // at all (upstream packer-plugin-vmware#280) - no boot_command tuning
  // fixes that, only launching Workstation first does. See TESTING.md.
  boot_wait = "1s"
  boot_command = [
    "<spacebar><wait1>", "<spacebar><wait1>", "<spacebar><wait1>", "<spacebar><wait1>",
    "<spacebar><wait1>", "<spacebar><wait1>", "<spacebar><wait1>", "<spacebar><wait1>",
    "<spacebar><wait1>", "<spacebar><wait1>", "<spacebar><wait1>", "<spacebar><wait1>",
    "<spacebar><wait1>", "<spacebar><wait1>", "<spacebar><wait1>", "<spacebar><wait1>",
    "<spacebar><wait1>", "<spacebar><wait1>", "<spacebar><wait1>", "<spacebar><wait1>",
    "<enter><wait1>", "<enter><wait1>", "<enter><wait1>", "<enter><wait1>",
    "<enter><wait1>", "<enter><wait1>", "<enter><wait1>", "<enter><wait1>",
  ]

  // Uploading an ISO is not installing Tools; the first provisioner below
  // installs it. Workstation's windows.iso must be present on the host.
  tools_mode          = "upload"
  tools_source_path   = var.vmware_tools_iso_path
  tools_upload_flavor = var.vmware_tools_iso_path == "" ? "windows" : ""
  tools_upload_path   = "C:/Windows/Temp/vmware-tools.iso"

  communicator   = "winrm"
  winrm_username = var.winrm_username
  winrm_password = var.winrm_password
  winrm_use_ssl  = false
  winrm_use_ntlm = false // Matches the Basic/HTTP bootstrap in the answer file.
  winrm_timeout  = "6h"  // Windows Setup + first-boot + driver install can genuinely take this long on a slow disk/ISO.

  shutdown_command = "shutdown /s /t 10 /f /d p:4:1"
  shutdown_timeout = "15m"

  // No keep_registered here: that option only applies to a REMOTE
  // hypervisor build (ESXi), where Packer would otherwise deregister the
  // VM after export. A local VMware Workstation build already leaves the
  // finished .vmx sitting in output_directory with nothing to deregister -
  // that's exactly what New-GoldenSnapshot.ps1 expects to find.
}

build {
  sources = ["source.vmware-iso.golden"]

  // Packer launches elevated PowerShell via Task Scheduler. Mount and install
  // in the same local SYSTEM task, outside the WinRM logon context that
  // returned Attached=False in previous builds. Diskpart's vdisk commands
  // accept VHD/VHDX, not ISO. Do not substitute attach vdisk here.
  provisioner "powershell" {
    elevated_user     = "SYSTEM"
    elevated_password = ""
    inline = [
      "$ErrorActionPreference = 'Stop'",
      "$iso = 'C:\\Windows\\Temp\\vmware-tools.iso'",
      "if (-not (Test-Path -LiteralPath $iso -PathType Leaf)) { throw \"VMware Tools ISO missing: $iso\" }",
      "try {",
      "  Mount-DiskImage -ImagePath $iso -StorageType ISO -ErrorAction Stop | Out-Null",
      "  $drive = $null",
      "  for ($i = 0; $i -lt 30 -and -not $drive; $i++) { $drive = Get-DiskImage -ImagePath $iso | Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter } | Select-Object -First 1 -ExpandProperty DriveLetter; if (-not $drive) { Start-Sleep -Seconds 1 } }",
      "  if (-not $drive) { throw 'VMware Tools ISO has no drive letter after 30s in the SYSTEM scheduled task' }",
      "  $installer = $drive + ':\\setup64.exe'",
      "  if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) { throw \"VMware Tools installer missing: $installer\" }",
      "  $setup = Start-Process -FilePath $installer -ArgumentList '/S /v\"/qn REBOOT=ReallySuppress /L*v C:\\Windows\\Temp\\vmware-tools-install.log\"' -Wait -PassThru",
      "  if ($setup.ExitCode -notin @(0, 3010)) { throw \"VMware Tools installer failed: $($setup.ExitCode); see C:\\Windows\\Temp\\vmware-tools-install.log\" }",
      "} finally {",
      "  if ((Get-DiskImage -ImagePath $iso -ErrorAction SilentlyContinue).Attached) { Dismount-DiskImage -ImagePath $iso -ErrorAction Stop }",
      "}",
      "Remove-Item -LiteralPath $iso -Force",
      "exit 0"
    ]
  }

  provisioner "windows-restart" {
    restart_timeout = "15m"
  }

  // Stage the licensed KAPE zip into the guest BEFORE Setup-Workstation.ps1
  // runs. An empty `only` list means ALL builders, so use `except` to
  // skip these provisioners when the optional zip is absent.
  provisioner "file" {
    except      = var.kape_zip_path == "" ? ["vmware-iso.golden"] : []
    source      = var.kape_zip_path
    destination = "C:/Windows/Temp/kape.zip"
  }

  provisioner "powershell" {
    except = var.kape_zip_path == "" ? ["vmware-iso.golden"] : []
    inline = [
      "$ErrorActionPreference = 'Stop'",
      "New-Item -ItemType Directory -Path C:\\Tools\\kape -Force | Out-Null",
      "Expand-Archive -LiteralPath C:\\Windows\\Temp\\kape.zip -DestinationPath C:\\Tools\\kape -Force",
      "Remove-Item C:\\Windows\\Temp\\kape.zip -Force"
    ]
  }

  // Copy the runtime source directories explicitly. Uploading the whole
  // repo would also upload the active output VM/ISO/cache when it lives
  // under this tree, including potentially locked VMDKs and build secrets.
  provisioner "powershell" {
    inline = ["New-Item -ItemType Directory -Path C:\\ir-endpoint-investigations -Force | Out-Null"]
  }

  provisioner "file" {
    sources     = [for entry in ["scripts", "Modules", "templates", "velociraptor", "README.md", "LICENSE", "METHODOLOGY.md"] : "${path.root}/../../../${entry}"]
    destination = "C:/ir-endpoint-investigations/"
  }

  // Reuses this repo's OWN Setup-Workstation.ps1 rather than reimplementing
  // tool-fetching logic inside the Packer template - see
  // infra\local\README.md's "Reuse" section.
  provisioner "powershell" {
    script = "${path.root}/scripts/provision-setup-workstation.ps1"
  }
}
