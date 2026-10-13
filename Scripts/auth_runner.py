#!/usr/bin/env python3
"""Single bundled entry point for both university authentication modes.

Run this as an isolated executable built by PyInstaller. Neither Python nor
uv must be installed on users' computers; each user still needs Chrome.
"""
import argparse
import sys

import automatic_auth
import browser_auth


def main() -> int:
    parser = argparse.ArgumentParser(description="ULiège VPN authentication runtime")
    parser.add_argument("--mode", choices=("automatic", "browser"), required=True)
    parser.add_argument("--emit-session", action="store_true", help="Send authenticated session to parent process via private stdout pipe")
    args, passthrough = parser.parse_known_args()
    if args.mode == "browser":
        if passthrough:
            parser.error("Browser mode doesn't take additional options")
        return browser_auth.main(emit_session=args.emit_session)
    # automatic_auth.main uses argparse on sys.argv.
    sys.argv = [sys.argv[0], *passthrough, *(["--emit-session"] if args.emit_session else [])]
    automatic_auth.main()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
