# Macaroon

A minimal macOS virtual machine app for Apple silicon, built on Apple's Virtualization framework.

## Use

1. Open `Macaroon.xcodeproj` and run.
2. Choose a macOS restore image from the list. The list comes from Apple's IPSW catalog (`mesu.apple.com`) and is filtered to `VirtualMac2,1` images.
3. Click **Download & Install**. This downloads the IPSW (about 17 GB) and installs macOS onto a 64 GB sparse disk.
4. Click **Start**, then finish macOS Setup Assistant inside the VM.
5. Drag any `.app` onto the window. It is copied to the shared folder, which macOS mounts inside the VM at `/Volumes/My Shared Files`.

VM files are stored in `~/Library/Application Support/Macaroon/VM`.

**Snapshots** (toolbar menu): Take Snapshot clones `Disk.img` and `AuxiliaryStorage` into `VM/Snapshots/<date>/` using APFS copy-on-write, so it is near-instant and uses no extra space at first. If the VM is running, it is paused and its memory/device state is saved too, so restoring resumes exactly where it left off. Restore first saves a "Before Restore" snapshot, so you can always go back.

**Windows 11 ARM** (needs `brew install wimlib`): pick Windows ARM, then Download & Install (or Install from ISO…). Macaroon repacks the ISO into `Windows/Media.img`, installs unattended through WinPE with the virtio-win drivers, and restarts the VM through Windows' reboots until setup is done (about 10 minutes). Log in as your Mac user name with password `macaroon`. Apple's firmware has no framebuffer for Windows, so a small UEFI driver supplies one (`Tools/WindowsEFI`, rebuild with `make`).

Regenerate the project with `xcodegen generate` after editing `project.yml`.
