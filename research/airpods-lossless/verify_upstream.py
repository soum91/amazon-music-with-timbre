#!/usr/bin/env python3
"""Check the source pin, then run a selected offline upstream test or demo.

Requires a local openulla checkout. Does not download or install anything.
"""
import argparse
import hashlib
import json
from pathlib import Path
import runpy
import sys


def deny_network(event, args):
    if event in ("socket.__new__", "socket.connect", "subprocess.Popen", "os.system"):
        raise RuntimeError("network/process creation disabled for offline verification")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("checkout", type=Path)
    parser.add_argument("--demo", choices=("accepted", "busy"))
    args = parser.parse_args()
    root = args.checkout.resolve()
    lock = json.loads(Path(__file__).with_name("upstream-lock.json").read_text())
    for name, expected in lock["files"].items():
        path = root / name
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            parser.error(f"source pin mismatch: {name}; use commit {lock['commit']}")
    sys.path.insert(0, str(root))
    sys.addaudithook(deny_network)
    if args.demo:
        sys.argv = ["ulla_demo.py"] + (["--reject", "busy"] if args.demo == "busy" else [])
        runpy.run_path(str(root / "tools/ulla_demo.py"), run_name="__main__")
        return 0
    try:
        import pytest
    except ImportError:
        parser.error("pytest is required for tests; the demos need only Python 3.11+")
    return pytest.main(["-q", "-p", "no:cacheprovider", *[
        str(root / "tests" / name) for name in (
            "test_end_to_end.py", "test_hci.py", "test_aap.py", "test_session.py")]])


if __name__ == "__main__":
    raise SystemExit(main())
