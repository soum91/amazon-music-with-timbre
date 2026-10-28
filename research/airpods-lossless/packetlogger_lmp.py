#!/usr/bin/env python3
"""Offline candidate LMP wrapper decoder; output excludes addresses/raw PDUs.

The wrapper offsets are inferred, not an Apple specification. Require exact
length agreement and the observed low-three-bit marker before interpreting it.
LMP packet-table signatures: openulla 454cc316c838a43389d43379668556fcb0730634,
docs/protocol.md section 5.13. Table agreement is not lossless audio proof.
"""
import argparse
from collections import Counter
import json
import struct


def unwrap(data):
    if len(data) < 10 or data[0] not in (0, 1):
        return None
    offset = 9 if data[0] == 0 else 12
    if len(data) <= offset:
        return None
    if data[0] == 1 and data[9:12] != bytes(3):
        return None
    length = data[offset] >> 3
    if data[offset] & 7 != 7 or length == 0 or len(data) != offset + 1 + length:
        return None
    return data[0], data[5:9], data[offset + 1:]


def analyze(stream):
    counts = Counter()
    pending = {}
    peers = set()
    while True:
        header = stream.read(4)
        if not header:
            break
        if len(header) != 4:
            raise ValueError("truncated PacketLogger length")
        length = struct.unpack(">I", header)[0]
        if not 9 <= length <= 4 * 1024 * 1024:
            raise ValueError("invalid PacketLogger length")
        body = stream.read(length)
        if len(body) != length:
            raise ValueError("truncated PacketLogger record")
        if body[8] != 0x0A:
            continue
        counts["type_0a_records"] += 1
        result = unwrap(body[9:])
        if result is None:
            counts["unrecognized_type_0a_wrappers"] += 1
            continue
        direction, peer, pdu = result
        peers.add(peer)
        counts["validated_candidate_wrappers"] += 1
        tid = pdu[0] & 1
        key = peer, tid
        if pdu[0] >> 1 != 0x7B or len(pdu) < 2:
            continue
        if pdu[1] == 0x0D and len(pdu) == 3:
            pending[key] = direction, pdu[2]
            counts[f"table_request_{'out' if direction == 0 else 'in'}_{pdu[2]}"] += 1
        elif pdu[1] in (1, 2) and pdu[2:4] == bytes([0x7B, 0x0D]):
            if len(pdu) != (4 if pdu[1] == 1 else 5):
                continue
            request = pending.get(key)
            if request is None or request[0] == direction:
                counts["unmatched_table_replies"] += 1
                continue
            del pending[key]
            if pdu[1] == 1:
                counts[f"accepted_request_table_{request[1]}"] += 1
            else:
                counts[f"rejected_request_table_{request[1]}_reason_0x{pdu[4]:02X}"] += 1
    return {
        "counts": dict(sorted(counts.items())),
        "peer_prefix_groups": len(peers),
        "limits": ["Wrapper layout is inferred and checked for exact length agreement.",
                   "Four-byte peer prefixes may collide; this is not full device identity.",
                   "Accepted table requests do not prove active packet use, codec or lossless delivery."],
        "lossless_audio_verified": False,
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture")
    args = parser.parse_args()
    with open(args.capture, "rb") as stream:
        print(json.dumps(analyze(stream), indent=2))
