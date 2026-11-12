# Plan: boot TinyMacII into Recovery and turn SIP off

Goal: let an Ammonia-style tweak load into Apple's own apps inside the TinyMacII VM, so they can get our NeXT
title bar, resize bar and scroller. Only the VM is changed, never the host Mac.

## Rollback points (taken 2026-11-12)

- **Code:** git tag `v1.3-before-sip-off` → commit 6d4f006. To go back: `git checkout v1.3-before-sip-off`
  (or `git reset --hard v1.3-before-sip-off` on main).
- **VM:** Macaroon snapshot `2026-11-12 10.05.35 Snapshot`, in
  `~/Library/Application Support/Macaroon/TinyMacII/Snapshots/` (Disk.img + AuxiliaryStorage, plus the
  running state in State.vzvmsave). To go back: Macaroon → Snapshots → that snapshot → Restore.
  It is an APFS clone, so it takes no extra space until the VM disk changes.

## Step 1: a "Start in Recovery" button in Macaroon

The Virtualization framework has a start option for this. Apple's DTS answer on the developer forums:
"VZMacOSVirtualMachineStartOptions.startUpFromMacOSRecovery is the way to go" (macOS 13+). VirtualBuddy uses
the same option. In `Macaroon/MacaroonApp.swift`:

- `start()` gets a `recovery: Bool = false` parameter. For macOS guests (`.macOS`, `.tinyMacII`) with
  recovery set:
  ```swift
  let options = VZMacOSVirtualMachineStartOptions()
  options.startUpFromMacOSRecovery = true
  try await vm.start(options: options)
  ```
  Otherwise `try await vm.start()` as now.
- A "Start in Recovery" button next to Start (only for macOS guests, same enable rules as Start).
- Status text: "Recovery: Utilities → Terminal, then csrutil disable."

Fallback without code: inside the guest, `sudo nvram recovery-boot-mode=unused && sudo reboot`. Undo it from
Recovery with `nvram -d recovery-boot-mode`.

## Step 2: turn SIP off (inside the VM, in Recovery)

1. Start in Recovery → choose Options → sign in with the VM's admin user.
2. Utilities → Terminal: `csrutil disable` → confirm with the admin user/password.
   On Apple silicon this lowers the boot policy to Permissive Security for that VM install only.
3. `reboot`. In the VM's Terminal check `csrutil status` → "disabled".

## Step 3: boot argument for arm64e injection (needed by Ammonia)

- `sudo nvram boot-args="-arm64e_preview_abi"` → reboot → `nvram boot-args` to check.
- **Unknown:** whether this boot argument works inside a Virtualization.framework VM. It's checked here,
  before any tweak work.

## Step 4: tweak loader and a first NeXT tweak

1. Install the maintained Ammonia fork (the original CoreBedtime/ammonia repository was archived in June
   2026).
2. Allowlist only TextEdit first (`/private/var/ammonia/core/ammonia.allowlist` plus the tweak's
   `.dylib.whitelist`), so a crash can't take down the rest of the system.
3. Tweak v0: a dylib (arm64 + arm64e) that, for each titled NSWindow, hides the standard title bar and window
   buttons and adds our NeXT title bar and resize bar (shared code from NeXTKit.swift).
4. Then the scroller: replace NSScrollView's vertical scroller with NeXTScroller, on the left.
5. Widen the allowlist one app at a time (Finder, Notes, Mail …).

## If it fails

- The VM doesn't boot, is stuck in Recovery, or apps crash: Macaroon → Snapshots → Restore
  `2026-11-12 10.05.35 Snapshot`.
- To keep the VM but turn protection back on: Start in Recovery → `csrutil enable` → in macOS
  `sudo nvram -d boot-args`.
- Code: `git checkout v1.3-before-sip-off`.

## Risks

- Lower security inside the VM only. The host keeps SIP on.
- macOS 27.x updates in the VM can break the tweak; take a snapshot before each update.
- Not shippable through the App Store; an opt-in experiment for TinyMacII.
