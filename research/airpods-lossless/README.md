# AirPods lossless transport research

Started 2026-10-28. Target: investigate interoperability with Apple's proprietary
Vision Pro/AirPods wireless audio link, eventually assessing a non-jailbroken
iPhone implementation. **No lossless transmitter has been implemented.**

## Evidence and limits

| Evidence | What it establishes | What it does not establish |
| --- | --- | --- |
| [Apple's Vision Pro support page](https://support.apple.com/en-gb/118522) | AirPods Pro 3 supports lossless audio and ultra-low latency with Vision Pro | A third-party iPhone app can select that transport |
| [Apple's 2023 Pro 2 USB-C announcement](https://www.apple.com/ca/newsroom/2023/09/apple-upgrades-airpods-pro-2nd-generation-with-usb-c-charging/) | An H2/proprietary-protocol implementation delivering 20-bit/48 kHz | A 24-bit Pro 3 transport specification |
| [openulla source pin](https://github.com/mstampfli/openulla/tree/454cc316c838a43389d43379668556fcb0730634) | Public setup/state-machine implementation and reports of live Linux setup exchanges on Pro 2 USB-C | Working wireless audio transmission or verified Pro 3 compatibility |
| Our local verification below | Selected protocol tests and simulations execute correctly on this machine | The firmware interpretation is correct, a radio transition occurs, or audio plays |

Upstream studies Pro 2 USB-C firmware 9A348. Its live measurements cover the early
setup exchange; the subsequent controller/DSP progression in its demo is simulated.
Its radio audio transport remains incomplete. Accepted setup is a useful clue, not
a lossless playback result. HCI opcodes derived from an earbud controller cannot be
assumed to have the same meaning on an arbitrary host controller.

Upstream's LICENSE at this pin says MIT; pyproject.toml says Apache-2.0. We have not
vendored the upstream implementation or firmware. Resolve the metadata discrepancy
before incorporating upstream code into a distributed app.

## Work completed

- Reviewed the protocol implementation and live-versus-simulated boundaries.
- Pinned 28 upstream files by SHA-256 in `upstream-lock.json`.
- Ran the four selected upstream test modules: **59 passed** on Python 3.12.
- Ran both accepted-setup and busy-rejection demos, with socket creation and
  subprocess launch blocked by a Python audit hook. Both exited 0; accepted setup
  reached the simulated STREAM_OPEN state, busy rejection stayed at CONTROLLER_SETUP.
- Implemented `capture_triage.py`: a streaming, offline btsnoop HCI inventory with
  candidate setup/stream/band commands, command replies, mode reports and capture
  quality counters. It outputs no addresses, raw payloads, audio or timestamps.
- Ran **8 local unittest cases**, covering H4/BlueZ, truncation, malformed data,
  payload false positives, setup replies and privacy of the exported summary.

The audit hook is a guard for these inspected Python paths, not an OS sandbox.
No Bluetooth device, firmware, controller setting or Amazon app was changed.

## What we need next

1. **Device inventory:** exact iPhone/iPad model, OS version, AirPods model number and
   firmware; whether a Mac, Linux PC or Vision Pro is available. Use existing
   equipment first. A Windows PC is still useful for storing/analyzing captures.
2. **Reference evidence:** ideally a successful Vision Pro/Pro 3 connection capture,
   with hardware/OS/firmware and capture method recorded. Start before connection
   and playback. A normal iPhone connection is the comparison. An app console log
   alone cannot reveal the Bluetooth controller's radio/audio protocol.
3. **Controller access and capability:** establish whether the proposed host can
   actually select the required mode and transmit its packet format. Do not infer
   this from generic Bluetooth version, HDR reports, or the presence of a 5 GHz radio.
4. **Audio framing/clocking:** recover and validate the real payload, transport timing
   and lossless encoding against a working reference. Simulation cannot provide it.
5. **Non-jailbroken deployment:** prove an available host API/entitlement can drive
   that controller path. This remains unproven; an injected app library's PCM hook
   does not itself grant controller or firmware access.

A Vision Pro reference is the clearest next experiment, but we have not established
that it exposes the required capture interface. A Mac capture can inventory what
that Mac does; it does not substitute for a proven Vision Pro link. Do not buy SDRs,
development boards or a headset on the strength of this initial research.

## Reproduce the offline checks

From this directory, with Python 3.11+ and Git installed:

```sh
git clone https://github.com/mstampfli/openulla.git openulla-reference
git -C openulla-reference checkout --detach 454cc316c838a43389d43379668556fcb0730634
python verify_upstream.py openulla-reference --demo accepted
python verify_upstream.py openulla-reference --demo busy
```

The selected upstream tests additionally require pytest. Install it into a virtual
environment, then run:

```sh
python -m venv .venv
# Windows PowerShell:
.venv\Scripts\python.exe -m pip install pytest
$env:PYTEST_DISABLE_PLUGIN_AUTOLOAD = "1"
.venv\Scripts\python.exe verify_upstream.py openulla-reference
# macOS/Linux equivalent:
.venv/bin/python -m pip install pytest
PYTEST_DISABLE_PLUGIN_AUTOLOAD=1 .venv/bin/python verify_upstream.py openulla-reference
```

## Analyze an existing controller capture

The tool accepts btsnoop v1 H4 (1002) or BlueZ monitor (2001). It does not start
capture, connect to AirPods or send vendor commands. Native PacketLogger `.pklg`
needs conversion to supported btsnoop; it is rejected explicitly otherwise.

PowerShell:

```powershell
python .\capture_triage.py "C:\captures\airpods-connection.btsnoop" | Out-File -Encoding utf8 "$env:USERPROFILE\airpods-hci-summary.json"
```

macOS/Linux:

```sh
python3 capture_triage.py airpods-connection.btsnoop > airpods-hci-summary.json
python3 -m unittest discover -s . -p 'test_*.py' -v
```

The JSON is host-wide and does not attribute commands to a particular device.
Relevant vendor commands are candidates using Pro 2-derived signatures. Status 0,
a stream-start request or even a reported mode change never sets
`lossless_audio_verified` to true. Negative results also cannot exclude negotiation
inside a controller or a setup sequence missed by the capture.

Keep original captures locally: they may contain pairing and device information.
For this first pass, only the generated inventory and device/capture metadata are
needed. The current checker deliberately does not decode ACL/AAP audio or pairings;
use upstream's richer offline decoder when those layers become the next question.

## Decision gates

| Gate | Pass evidence | Current state |
| --- | --- | --- |
| Software baseline | Reproducible protocol tests and simulation | Passed locally, selected scope only |
| Real Pro 3 negotiation | Attributable reference capture and decoded mode sequence | Not captured |
| Host transmitter | Actual required radio packets from the proposed host | Not demonstrated |
| Lossless playback | Controlled source-to-receiver validation, not a UI rate label | Not demonstrated |
| Jailed iPhone integration | Working permitted path from app through host stack/controller | Unknown |

Amazon Home/Profile debugging and Timbre DSP are separate tasks. Changing DSP
sample rate or advertising a 24-bit buffer cannot unlock this wireless link.
