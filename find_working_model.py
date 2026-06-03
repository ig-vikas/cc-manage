import os
import requests
import json

from api_test_common import get_openrouter_api_key


def find_working_model(limit: int = 25):
    headers = {
        "Authorization": f"Bearer {get_openrouter_api_key()}",
        "Content-Type": "application/json"
    }

    print("Fetching list of all free models from OpenRouter...")
    try:
        r = requests.get("https://openrouter.ai/api/v1/models", timeout=60)
        data = r.json().get('data', [])
        free_models = [m['id'] for m in data if m['pricing']['prompt'] == '0']
    except Exception as e:
        print("Failed to fetch models:", e)
        return

    print(f"Found {len(free_models)} free models. Testing them now...")
    
    url = "https://openrouter.ai/api/v1/chat/completions"
    
    working = []

    for model in free_models[:limit]:
        print(f"Testing {model}...", end=" ")
        payload = {
            "model": model,
            "messages": [{"role": "user", "content": "Reply with 'WORKING'."}]
        }
        resp = requests.post(url, headers=headers, json=payload, timeout=60)
        if resp.status_code == 200:
            print("SUCCESS! ->", resp.json()['choices'][0]['message']['content'].strip())
            working.append(model)
            if len(working) >= 1:
                break
        else:
            err = resp.text
            try:
                err = json.loads(err)['error']['message']
            except:
                pass
            if 'rate-limited' in err:
                print("FAIL (Rate limited upstream)")
            else:
                print(f"FAIL ({resp.status_code}: {err[:50]})")

    print("\nWorking Models:")
    print(working)
    return working
    
if __name__ == "__main__":
    raise SystemExit(0 if find_working_model() else 1)
