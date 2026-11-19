# GL-E750 display: MCU protocol and mcu-switch

Why the display code looks the way it does. Facts under **Measured** come from tests on a GL-E750 with the stock MCU firmware V 2.0.8.

## Parts

| File | Role |
| --- | --- |
| `files/usr/bin/mcu` | Daemon (Lua, lua-eco), GL.iNet origin: status frames to the MCU, battery and temperature from its replies, ubus object `mcu`, power-button events |
| `files/usr/bin/mcu-switch` | Gestures and screen modes; sources `files/usr/share/mcu-switch/lib.sh` |
| `files/usr/share/mcu-switch/{sms,menu,module}.sh` | SMS, menu and module (`awg`, `pw`) modes |
| `files/etc/rc.button/BTN_0` | Slide switch: `mcu-switch flip on\|off $SEEN` |
| `files/etc/config/mcu` | Screens (`global`), gesture fallback actions (`switch`), modules (`module`), menu (`menu.item`) |
| `packages/luci-app-gl-e750` | luci-app-5gmodem extension: `5gmodem/ext/gl-e750.js` (cards, presets, menu editor), `buttons.d/gl-e750.sh` (backend hooks), see luci-app-5gmodem `docs/subsystems/extensions.md` |

## MCU protocol

Serial port from `glconfig.mcu.dev` (`/dev/ttyS0`), 115200 8N1. The router writes JSON objects; the MCU answers some of them and sends events on its own.

| Frame | Effect |
| --- | --- |
| status (`{"ps": ..., "clock": ..., "ssid": ...}`, ~400 bytes) | Data of the standard screens. Reply `{OK},capacity,temp,chg_state,cycles` comes late and may arrive in two reads (`result_hander` buffers the first part) |
| `{"msg": "<64 chars>"}` | Pop-up, 4 rows of 16 characters. Shown 20 s, then the display goes off |
| `{"ps": "0\|1"}` | Power saving. Acts only when opposite to the MCU's own state |
| `{"display_mask": "<hex>"}` | Standard screens on (bits from `global.*_enabled`, `1f`: all) or off (`0`) |
| from the MCU: `Power_Saving_on` / `Power_Saving_off` | Power button held 3 s. The MCU has already toggled its own ps and shows its own "Standby mode" screen |

Measured:

- **Frames need ≥ 40 ms of idle line between them**; with less the MCU drops characters. `write()` returns before the bytes leave the UART (8N1 at 115200 is 11.5 bytes/ms, a status frame takes ~35 ms on the wire), so the daemon writes a frame no sooner than `0.05 + bytes / 11520` s after the previous one (`get_serial_data`), and mcu-switch sleeps 50 ms after each pop-up (`send`). The daemon sends nothing while a mode owns the screen, so its writes and mcu-switch's do not overlap. Pop-ups every 200 ms show without defects.
- **A short press of the power button wipes the pop-up and shows the standard screen**, unless `display_mask` is `0`. A mode therefore turns the standard screens off while it runs.
- The MCU redraws a standard screen only when the frame data changes; an identical frame does nothing, except right after a ps change.
- Pop-ups show while the MCU is in power saving.
- Status frames sent during a pop-up do not disturb it.
- There is no frame that wakes the display after a pop-up timed out: only a button press does.
- After a long press the MCU's ps no longer matches `global.power_saveing`. Restoring it takes, in this order: `{"ps": system}` (only if different), `display_mask`, a status frame, then the final pop-up, each ≥ 40 ms apart. The earlier fix sent the status frame twice: the MCU ignores the first frame after a ps frame, and the `display_mask` frame now takes that place.

## Screen ownership (mcu-switch)

One mcu-switch process owns the screen. Files in `/tmp`:

| File | Content |
| --- | --- |
| `mcu-switch.pid` | `<pid> <kind>` of the owner: `f` flip, `a` action, `r` module, `m` metrics, `s` SMS, `t` standby, `n` menu. Cleared by the owner's EXIT trap |
| `mcu-switch.gen` | Gesture sequence id: an action started by an older gesture skips its next `own` |
| `mcu-switch.pend` | Pid of a flip waiting for a possible double flip (`gesture` s); `g`: double flip came |
| `mcu-switch.in` | Input for a mode (`flip`, `long`), followed by `SIGUSR1` to the owner |
| `mcu-switch.scr` | Last pop-up frame of the owner |
| `mcu-switch.lp` | Frame of the mode's reaction to a long press (empty: `scr`) |
| `mcu-switch.lpg` | First frame of the long press action when no mode runs (`lpg`, rewritten by `final` and at daemon start) |
| `mcu-switch.menuf` | Menu list as last drawn: first frame of the next menu once the help screen is off |
| `mcu-switch.fin` | Final pop-up of the mode that ended; `wipe`: clear the pop-up |
| `mcu-switch.mask` | mcu-switch sent `display_mask 0`; the daemon restores the screens and removes it |
| `mcu-switch.menu` | Command of the menu item used last |

- `own <kind>` makes the caller the owner and kills the previous one. If the screen was free it creates `mask` and sends `{"display_mask": "0"}`.
- `send` writes the pop-up to the tty and to `scr`. `final` shows the end message (capitals, centred on row 2, detail on row 3) and writes it to `fin`.
- Modes with input (`s`, `m`, `n`) get each flip (from mcu-switch) and the long press (from the daemon) through `in` + `SIGUSR1`; there is no double flip inside them. Other kinds are replaced by a new gesture.
- The menu help screen shows while `menu.intro` > 0 (unset: 3); each show decrements it (one flash write).
- A long press can arrive while the shell starts: `mcu-switch long` and `flip` run re-niced (`nice -n -10`), the user's command runs at normal priority.

## Daemon side

- **Any owner pauses status frames** (`screen_check`): the daemon sends nothing while a mode owns the screen (at most 10 min, metrics) and drops a status frame collected while a mode started. It still reads the port for button events and MCU requests. Battery and temperature in `/tmp/mcu-status.json` are not updated meanwhile. Frames written by other ubus clients go out with `display_mask` `0` and the MCU's own ps.
- **Long press** (`long_press`): the MCU shows its "Standby mode" at once, and mcu-switch needs ~0.5 s to draw. The daemon covers it immediately. In a mode with input it sends `lp` (or `scr`) and passes `long` to the mode. Otherwise it sends `display_mask 0` (no owner) and `lpg`, then spawns `MCU_LP=1 mcu-switch long`. `read_fun` returns as soon as a read ends with a `Power_Saving_*` event instead of waiting 0.3 s for more data.
- **Restore** (`restore`): when no owner is left (checked every 0.1 s while paused, 0.5 s otherwise) and the daemon is paused, holds a long-press ps, or finds `mask` (a short mode can start and end between two checks), the daemon sends the sequence from the previous section and then `fin`. With `fin` = `wipe` the ps frame is always sent, with `"msg": ""`, and no pop-up follows. If a new owner appeared meanwhile it sends `display_mask 0` instead of `fin`. After a long press with no owner, it waits 5 s (`ps_wait`) for mcu-switch to take the screen.
- Children are started with `sys.sh` (`spawn`). lua-eco's `sys.signal` blocks SIGTERM in the daemon, and children of `io.popen`/`os.execute` inherit the block: `timeout` could not stop a hung `uqmi`, which froze the whole event loop (ubus "Request timed out", procd SIGKILL on restart).

## Final messages

| Mode | Message |
| --- | --- |
| menu | `MENU DONE` |
| SMS | `SMS DONE` (row 3: `no messages`, `all marked read`); after a flash-only notification `NEW SMS`; "Mark all read?" not answered: none, standard screen |
| metrics | `METRICS DONE` |
| standby | `STANDBY ON`, `STANDBY OFF` (row 3 `already` if nothing changed) |
| module | `<name> READY` / `<name> DOWN`, or `<name> <ok_<action>>` (row 3 `already` if nothing to do); failures `ERROR`, `TIMEOUT`, `CPU HIGH` |
| other command | gesture or menu item name; row 3 `done` or `failed (<exit code>)` |
| no command | gesture name; row 3 `disabled` or `not configured` |

A superseded mode shows nothing: the new one owns the screen.

## Modules (`config module`)

`mcu-switch <section> on|on_*|off` runs `cmd_<action>` and shows the elapsed time and system load until the service settles.

| Option | Meaning |
| --- | --- |
| `name` | Name on the display |
| `cmd_<action>` | Command for `on`, `on_<variant>`, `off` |
| `is_<action>`, `is_on` | Test: already in that state, nothing to run |
| `ok_<action>` | Text after the name on success instead of `READY`/`DOWN` (16 characters per row: `ok_on_split 'SPLIT CHANN.'` → `AWG SPLIT CHANN.`) |
| `log`, `done_re`, `done_re_off` | Log files and the line that means done; without them, the command's exit code |
| `estimate`, `grace` | Seconds before `TIMEOUT` = `estimate + grace` |
| `stabilize`, `cpu_ok` | After done, wait up to `stabilize` s for CPU < `cpu_ok` % (`CPU HIGH` otherwise) |

## MCU firmware

Most of the above described code works around the stock MCU firmware limitations:
- short button press event is not communicated to Linux leaving only two inputs available: switch flip and button long press;
- a short button press autonomously brings back standard screens unless all of them disabled with display_mask;
- a pop-up 'msg' custom frame is not stored in MCU and needs to be retransmitted for any updates;
- a "Standby mode" screen shown before the router receives notification of the press;
- characters dropped on a busy line.
