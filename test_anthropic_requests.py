import requests

from api_test_common import get_openrouter_api_key


DEFAULT_MODELS = [
    "baidu/cobuddy:free",
    "qwen/qwen3-coder:free",
    "meta-llama/llama-3.3-70b-instruct:free",
]


def test_anthropic_api(models_to_test: list[str] = DEFAULT_MODELS) -> list[str]:
    url = "https://openrouter.ai/api/v1/messages"
    headers = {
        "Authorization": f"Bearer {get_openrouter_api_key()}",
        "anthropic-version": "2023-06-01",
        "Content-Type": "application/json"
    }

    working_models = []

    for model in models_to_test:
        print(f"Testing {model} via Anthropic Messages API...")
        data = {
            "model": model,
            "max_tokens": 120,
            "messages": [{"role": "user", "content": "Reply with exactly and only this word: WORKING"}]
        }

        try:
            response = requests.post(url, headers=headers, json=data, timeout=60)
            if response.status_code == 200:
                content_blocks = response.json().get("content", [])
                text_response = next((block["text"] for block in content_blocks if block["type"] == "text"), "No text found")
                print(f"[OK] {model} responded: {text_response}")
                working_models.append(model)
            else:
                print(f"[FAIL] {model}: HTTP {response.status_code} - {response.text[:500]}")
        except Exception as e:
            print(f"[FAIL] {model}: {e}")

    print("\n--- RESULTS ---")
    print("Working models:")
    for model in working_models:
        print(f" - {model}")
    return working_models

if __name__ == "__main__":
    raise SystemExit(0 if test_anthropic_api() else 1)
