import os
import requests

from api_test_common import get_openrouter_api_key


def test_models():
    url = "https://openrouter.ai/api/v1/chat/completions"
    headers = {
        "Authorization": f"Bearer {get_openrouter_api_key()}",
        "Content-Type": "application/json"
    }

    models_to_test = [
        "meta-llama/llama-3.3-70b-instruct:free",
        "meta-llama/llama-3.2-3b-instruct:free",
        "qwen/qwen3-coder:free",
        "nousresearch/hermes-3-llama-3.1-405b:free",
    ]

    working_models = []

    for model in models_to_test:
        print(f"Testing {model}...")
        try:
            data = {
                "model": model,
                "messages": [{"role": "user", "content": "Reply with only the word 'WORKING'."}]
            }
            response = requests.post(url, headers=headers, json=data, timeout=60)
            if response.status_code == 200:
                print(f"[OK] {model} responded: {response.json()['choices'][0]['message']['content']}")
                working_models.append(model)
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
    raise SystemExit(0 if test_models() else 1)
