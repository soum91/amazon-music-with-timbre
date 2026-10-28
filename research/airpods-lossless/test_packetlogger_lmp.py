import io
import struct
import unittest

from packetlogger_lmp import analyze, unwrap


def frame(direction, pdu, peer=b"\x11\x22\x33\x44"):
    wrapper = bytes([direction]) + bytes(4) + peer
    if direction == 1:
        wrapper += bytes(3)
    wrapper += bytes([(len(pdu) << 3) | 7]) + pdu
    body = bytes(8) + b"\x0a" + wrapper
    return struct.pack(">I", len(body)) + body


class LmpTests(unittest.TestCase):
    def test_collision_does_not_cancel_other_transaction(self):
        capture = frame(1, bytes.fromhex("f7 0d 02"))
        capture += frame(0, bytes.fromhex("f6 0d 02"))
        capture += frame(0, bytes.fromhex("f7 02 7b 0d 23"))
        capture += frame(1, bytes.fromhex("f6 01 7b 0d"))
        report = analyze(io.BytesIO(capture))
        self.assertEqual(report["counts"]["accepted_request_table_2"], 1)
        self.assertEqual(report["counts"]["rejected_request_table_2_reason_0x23"], 1)
        self.assertFalse(report["lossless_audio_verified"])
        self.assertNotIn("11223344", str(report))

    def test_acceptance_from_other_peer_is_not_matched(self):
        capture = frame(0, bytes.fromhex("f6 0d 02"))
        capture += frame(1, bytes.fromhex("f6 01 7b 0d"), peer=bytes(4))
        report = analyze(io.BytesIO(capture))
        self.assertNotIn("accepted_request_table_2", report["counts"])
        self.assertEqual(report["counts"]["unmatched_table_replies"], 1)

    def test_malformed_wrappers_are_not_interpreted(self):
        valid = frame(0, bytes.fromhex("f6 0d 02"))[13:]
        self.assertIsNotNone(unwrap(valid))
        self.assertIsNone(unwrap(valid[:-1]))
        self.assertIsNone(unwrap(valid[:9] + b"\x18" + valid[10:]))

    def test_truncated_file_is_rejected(self):
        with self.assertRaises(ValueError):
            analyze(io.BytesIO(frame(0, bytes.fromhex("f6 0d 02"))[:-1]))
