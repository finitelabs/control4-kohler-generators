"""Run a mock of the KOHLER home-generator cloud.

Examples:
  python -m mock_kohler --config instances/demo.json
  python -m mock_kohler --config instances/demo.json --port 18443 --tls --speed 60
  python -m mock_kohler --list

One process plays the whole service on one port: the token endpoint
(/oauth2/default/v1/token), the homeowner API (/kem/api/v3/...) and the control API under
/_mock/ (GET /_mock lists the actions).

A config file names the client and API key the mock accepts, the accounts, their homes and
generators (each a profile from profiles/ or a path) and the settings. --speed runs the
generators' clock faster: 60 makes a 20 minute exercise take 20 seconds. --tls serves HTTPS with
a self-signed certificate, made with openssl unless --cert and --key are given.
"""

import argparse
import asyncio
import json
import logging
import signal
import ssl
import subprocess
import sys
import tempfile
from pathlib import Path

from .cloud import PROFILES, Cloud, load_profile


def parse_args(argv):
    ap = argparse.ArgumentParser(
        prog="python -m mock_kohler",
        description=__doc__.split("\n\n")[0],
        epilog="\n\n".join(__doc__.split("\n\n")[1:]),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument(
        "--config", help="JSON file naming the accounts, generators and settings"
    )
    ap.add_argument(
        "--host", default=None, help="address to listen on (default 0.0.0.0)"
    )
    ap.add_argument(
        "--port", type=int, default=None, help="port (default from the config)"
    )
    ap.add_argument(
        "--speed", type=float, default=None, help="simulated seconds per second"
    )
    ap.add_argument("--tls", action="store_true", help="serve HTTPS")
    ap.add_argument("--cert", help="certificate file for --tls")
    ap.add_argument("--key", help="key file for --tls")
    ap.add_argument("--list", action="store_true", help="list the bundled profiles")
    ap.add_argument("-v", "--verbose", action="store_true")
    return ap.parse_args(argv)


def self_signed(directory):
    cert, key = Path(directory) / "cert.pem", Path(directory) / "key.pem"
    subprocess.run(
        [
            "openssl",
            "req",
            "-x509",
            "-newkey",
            "rsa:2048",
            "-nodes",
            "-days",
            "30",
            "-subj",
            "/CN=mock-kohler",
            "-keyout",
            str(key),
            "-out",
            str(cert),
        ],
        check=True,
        capture_output=True,
    )
    return str(cert), str(key)


async def run(args):
    if not args.config:
        print("no config: pass --config (see --help)", file=sys.stderr)
        return 2
    with open(args.config, encoding="utf-8") as f:
        cfg = json.load(f)
    host = args.host or cfg.get("host", "0.0.0.0")
    port = args.port or cfg.get("port", 18400)
    ctx = None
    tmp = None
    if args.tls:
        cert, key = args.cert, args.key
        if not (cert and key):
            tmp = tempfile.TemporaryDirectory()
            cert, key = self_signed(tmp.name)
        ctx = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
        ctx.load_cert_chain(cert, key)
    cloud = Cloud(cfg, speed=args.speed)
    await cloud.start(host, port, ctx)
    scheme = "https" if ctx else "http"
    print(f"mock KOHLER cloud on {scheme}://{host}:{port}", flush=True)
    for acct in cloud.accounts:
        for gen in acct.generators:
            print(f"  {acct.email}: {gen.name} ({gen.id})", flush=True)
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stop.set)
    await stop.wait()
    await cloud.stop()
    if tmp:
        tmp.cleanup()
    return 0


def main(argv=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.WARNING)
    if args.list:
        for p in sorted(PROFILES.glob("*.json")):
            prof = load_profile(p)
            print(
                f"{p.stem:24} {prof.get('modelDisplayName', ''):8} {prof.get('description', '')}"
            )
        return 0
    return asyncio.run(run(args))


if __name__ == "__main__":
    sys.exit(main())
