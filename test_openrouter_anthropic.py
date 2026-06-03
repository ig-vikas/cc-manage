import os
import sys

from anthropic import Anthropic

from api_test_common import anthropic_message_text, get_openrouter_api_key


DEFAULT_MODELS = [
    "baidu/cobuddy:free",
    "qwen/qwen3-coder:free",
    "meta-llama/llama-3.3-70b-instruct:free",
    "meta-llama/llama-3.2-3b-instruct:free",
    "nousresearch/hermes-3-llama-3.1-405b:free",
]


def test_models(models_to_test: list[str]) -> list[str]:
    client = Anthropic(
        api_key=get_openrouter_api_key(),
        base_url=os.environ.get("OPENROUTER_ANTHROPIC_BASE_URL", "https://openrouter.ai/api"),
        timeout=30.0,
        max_retries=0,
    )

    working_models = []

    for model in models_to_test:
        print(f"Testing {model} via Anthropic SDK...", flush=True)
        try:
            message = client.messages.create(
                max_tokens=50,
                messages=[
                    {
                        "role": "user",
                        "content": "Reply with only the word 'WORKING'."
                    }
                ],
                model=model,
            )
            print(f"[OK] {model} responded: {anthropic_message_text(message)}")
            working_models.append(model)
        except Exception as e:
            print(f"[FAIL] {model}: {e}")

    print("\n--- RESULTS ---")
    print("Working models:")
    for m in working_models:
        print(f" - {m}")
    return working_models


if __name__ == "__main__":
    models = sys.argv[1:] or DEFAULT_MODELS
    successes = test_models(models)
    raise SystemExit(0 if successes else 1)
