import os
import sys

from anthropic import Anthropic

from api_test_common import anthropic_message_text, get_openrouter_api_key


def test_single(model: str = "baidu/cobuddy:free") -> bool:
    client = Anthropic(
        api_key=get_openrouter_api_key(),
        base_url=os.environ.get("OPENROUTER_ANTHROPIC_BASE_URL", "https://openrouter.ai/api"),
        timeout=30.0,
        max_retries=0,
    )

    print(f"Testing {model} via Anthropic SDK...")
    try:
        message = client.messages.create(
            max_tokens=50,
            messages=[{"role": "user", "content": "Reply with only the word 'WORKING'."}],
            model=model,
        )
        print(f"[OK] {model} responded: {anthropic_message_text(message)}")
        return True
    except Exception as e:
        print(f"[FAIL] {model}: {e}")
        return False

if __name__ == "__main__":
    raise SystemExit(0 if test_single(*(sys.argv[1:] or [])) else 1)
