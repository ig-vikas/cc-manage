from __future__ import annotations

import os
import re
from pathlib import Path
from typing import Iterable

from dotenv import load_dotenv


REPO_ROOT = Path(__file__).resolve().parents[1]
CLAUDE_PROFILES_DIR = Path(
    os.environ.get("CLAUDE_PROFILES_DIR", Path.home() / ".claude-profiles" / "profiles")
)


def load_local_env() -> None:
    load_dotenv(REPO_ROOT / ".env", override=False)


def read_profile_value(profile_name: str, variable: str) -> str | None:
    profile_path = CLAUDE_PROFILES_DIR / f"{profile_name}.ps1"
    if not profile_path.exists():
        return None

    pattern = re.compile(
        rf"^\s*\$script:{re.escape(variable)}\s*=\s*['\"]([^'\"]+)['\"]",
        re.IGNORECASE,
    )
    for line in profile_path.read_text(encoding="utf-8").splitlines():
        match = pattern.match(line)
        if match:
            return match.group(1)
    return None


def get_secret(
    env_names: Iterable[str],
    profile_names: Iterable[str],
    *,
    variable: str = "API_KEY",
    label: str = "API key",
) -> str:
    load_local_env()
    for env_name in env_names:
        value = os.environ.get(env_name)
        if value:
            return value.strip()

    for profile_name in profile_names:
        value = read_profile_value(profile_name, variable)
        if value:
            return value.strip()

    env_list = ", ".join(env_names)
    profile_list = ", ".join(profile_names)
    raise RuntimeError(
        f"Missing {label}. Set one of [{env_list}] in .env/environment "
        f"or add {variable} to one of these Claude profiles: [{profile_list}]."
    )


def get_openrouter_api_key() -> str:
    return get_secret(
        ("OPENROUTER_API_KEY", "OPENROUTER_KEY"),
        ("api-test-openrouter-working", "1219-openrouter-cobuddy", "1219-openrouter-free"),
        label="OpenRouter API key",
    )


def get_google_api_key() -> str:
    return get_secret(
        ("GOOGLE_API_KEY", "GEMINI_API_KEY"),
        ("api-test-gemini-working", "1219-gemini-tested", "1219-gemini"),
        label="Google Gemini API key",
    )


def anthropic_message_text(message) -> str:
    chunks: list[str] = []
    for block in getattr(message, "content", []) or []:
        text = getattr(block, "text", None)
        if text is not None:
            chunks.append(text)
        elif isinstance(block, dict) and block.get("type") == "text":
            chunks.append(str(block.get("text", "")))
    return "".join(chunks).strip()
