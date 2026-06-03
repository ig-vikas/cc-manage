import os
import requests
import socket
import subprocess
import sys
import time
from pathlib import Path

from api_test_common import get_google_api_key


HOST = "127.0.0.1"
PORT = int(os.environ.get("GEMINI_PROXY_PORT", "18000"))
PROXY_URL = f"http://{HOST}:{PORT}/v1/messages"
PROXY_SCRIPT = Path.home() / ".claude-profiles" / "proxy" / "anthropic-gemini-proxy.js"

DEFAULT_MODELS = [
    "gemini-2.5-flash",
    "gemini-2.0-flash",
    "gemini-2.0-flash-lite",
    "gemini-1.5-flash",
]


def port_is_open() -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.settimeout(0.5)
        return sock.connect_ex((HOST, PORT)) == 0


def start_proxy_if_needed() -> subprocess.Popen | None:
    if port_is_open():
        print(f"Using existing local Gemini proxy on {HOST}:{PORT}")
        return None
    if not PROXY_SCRIPT.exists():
        raise RuntimeError(f"Proxy script not found: {PROXY_SCRIPT}")

    print(f"Starting local Gemini proxy on {HOST}:{PORT}")
    process = subprocess.Popen(
        [os.environ.get("NODE_EXE", "node"), str(PROXY_SCRIPT), str(PORT)],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    for _ in range(30):
        if port_is_open():
            return process
        if process.poll() is not None:
            output = process.stdout.read() if process.stdout else ""
            raise RuntimeError(f"Proxy exited early: {output.strip()}")
        time.sleep(0.2)
    process.terminate()
    raise RuntimeError("Timed out waiting for local Gemini proxy to start")


def test_gemini_models(models_to_test: list[str] = DEFAULT_MODELS) -> list[str]:
    headers = {
        "x-api-key": get_google_api_key(),
        "anthropic-version": "2023-06-01",
        "Content-Type": "application/json"
    }

    working_models = []

    for model in models_to_test:
        print(f"Testing {model} via Local Gemini Proxy...")
        
        data = {
            "model": model,
            "max_tokens": 120,
            "messages": [{"role": "user", "content": "Reply with exactly and only this word: WORKING"}]
        }

        try:
            response = requests.post(PROXY_URL, headers=headers, json=data, timeout=60)
            if response.status_code == 200:
                content_blocks = response.json().get("content", [])
                text_response = next((block.get("text", "") for block in content_blocks if block.get("type") == "text"), "").strip()
                if text_response:
                    print(f"[OK] {model} responded: {text_response}")
                    working_models.append(model)
                else:
                    print(f"[FAIL] {model}: HTTP 200 but no text content - {response.text[:500]}")
            else:
                print(f"[FAIL] {model}: HTTP {response.status_code} - {response.text[:200]}")
        except Exception as e:
            print(f"[FAIL] {model}: {e}")

    print("\n--- RESULTS ---")
    print("Working models:")
    for m in working_models:
        print(f" - {m}")
    return working_models

if __name__ == "__main__":
    proxy_process = start_proxy_if_needed()
    try:
        successes = test_gemini_models(sys.argv[1:] or DEFAULT_MODELS)
    finally:
        if proxy_process is not None and proxy_process.poll() is None:
            proxy_process.terminate()
            proxy_process.wait(timeout=5)
    raise SystemExit(0 if successes else 1)
