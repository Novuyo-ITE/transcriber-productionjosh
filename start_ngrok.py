"""
start_ngrok.py
--------------
Starts a secure public ngrok tunnel to the local Django server (port 8000)
using the NGROK authtoken configured in .env.
"""

import os
import sys
import time
from pathlib import Path
from dotenv import load_dotenv, find_dotenv
from pyngrok import ngrok, conf

# Load environment variables from .env
load_dotenv(find_dotenv())

PORT = int(os.getenv("PORT", "8000"))
AUTHTOKEN = (os.getenv("NGROK_AUTHTOKEN") or os.getenv("NGROK_AUTH_TOKEN") or "").strip()
URL_FILE = Path(__file__).resolve().parent / "data" / "ngrok_url.txt"


def main():
    print("=" * 65, flush=True)
    print("  NSSF Uganda ChatBot - Public ngrok Tunnel Launcher", flush=True)
    print("=" * 65, flush=True)

    if not AUTHTOKEN:
        print("[ngrok] ERROR: NGROK_AUTHTOKEN not found in .env file.", flush=True)
        sys.exit(1)

    # 1. Set Authtoken
    print("[ngrok] Authenticating with NGROK_AUTHTOKEN from .env...", flush=True)
    ngrok.set_auth_token(AUTHTOKEN)

    # 2. Open HTTP Tunnel
    print(f"[ngrok] Opening public tunnel to http://127.0.0.1:{PORT} ...", flush=True)
    try:
        tunnel = ngrok.connect(PORT, "http")
        public_url = tunnel.public_url
        if public_url.startswith("http://"):
            secure_url = public_url.replace("http://", "https://")
        else:
            secure_url = public_url

        URL_FILE.parent.mkdir(parents=True, exist_ok=True)
        with open(URL_FILE, "w", encoding="utf-8") as f:
            f.write(secure_url.strip())

        print("\n" + "=" * 65, flush=True)
        print("  PUBLIC SHAREABLE NGROK LINK:", flush=True)
        print(f"  --> {secure_url}", flush=True)
        print("=" * 65 + "\n", flush=True)
        print("Tunnel is LIVE and active 24/7.", flush=True)

        # Keep alive loop
        while True:
            time.sleep(30)

    except KeyboardInterrupt:
        print("\n[ngrok] Shutting down tunnel...", flush=True)
        ngrok.kill()
        sys.exit(0)
    except Exception as e:
        print(f"[ngrok] Error starting tunnel: {e}", flush=True)
        sys.exit(1)


if __name__ == "__main__":
    main()
