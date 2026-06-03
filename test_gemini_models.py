import os
import sys
from dotenv import load_dotenv
from google import genai

from api_test_common import get_google_api_key

# Load environment variables from .env file
load_dotenv()

# Initialize the new Google GenAI client
client = genai.Client(api_key=get_google_api_key())

CANDIDATE_MODELS = [
    "gemini-3.5-flash",
    "gemini-3-flash-preview",
    "gemini-3.1-flash-lite",
    "gemini-3.1-flash-lite-preview",
    "gemini-2.5-flash",
    "gemini-2.5-pro",
    "gemini-2.0-flash",
    "gemini-2.0-flash-lite",
    "gemini-1.5-flash",
    "gemini-1.5-pro",
]


def short_model_name(name: str) -> str:
    return name.removeprefix("models/")


def list_available_models() -> dict[str, object]:
    """Dynamically list all available models in AI Studio."""
    print("--- Available Models in AI Studio ---")
    available = {}
    try:
        for model in client.models.list():
            short_name = short_model_name(model.name)
            actions = getattr(model, "supported_actions", None) or []
            if "generateContent" in actions:
                available[short_name] = model
                print(f"- {short_name}")
    except Exception as e:
        print(f"Failed to list models: {e}")
    print("-------------------------------------\n")
    return available


def test_models(models_to_test, prompt) -> list[str]:
    """Test a specific list of models with a given prompt."""
    print(f"Testing Prompt: '{prompt}'\n")
    print("=" * 50)
    working_models = []
    for model_name in models_to_test:
        print(f"Testing Model: {model_name}")
        try:
            response = client.models.generate_content(
                model=model_name,
                contents=prompt
            )
            print(f"Response:\n{response.text.strip()}")
            working_models.append(model_name)
        except Exception as e:
            # This handles models that might lack access or quota limits
            print(f"[Error testing {model_name}]: {e}")
        print("=" * 50 + "\n")
    return working_models

if __name__ == "__main__":
    # 1. Print all currently active models for your API key
    available_models = list_available_models()

    requested_models = sys.argv[1:]
    target_models = requested_models or [model for model in CANDIDATE_MODELS if model in available_models]
    if not target_models:
        target_models = list(available_models.keys())[:3]

    test_prompt = "Hello! Please reply with a single concise sentence acknowledging my prompt."

    successes = test_models(target_models, test_prompt)
    raise SystemExit(0 if successes else 1)
