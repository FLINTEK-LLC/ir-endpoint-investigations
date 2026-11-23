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
// build, Pro requires a valid product key during setup - see the
// `product_key` variable below.)

packer {
  required_plugins {
    vmware = {
      version = ">= 1.0.11"
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
  description = "Windows 11 Pro product key. Defaults to Microsoft's own publicly-documented generic KMS client setup key for Pro - this selects the edition during setup but does NOT activate Windows (desktop watermark, Settings nag, no functional restriction otherwise), which is fine for a disposable, snapshot-revert analyst VM with no personalization needs. Pass a real key with -var once you have one, for a permanently-activated golden image instead - no other change needed. Unlike winrm_password, autounattend.xml cannot read this variable (a floppy file is static content, not a template), so whatever key is used here must also be placed directly into http/autounattend.xml's <ProductKey><Key> element before building - same 'change both together' requirement winrm_password already documents. Never hardcode a REAL license key in a committed copy of autounattend.xml or in any committed .pkrvars file - pass it with -var or a gitignored .pkrvars.hcl, same convention as this repo's admin_password variables in infra/modules/*/investigation-host/variables.tf. The generic key above is safe to commit since it is Microsoft's own public, non-activating default."
}

variable "vm_name" {
  type    = string
  default = "ir-golden"
}

variable "output_directory" {
  type        = string
  default     = "output-ir-golden"
  description = "Where Packer writes the built VM. New-GoldenSnapshot.ps1's default -VmxPath assumes this stays in sync with infra/local/README.md's Quick start."
}

variable "disk_size_mb" {
  type    = number
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
  description = "Local account autounattend.xml creates and enables WinRM for, so Packer's provisioners can connect. This is also the account used to RDP in afterwards - set winrm_password to something memorable, or change it once the VM comes up."
}

variable "winrm_password" {
  type        = string
  sensitive   = true
  description = "Plaintext in autounattend.xml by necessity - unattended Windows setup has no secrets-manager hook. The committed http/autounattend.xml ships a placeholder password (ChangeMe!IR-Golden-2026); it is not a real secret, but change it (in BOTH autounattend.xml and this variable, they must match) before relying on this VM long-term."
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
variable "kape_zip_path" {
  type    = string
  default = ""
}

source "vmware-iso" "golden" {
  vm_name          = var.vm_name
  output_directory = var.output_directory
  iso_url          = var.iso_url
  iso_checksum     = var.iso_checksum

  disk_size            = var.disk_size_mb
  memory               = var.memory_mb
  cpus                 = var.cpus
  guest_os_type        = "windows9-64" # Workstation's internal id for Windows 10/11 64-bit guests.
  headless             = false         // Visible while building is worth it the first few times you debug autounattend.xml.
  version              = 19            // Workstation 17.x virtual hardware version.
  network_adapter_type = "vmxnet3"     // VMware's paravirtualized NIC - the vmware-iso builder installs VMware Tools into the guest automatically as part of a normal build, which vmxnet3 needs; it gives real network throughput, matters for both the Packer provisioners and this module's own guest-IP/RDP steps in New-LocalCase.ps1/Connect-LocalHost.ps1.

  // Without an explicit adapter, the disk shows up in Windows Setup's
  // "Where do you want to install Windows" screen as EMPTY - no disk
  // listed at all, not just unselected. SATA is the deliberate choice
  // here over any SCSI sub-type (lsilogic/lsisas1068/pvscsi/buslogic):
  // Workstation's VM Settings panel labels a disk generically as "SCSI"
  // regardless of which sub-type actually got applied, and a SCSI
  // sub-type mismatch (or the plugin/guest-OS-profile combination
  // silently not honoring the requested one) is exactly the kind of
  // thing that produces a disk with no recognized inbox driver. SATA's
  // AHCI driver has been inbox in Windows since Vista, across every
  // mainstream hypervisor, with no sub-type ambiguity to get wrong.
  disk_adapter_type = "sata"

  // autounattend.xml drives Windows Setup through a floppy image - the
  // oldest and most universally-supported injection mechanism for
  // unattended Windows installs, and the one that works with the stock
  // vmware-iso builder with no extra floppy controller config.
  floppy_files = ["${path.root}/http/autounattend.xml"]

  // Without this, the VM's BIOS boot order leaves the CD-ROM ahead of the
  // hard disk, so every reboot mid-install (WinPE -> specialize -> OOBE)
  // boots the ISO again instead of continuing on disk - Windows Setup
  // restarts from scratch forever rather than completing. Forcing hdd
  // first fixes this; the ISO is still attached for file access during
  // setup, just not boot-prioritized after the first reboot.
  vmx_data = {
    "bios.bootOrder" = "hdd,cdrom"
  }

  communicator   = "winrm"
  winrm_username = var.winrm_username
  winrm_password = var.winrm_password
  winrm_timeout  = "6h" // Windows Setup + first-boot + driver install can genuinely take this long on a slow disk/ISO.

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

  // Stage the licensed KAPE zip into the guest BEFORE Setup-Workstation.ps1
  // runs, so it finds kape.exe already in place. Packer's `only` lets this
  // step be skipped cleanly when kape_zip_path is blank, without an
  // external shell conditional.
  provisioner "file" {
    only        = var.kape_zip_path != "" ? ["vmware-iso.golden"] : []
    source      = var.kape_zip_path
    destination = "C:/Windows/Temp/kape.zip"
  }

  provisioner "powershell" {
    only = var.kape_zip_path != "" ? ["vmware-iso.golden"] : []
    inline = [
      "New-Item -ItemType Directory -Path C:\\Tools\\kape -Force | Out-Null",
      "Expand-Archive -LiteralPath C:\\Windows\\Temp\\kape.zip -DestinationPath C:\\Tools\\kape -Force",
      "Remove-Item C:\\Windows\\Temp\\kape.zip -Force"
    ]
  }

  // This repo itself, copied in whole rather than re-cloned with git -
  // the base image has no git installed yet, matching
  // infra\scripts\fetch-and-bootstrap.ps1's own "no git dependency"
  // reasoning for the cloud module's first-boot shim.
  provisioner "file" {
    source      = "${path.root}/../../.."
    destination = "C:/ir-endpoint-investigations"
  }

  // Reuses this repo's OWN Setup-Workstation.ps1 rather than reimplementing
  // tool-fetching logic inside the Packer template - see
  // infra\local\README.md's "Reuse" section.
  provisioner "powershell" {
    script = "${path.root}/scripts/provision-setup-workstation.ps1"
  }
}
