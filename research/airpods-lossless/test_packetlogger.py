import io
import struct
import unittest

from capture_triage import analyze


def packet(kind, data):
    body = struct.pack(">II", 123, 999999) + bytes([kind]) + data
    return struct.pack(">I", len(body)) + body


class PacketLoggerTests(unittest.TestCase):
    def test_candidate_and_reply_not_lossless(self):
        data = packet(0, bytes.fromhex("79 ff 01 05"))
        data += packet(1, bytes.fromhex("0e 04 01 79 ff 00"))
        report = analyze(io.BytesIO(data))
        self.assertEqual(report["ulla_candidate_commands"], {"allowed_bands": 1})
        self.assertEqual(report["ulla_command_replies"], {"complete 0xFF79 status 0x00": 1})
        self.assertFalse(report["lossless_audio_verified"])

    def test_clipped_acl_payload_is_flagged(self):
        report = analyze(io.BytesIO(packet(2, bytes.fromhex("01 20 90 03 00"))))
        self.assertEqual(report["quality"]["truncated_records"], 1)
        self.assertEqual(report["commands"], {})

    def test_notes_not_leaked_or_interpreted(self):
        report = analyze(io.BytesIO(packet(252, b"private-address-and-serial")))
        self.assertNotIn("private-address-and-serial", str(report))
        self.assertEqual(report["commands"], {})

    def test_bad_record_containers_fail(self):
        valid = packet(0, bytes.fromhex("52 fe 00"))
        bad_micros = struct.pack(">III", 12, 123, 1000000) + bytes.fromhex("00 52 fe 00")
        for data in (valid[:-1], valid[:3], struct.pack(">I", 8), bad_micros):
            with self.subTest(data=data), self.assertRaises(ValueError):
                analyze(io.BytesIO(data))
