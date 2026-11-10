# Macaroon

A minimal macOS virtual machine app for Apple silicon, built on Apple's Virtualization framework.

## Use

1. Open `Macaroon.xcodeproj` and run.
2. Choose a macOS restore image from the list. The list comes from Apple's IPSW catalog (`mesu.apple.com`) and is filtered to `VirtualMac2,1` images.
3. Click **Download & Install**. This downloads the IPSW (about 17 GB) and installs macOS onto a 64 GB sparse disk.
4. Click **Start**, then finish macOS Setup Assistant inside the VM.
5. Drag any `.app` onto the window. It is copied to the shared folder, which macOS mounts inside the VM at `/Volumes/My Shared Files`.

VM files are stored in `~/Library/Application Support/Macaroon/VM`.

Regenerate the project with `xcodegen generate` after editing `project.yml`.
