#!/usr/bin/env python3
"""Offline HCI inventory. Never opens a radio or claims audio is lossless.

ULLA signatures: mstampfli/openulla commit
454cc316c838a43389d43379668556fcb0730634, openulla/hci.py.
This is an independent container/inventory implementation, not a radio driver.
"""
import argparse
from collections import Counter
import json
from pathlib import Path
import struct
import sys

SIGNATURES = {
    0xFE50: "transition_request", 0xFE51: "second_setup_command",
    0xFE52: "stream_start_request", 0xFE53: "read_stream_descriptor",
    0xFE57: "stream_dma_address", 0xFE58: "stream_stop_request",
    0xFDF3: "feature_group", 0xFF77: "band_gate",
    0xFF78: "read_link_band", 0xFF79: "allowed_bands",
    0xFF7A: "allowed_bands_again", 0xFF7C: "set_link_band",
    0xFF8E: "band_ranges", 0xFF92: "country_codes_by_band",
    0xFD31: "country_code", 0xFFB3: "test_band_range",
}
MAX_RECORD = 4 * 1024 * 1024


def exact(stream, size):
    data = stream.read(size)
    if len(data) != size:
        raise ValueError("truncated capture")
    return data


def records(stream):
    header = exact(stream, 16)
    if header[:8] != b"btsnoop\0":
        raise ValueError("expected btsnoop; PacketLogger .pklg must be converted first")
    version, link = struct.unpack(">II", header[8:])
    if version != 1 or link not in (1002, 2001):
        raise ValueError("supported: btsnoop v1 H4 (1002) or BlueZ monitor (2001)")
    while True:
        raw = stream.read(24)
        if not raw:
            return
        if len(raw) != 24:
            raise ValueError("truncated record header")
        original, included, flags, drops, _ = struct.unpack(">IIIIQ", raw)
        if included > original or included > MAX_RECORD:
            raise ValueError("invalid or oversized record length")
        payload = exact(stream, included)
        cut = included < original
        if link == 1002:
            kind = {1: "command", 4: "event"}.get(payload[0] if payload else 0, "other")
            payload = payload[1:]
        else:
            kind = {2: "command", 3: "event"}.get(flags & 0xFFFF, "other")
        yield kind, payload, cut, drops


def analyze(stream):
    kinds, commands, signatures, replies, modes = (Counter() for _ in range(5))
    malformed = truncated = maximum_drops = 0
    for kind, data, cut, drops in records(stream):
        kinds[kind] += 1
        maximum_drops = max(maximum_drops, drops)
        truncated += cut
        if cut or kind == "other":
            continue
        minimum = 3 if kind == "command" else 2
        if len(data) < minimum or len(data) != minimum + data[minimum - 1]:
            malformed += 1
            continue
        if kind == "command":
            opcode = int.from_bytes(data[:2], "little")
            commands[f"0x{opcode:04X}"] += 1
            if opcode in SIGNATURES:
                signatures[SIGNATURES[opcode]] += 1
                if opcode == 0xFE50 and data[2] != 7:
                    malformed += 1
        elif data[0] == 0x0E and len(data) >= 6:  # Command Complete
            opcode = int.from_bytes(data[3:5], "little")
            if opcode in SIGNATURES:
                replies[f"complete 0x{opcode:04X} status 0x{data[5]:02X}"] += 1
        elif data[0] == 0x0F and len(data) == 6:  # Command Status
            opcode = int.from_bytes(data[4:6], "little")
            if opcode in SIGNATURES:
                replies[f"status 0x{opcode:04X} status 0x{data[2]:02X}"] += 1
        elif data[:4] == b"\xff\x07\x00\x0a" and len(data) == 9:
            modes[f"mode 0x{data[6]:02X} result 0x{data[7]:02X} reason 0x{data[8]:02X}"] += 1
    return {
        "schema": 1,
        "scope": "host-wide HCI inventory; no device attribution or audio verification",
        "records": dict(sorted(kinds.items())),
        "commands": dict(sorted(commands.items())),
        "ulla_candidate_commands": dict(sorted(signatures.items())),
        "ulla_command_replies": dict(sorted(replies.items())),
        "candidate_mode_reports": dict(sorted(modes.items())),
        "quality": {"truncated_records": truncated, "malformed_hci_packets": malformed,
                    "maximum_reported_cumulative_drops": maximum_drops},
        "lossless_audio_verified": False,
        "interpretation": [
            "Signatures use AirPods Pro 2 USB-C research; Pro 3 compatibility is unverified.",
            "Vendor opcodes can mean different things on different controllers.",
            "A request or status 0 does not prove a radio transition or lossless audio.",
            "Absent signatures do not rule out controller-internal negotiation or missed setup.",
            "No addresses, raw payloads, timestamps, or audio are included in this report.",
        ],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=Path)
    args = parser.parse_args()
    try:
        with args.capture.open("rb") as stream:
            report = analyze(stream)
    except (OSError, ValueError) as exc:
        print(f"Capture not analyzed: {exc}", file=sys.stderr)
        return 2
    print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
