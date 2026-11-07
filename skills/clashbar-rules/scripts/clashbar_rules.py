#!/usr/bin/env python3
"""Talk to the local ClashBar custom-rule service."""

import argparse
import json
import socket
import sys
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", default=str(Path.home() / "Library/Application Support/clashbar/state/agent/rules.sock"))
    sub = parser.add_subparsers(dest="action", required=True)
    sub.add_parser("list")
    for name in ("add", "update"):
        command = sub.add_parser(name)
        command.add_argument("--revision", required=True)
        command.add_argument("--operation", choices=("add", "replace", "delete"), required=True)
        command.add_argument("--original", default="")
        command.add_argument("--value", default="")
        if name == "update":
            command.add_argument("--id", required=True)
    command = sub.add_parser("remove")
    command.add_argument("--revision", required=True)
    command.add_argument("--id", required=True)
    args = vars(parser.parse_args())
    path = args.pop("socket")
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(60)
            client.connect(path)
            client.sendall(json.dumps(args, ensure_ascii=False).encode("utf-8") + b"\n")
            with client.makefile("rb") as stream:
                line = stream.readline(8 * 1024 * 1024 + 1)
            if not line or len(line) > 8 * 1024 * 1024 or not line.endswith(b"\n"):
                raise ValueError("Invalid or oversized response from ClashBar")
            response = json.loads(line)
        print(json.dumps(response, ensure_ascii=False, indent=2))
        return 0 if response.get("ok") else 1
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(json.dumps({"ok": False, "code": "connection_error", "message": str(error)}, ensure_ascii=False), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
