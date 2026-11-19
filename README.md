# UE BOOM 2 — stop the BLE battery drain

## The problem
On firmware v2.x, the speaker keeps its Bluetooth Low Energy radio advertising while it is
"off". This is how the UE BOOM app's remote power-on works. It also slowly drains the battery.

## The fix: turn the BLE setting off (no reflashing)
The speaker accepts the command `03 01 B9 00` ("Set BLE state = off") on its Bluetooth Classic
serial port (SPP, RFCOMM). The setting is **persistent**, so you only send it once per speaker.
`03 01 B9 01` restores the original behaviour (BLE also stays on while the speaker is off).

**Tested on one BOOM 2 (fw 2.4.7):** after `ble-off`, the speaker still advertises over BLE while it is
ON, but stops as soon as it is powered OFF, and this holds across power cycles. That is exactly
"BLE off when the speaker is off".

You can check it with `./blescan 15 | grep -i <mac-without-dashes>`; no output means BLE is silent.

The command was found by community reverse engineering of the UE app:
- https://blog.countableset.com/2022/02/22/ue-boom-reverse-engineering/
- https://gist.github.com/perja12/a1c3b5c6e432ff2e6cf3403d65678ec9

### Usage (macOS)
```sh
./ueboom                         # interactive menu (recommended)
./ueboom status                  # status table only
./ueboom ble-off [all|Yellow|3a-5e-91-d4-0c-b7]   # match by address or part of the name
./ueboom ble-on  White           # undo (back to always-on BLE)
./ueboom raw White "02 01 6B"    # any frame; e.g. this one announces battery level

# rebuild:
swiftc -O -o ueboom ueboom.swift -framework IOBluetooth -framework CoreBluetooth
```

The menu lists every paired speaker whose name contains "BOOM" and shows for each one:
- **Power**: ON or off. The Mac pages each speaker for up to 3 s to find out.
- **BLE**: for a speaker that is off, a 6 s BLE scan tells whether it is still advertising
  (`BLE ON while off — draining battery`) or silent (`BLE off while off ✓`). A speaker that is on
  advertises either way, so the tool shows the last setting it sent or saw for it, saved in
  `~/Library/Application Support/ueboom/state.json`.

Type a number to pick one speaker, `d` / `e` to disable / enable BLE on every speaker that is
on, `r` to rescan, `q` to quit. Commands only reach speakers that are on; a speaker that is off
is skipped with a hint to turn it on.
1. Pair **each** speaker with the Mac first (System Settings → Bluetooth). Only "UE BOOM 2 Yellow"
   is paired right now.
2. Turn the speaker on. If the command fails, disconnect the speaker from your phone first.
3. The first run may ask you to allow Terminal to use Bluetooth.

### Caveats
- **The UE BOOM app turns BLE back on.** Remove the app from your phones, or run `ble-off` again
  after each time you use it.
- With BLE off you lose remote power-on from the app. Bluetooth audio and the buttons use
  Bluetooth Classic and keep working. PartyUp / Double-Up started with the buttons should keep
  working too, but this hasn't been tested.
- To check that it worked: power the speaker off, then scan with a BLE scanner app (nRF Connect,
  LightBlue). The speaker should no longer show up.

## Why there is no patched firmware
- **No firmware image is available.** Logitech never published BOOM 2 firmware files. The app
  downloads updates from Logitech's servers and sends them over Bluetooth using a private
  protocol. I found no public copy of v2.4.7 or any other version, and no description of the
  update protocol.
- **Patching it blind isn't realistic.** The speaker runs a Qualcomm/CSR Bluetooth chip. Its
  firmware is a set of VM and DSP applications for that chip, packed in a vendor-specific update
  file that may also carry an integrity check. Without the image, the tools for that chip, and a
  speaker to test on, a patch is guesswork.
- **A bad flash can't be undone from a computer.** The BOOM 2's USB port only charges the
  battery; it carries no data. A failed update could only be fixed by opening the speaker and
  wiring a CSR SPI programmer to the debug pads.
- **Behaviour isn't changed.** The SPP command above does what the patch was meant to do: it
  stops the drain. The only thing you give up is remote power-on.

For the same reasons there is no "flash any stock firmware" script. The only supported update
path is the UE BOOM app (BOOM 2 is supported on iOS/Android), which installs Logitech's latest
version.
