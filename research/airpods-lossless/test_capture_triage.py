import io
import struct
import unittest

from capture_triage import analyze


def capture(*packets, link=1002):
    result = b"btsnoop\0" + struct.pack(">II", 1, link)
    for payload, flags in packets:
        result += struct.pack(">IIIIQ", len(payload), len(payload), flags, 0, 0) + payload
    return result


class CaptureTests(unittest.TestCase):
    def test_setup_ack_and_mode_are_evidence_not_audio(self):
        blob = capture((bytes.fromhex("01 50 fe 07 0b 00 00 00 01 03 00"), 2),
                       (bytes.fromhex("04 0e 04 01 50 fe 00"), 3),
                       (bytes.fromhex("04 ff 07 00 0a 0b 00 01 00 ff"), 3))
        report = analyze(io.BytesIO(blob))
        self.assertEqual(report["ulla_candidate_commands"], {"transition_request": 1})
        self.assertEqual(report["ulla_command_replies"], {"complete 0xFE50 status 0x00": 1})
        self.assertEqual(len(report["candidate_mode_reports"]), 1)
        self.assertFalse(report["lossless_audio_verified"])

    def test_bluez_monitor_and_command_status(self):
        report = analyze(io.BytesIO(capture((bytes.fromhex("52 fe 00"), 2),
                         (bytes.fromhex("0f 04 0c 01 52 fe"), 3), link=2001)))
        self.assertEqual(report["ulla_candidate_commands"], {"stream_start_request": 1})
        self.assertEqual(report["ulla_command_replies"], {"status 0xFE52 status 0x0C": 1})

    def test_packet_size_is_not_ulla_proof(self):
        report = analyze(io.BytesIO(capture((bytes.fromhex("01 02 fd 01 01"), 2))))
        self.assertEqual(report["commands"], {"0xFD02": 1})
        self.assertEqual(report["ulla_candidate_commands"], {})

    def test_payload_signature_does_not_count_as_command(self):
        report = analyze(io.BytesIO(capture((bytes.fromhex("02 50 fe 00"), 0))))
        self.assertEqual(report["ulla_candidate_commands"], {})

    def test_malformed_hci_is_counted(self):
        report = analyze(io.BytesIO(capture((bytes.fromhex("01 50 fe 07 00"), 2))))
        self.assertEqual(report["quality"]["malformed_hci_packets"], 1)
        self.assertEqual(report["commands"], {})

    def test_cut_packet_is_not_interpreted(self):
        blob = b"btsnoop\0" + struct.pack(">II", 1, 1002)
        blob += struct.pack(">IIIIQ", 11, 4, 2, 4, 0) + bytes.fromhex("01 50 fe 07")
        report = analyze(io.BytesIO(blob))
        self.assertEqual(report["quality"]["truncated_records"], 1)
        self.assertEqual(report["quality"]["maximum_reported_cumulative_drops"], 4)
        self.assertEqual(report["commands"], {})

    def test_bad_containers_fail_explicitly(self):
        valid = capture((bytes.fromhex("01 52 fe 00"), 2))
        for blob in (b"", b"x" * 16, valid[:-1], valid[:20],
                     b"btsnoop\0" + struct.pack(">II", 2, 1002),
                     b"btsnoop\0" + struct.pack(">II", 1, 999),
                     valid[:16] + struct.pack(">IIIIQ", 2, 3, 0, 0, 0)):
            with self.subTest(blob=blob), self.assertRaises(ValueError):
                analyze(io.BytesIO(blob))

    def test_report_does_not_leak_acl_payload(self):
        secret = b"private-address-and-audio"
        report = analyze(io.BytesIO(capture((b"\x02" + secret, 0))))
        self.assertNotIn(secret.decode(), str(report))


if __name__ == "__main__":
    unittest.main()
