# Test plan

Everything here is run against real hardware — there is no way to fake a MAGRGB. The
levels are ordered so that the cheap, reversible checks come first and the disruptive ones
last. Stop at whatever level you have time for; each one is useful on its own.

**Before starting:** close the PowerShell tools if any are open. They and SignalRGB both
stream to the strip and will fight over it. The strip's HTTP server also dislikes .NET
connection pooling, so `Invoke-WebRequest` can fail against it while SignalRGB is running —
that is a client artefact, not the device being down.

Record the result of each step. A test you did not write down is a test you will re-run.

---

## Level 0 — Smoke test  (2 min, no side effects)

The strip is already installed and paired. Confirm nothing is broken.

| # | Step | Expected |
|---|---|---|
| 0.1 | Open SignalRGB, look at the device list | Strip present, 41 zones |
| 0.2 | Apply any effect | All 41 zones follow it |
| 0.3 | Watch an effect that sweeps left→right | Direction matches your other devices, not mirrored |
| 0.4 | Check the log | `extControl active, streaming 41 zones` |
| 0.5 | Check the log for errors | No `ReferenceError`, no `Unknown Device Type` |

If 0.4 is missing, arming failed silently — see Troubleshooting.

---

## Level 1 — Settings matrix  (5 min, fully reversible)

Every `ControllableParameters` entry, one at a time. This is the level that catches the
class of bug that bit us twice: **a setting that silently produces black instead of
failing loudly.**

| # | Setting | Action | Expected |
|---|---|---|---|
| 1.1 | Lighting Mode | Set to **Forced**, colour red | Whole strip solid red |
| 1.2 | Forced Color | Change to green, then to white | Follows immediately; **white must be white, not off** |
| 1.3 | Lighting Mode | Back to **Canvas** | Effects resume |
| 1.4 | Update rate | 10 → 20 → 30 → 45 fps | Visibly smoother as it rises; no stutter or dropout at 45 |
| 1.5 | Flip direction | Toggle **on** | Effects run the opposite way |
| 1.6 | Flip direction | Toggle back **off** | Correct direction restored (off is correct for a normally-mounted strip) |
| 1.7 | Transition | Set to 5, run a fast effect | Colours visibly smear/lag |
| 1.8 | Transition | Back to 0 | Instant response again |
| 1.9 | Turn OFF on shutdown | Enable, quit SignalRGB | Strip goes dark and stays dark |
| 1.10 | Turn OFF on shutdown | Disable, quit SignalRGB | Strip goes dark but the device stays powered |

> 1.2 matters most. `Forced` was shipped broken — it turned the strip black, silently,
> because an undefined value ANDed to zero. Any setting that produces black without an
> error deserves suspicion.

---

## Level 2 — Fresh SignalRGB install  (10 min, reversible)

Simulates a new user who already has a token. Touches nothing on the strip.

1. In the plugin panel, press **Forget** on the strip.
   - Expected: it disappears from the list; its stored token is cleared.
2. Restart SignalRGB.
   - Expected: the strip reappears **on its own** via mDNS on `_ltpdu._tcp`.
   - Log should show `mDNS record:` followed by the record contents.
   - If it does not appear, discovery is broken — note it and add by IP to continue.
3. Add it by IP if discovery did not do it.
4. Paste the token on the strip's row, press **Save**.
   - Expected: row shows `paired` and `41 zones`; the field clears.
5. Link the device and apply an effect.
   - Expected: works exactly as before.

**Recovery if this goes wrong:** the token is in `tools/magrgb-token.json`. Re-paste it.

---

## Level 3 — Full pairing cycle  (15 min, reversible but fiddly)

The path every new user takes. This is the one that has never been tested end to end.

1. Revoke the token on the device:
   ```powershell
   Invoke-WebRequest -Uri "http://<ip>:16021/api/v1/<token>" -Method Delete -UseBasicParsing
   ```
   Expect HTTP 204. The strip now has no valid credential.
2. Confirm it is really gone — a request with that token should now fail:
   ```powershell
   Invoke-WebRequest -Uri "http://<ip>:16021/api/v1/<token>/state" -UseBasicParsing
   ```
   Expect 401.
3. Delete `tools/magrgb-token.json`, and press **Forget** in the plugin panel.
4. Run the setup script from zero:
   ```powershell
   powershell -ExecutionPolicy Bypass -File tools\magrgb-setup.ps1
   ```
   - Expected: finds the strip by mDNS, prints IP / model / firmware.
   - While it polls: Nanoleaf Desktop → strip → **Enable API** ON → **Connect to API**.
   - Expected: a token is obtained, saved, and the colour test runs.
5. **Also test the plugin's own auto-pairing**, which is the path most users take:
   - Revoke again (step 1), delete the token file, **Forget** the strip.
   - Add the strip by IP in the panel, leave the token field empty.
   - Do the Nanoleaf Desktop dance again.
   - Expected: the plugin captures the token by itself within a few seconds and announces.
   - Log: `Paired with <ip>` then `41 zones`.

**Recovery:** if no token can be obtained at all, `Enable API` is off. Turn it on *before*
pressing `Connect to API`; pressing only the second gives HTTP 403.

---

## Level 4 — Resilience  (10 min)

Failure modes a normal user will hit within their first week.

| # | Scenario | Expected |
|---|---|---|
| 4.1 | Power-cycle the strip (unplug 10 s) | Lighting resumes on its own within ~10 s — the re-arm loop recovers it |
| 4.2 | Restart SignalRGB | Strip reappears and works; no re-pairing |
| 4.3 | Reboot the PC | Same |
| 4.4 | Open Nanoleaf Desktop and start Screen Mirror | The two fight over the stream; expected, documented. Close it and SignalRGB recovers |
| 4.5 | Change an effect while streaming | No stutter, no dropped frames |
| 4.6 | Leave it running 30+ min | Still streaming, no drift, no log spam |

4.1 is the important one: it proves the token survives a power cycle on the device side,
which is asserted in the README but has never actually been verified.

---

## Level 5 — Destructive  (only if something above cannot be reproduced)

A factory reset is the only true clean slate, and it costs the most: the strip must be
re-provisioned onto Wi-Fi through the Nanoleaf **mobile** app, and everything above redone.
Do not do this to satisfy curiosity — only to reproduce a bug that survives Level 3.

---

## Known untested

Carry these forward until someone has actually checked them.

- **`FALLBACK_ZONES = 41`** for any model not in `MODEL_ZONES` is a guess. It is right for
  the NL72S2 and unverified for anything else, including the MAGRGB XL.
- **Multiple strips at once.** Tokens are stored per IP and the UI is per row, but two
  devices have never been driven simultaneously.
- **A second Nanoleaf Essentials device** on the same network — discovery filters on
  `_ltpdu._tcp`, which every Essentials-class device advertises, so a Nanoleaf bulb would
  also be picked up and would then be driven with the wrong zone count.
- **Behaviour when the token is revoked while streaming.** The code logs and stops arming,
  but the UDP stream keeps going into the void.

---

## Troubleshooting

| Symptom | Cause |
|---|---|
| No `extControl active` in the log | Arming failed. Check the token; 401/403 means it is dead |
| Strip frozen on one colour | `Render()` is throwing. Look for a `ReferenceError` in the log |
| Strip goes black on a setting change | A property is resolving to a non-indexable value. Same class as the `hexToRgb` bug |
| Nothing auto-discovers | SignalRGB's own Nanoleaf addon claims `_nanoleafapi`; we use `_ltpdu` to avoid it. If that also fails, add by IP |
| Setup script finds nothing | A VPN adapter was picked. Pass `-LocalIp <your LAN IP>` |
| `Invoke-WebRequest` fails but the strip works | .NET connection pooling against the strip's embedded server. Not a device fault |
