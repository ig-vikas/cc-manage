from __future__ import annotations

import json
import os
import socket
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib import error, request


HOST = "127.0.0.1"
DUMMY_KEY = "test-key"
NODE_EXE = os.environ.get("NODE_EXE", "node")
PROXY_DIR = Path(os.environ.get("CLAUDE_PROFILES_ROOT", Path.home() / ".claude-profiles")) / "proxy"


class TestFailure(AssertionError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise TestFailure(message)


def free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind((HOST, 0))
        return int(sock.getsockname()[1])


def port_is_open(port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.settimeout(0.25)
        return sock.connect_ex((HOST, port)) == 0


def wait_for_proxy(process: subprocess.Popen, port: int, name: str) -> None:
    for _ in range(50):
        if port_is_open(port):
            return
        if process.poll() is not None:
            output = process.stdout.read() if process.stdout else ""
            raise TestFailure(f"{name} exited early: {output.strip()}")
        time.sleep(0.1)
    stop_process(process)
    raise TestFailure(f"{name} did not start on port {port}")


def stop_process(process: subprocess.Popen | None) -> None:
    if process is None or process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)


def start_proxy(script_name: str, port: int, extra_env: dict[str, str] | None = None) -> subprocess.Popen:
    script = PROXY_DIR / script_name
    require(script.exists(), f"Proxy script missing: {script}")

    env = os.environ.copy()
    env.update(extra_env or {})
    process = subprocess.Popen(
        [NODE_EXE, str(script), str(port)],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        env=env,
    )
    wait_for_proxy(process, port, script_name)
    return process


def http_request(
    method: str,
    url: str,
    body: object | str | None = None,
    *,
    key: str | None = DUMMY_KEY,
    timeout: float = 15.0,
) -> tuple[int, str]:
    headers = {"anthropic-version": "2023-06-01"}
    data = None
    if body is not None:
        headers["Content-Type"] = "application/json"
        data = body.encode("utf-8") if isinstance(body, str) else json.dumps(body).encode("utf-8")
    if key:
        headers["x-api-key"] = key

    req = request.Request(url, data=data, headers=headers, method=method)
    try:
        with request.urlopen(req, timeout=timeout) as response:
            return int(response.status), response.read().decode("utf-8", errors="replace")
    except error.HTTPError as exc:
        return int(exc.code), exc.read().decode("utf-8", errors="replace")


def base_anthropic_body() -> dict:
    return {
        "model": "mock-model",
        "max_tokens": 64,
        "top_p": 0.7,
        "stop_sequences": ["STOP_TEST"],
        "parallel_tool_calls": False,
        "system": [{"type": "text", "text": "You are a precise test assistant."}],
        "tools": [
            {
                "name": "read-file.path",
                "description": "Read a project file.",
                "input_schema": {
                    "type": "object",
                    "properties": {"path": {"type": "string"}},
                    "required": ["path"],
                },
            }
        ],
        "tool_choice": {"type": "tool", "name": "read-file.path"},
        "messages": [
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": "Inspect this image and then use the tool."},
                    {
                        "type": "image",
                        "source": {
                            "type": "base64",
                            "media_type": "image/png",
                            "data": "AA==",
                        },
                    },
                    {
                        "type": "document",
                        "title": "Spec",
                        "content": [{"type": "text", "text": "Document fallback text"}],
                    },
                ],
            },
            {
                "role": "assistant",
                "content": [
                    {"type": "text", "text": "I will call the tool."},
                    {"type": "thinking", "thinking": "internal note should be preserved as fallback"},
                    {
                        "type": "tool_use",
                        "id": "toolu_test123",
                        "name": "read-file.path",
                        "input": {"path": "README.md"},
                    },
                ],
            },
            {
                "role": "user",
                "content": [
                    {
                        "type": "tool_result",
                        "tool_use_id": "toolu_test123",
                        "content": [{"type": "text", "text": "README contents"}],
                    }
                ],
            },
        ],
    }


class MockOpenAIHandler(BaseHTTPRequestHandler):
    server: "MockOpenAIServer"

    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length", "0"))
        raw_body = self.rfile.read(length).decode("utf-8")
        payload = json.loads(raw_body or "{}")
        self.server.captured.append(
            {
                "path": self.path,
                "headers": dict(self.headers),
                "body": payload,
            }
        )

        if payload.get("stream"):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            chunks = [
                {"choices": [{"index": 0, "delta": {"role": "assistant"}}]},
                {"choices": [{"index": 0, "delta": {"content": "Streaming "}}]},
                {"choices": [{"index": 0, "delta": {"content": "works."}}]},
                {
                    "choices": [
                        {
                            "index": 0,
                            "delta": {
                                "tool_calls": [
                                    {
                                        "index": 0,
                                        "id": "call_stream",
                                        "type": "function",
                                        "function": {
                                            "name": "read-file_path",
                                            "arguments": "{\"path\":\"README.md\"}",
                                        },
                                    }
                                ]
                            },
                        }
                    ]
                },
                {
                    "choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}],
                    "usage": {"completion_tokens": 4},
                },
            ]
            for chunk in chunks:
                self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode("utf-8"))
            self.wfile.write(b"data: [DONE]\n\n")
            return

        response_body = {
            "id": "chatcmpl_test",
            "object": "chat.completion",
            "choices": [
                {
                    "index": 0,
                    "message": {
                        "role": "assistant",
                        "content": "Tool request converted.",
                        "tool_calls": [
                            {
                                "id": "call_test",
                                "type": "function",
                                "function": {
                                    "name": "read-file_path",
                                    "arguments": "{\"path\":\"README.md\"}",
                                },
                            }
                        ],
                    },
                    "finish_reason": "tool_calls",
                }
            ],
            "usage": {"prompt_tokens": 12, "completion_tokens": 5},
        }
        if payload.get("model") == "array-response-model":
            response_body["choices"][0]["message"]["content"] = [
                {"type": "text", "text": "Array content works."},
                {"type": "unknown_part", "value": 7},
            ]
            response_body["choices"][0]["message"]["tool_calls"][0]["function"]["arguments"] = {"path": "README.md"}
        encoded = json.dumps(response_body).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def log_message(self, fmt: str, *args: object) -> None:
        return


class MockOpenAIServer(HTTPServer):
    captured: list[dict]


def start_mock_openai() -> tuple[MockOpenAIServer, threading.Thread, int]:
    port = free_port()
    server = MockOpenAIServer((HOST, port), MockOpenAIHandler)
    server.captured = []
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, thread, port


class MockOpenCodeHandler(BaseHTTPRequestHandler):
    server: "MockOpenCodeServer"

    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length", "0"))
        raw_body = self.rfile.read(length).decode("utf-8")
        payload = json.loads(raw_body or "{}")
        self.server.captured.append(
            {
                "path": self.path,
                "headers": dict(self.headers),
                "body": payload,
            }
        )

        response_body = {
            "id": "chatcmpl_opencode_test",
            "object": "chat.completion",
            "model": "nemotron-3-ultra-free",
            "choices": [
                {
                    "index": 0,
                    "message": {"role": "assistant", "content": "OpenCode says hello."},
                    "finish_reason": "stop",
                }
            ],
            "usage": {"prompt_tokens": 200, "completion_tokens": 53},
        }
        tools = payload.get("tools") or []
        if tools:
            function_name = tools[0]["function"]["name"]
            response_body["choices"][0]["message"]["tool_calls"] = [
                {
                    "id": "call_opencode_test",
                    "type": "function",
                    "function": {
                        "name": function_name,
                        "arguments": "{\"path\":\"README.md\"}",
                    },
                }
            ]
            response_body["choices"][0]["finish_reason"] = "tool_calls"
        encoded = json.dumps(response_body).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def log_message(self, fmt: str, *args: object) -> None:
        return


class MockOpenCodeServer(HTTPServer):
    captured: list[dict]


def start_mock_opencode() -> tuple[MockOpenCodeServer, threading.Thread, int]:
    port = free_port()
    server = MockOpenCodeServer((HOST, port), MockOpenCodeHandler)
    server.captured = []
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, thread, port


def test_proxy_basic_endpoints() -> None:
    cases = [
        ("anthropic-gemini-proxy.js", {}),
        ("codestral-anthropic-proxy.js", {}),
        ("hug-anthropic-proxy.js", {}),
        ("mistral-anthropic-proxy.js", {}),
        ("mistral-vibe-anthropic-proxy.js", {}),
        ("nvidia-anthropic-proxy.js", {}),
        ("opencode-nemotron-proxy.js", {}),
        ("openrouter-anthropic-normalizer.js", {}),
        (
            "openai-chat-proxy.js",
            {
                "CC_PROVIDER": "mock-openai",
                "CC_UPSTREAM_BASE_URL": "http://127.0.0.1:9/v1",
                "CC_MODELS": "mock-model",
            },
        ),
    ]

    for script_name, env in cases:
        port = free_port()
        process = start_proxy(script_name, port, env)
        try:
            base_url = f"http://{HOST}:{port}"

            status, body = http_request("GET", f"{base_url}/v1/models")
            require(status == 200, f"{script_name} /v1/models returned {status}: {body[:200]}")
            parsed = json.loads(body)
            require(isinstance(parsed.get("data"), list), f"{script_name} models response missing data[]")

            status, body = http_request("GET", f"{base_url}/v1/models", key=None)
            require(status == 401, f"{script_name} missing-key check returned {status}")

            status, body = http_request(
                "POST",
                f"{base_url}/v1/messages/count_tokens",
                {"messages": [{"role": "user", "content": "count me"}]},
            )
            require(status == 200, f"{script_name} count_tokens returned {status}: {body[:200]}")
            require(json.loads(body).get("input_tokens", 0) > 0, f"{script_name} count_tokens was empty")

            status, body = http_request("POST", f"{base_url}/v1/messages", "{not-json")
            require(status == 400, f"{script_name} invalid JSON returned {status}: {body[:200]}")
        finally:
            stop_process(process)


def test_openai_compatible_conversion() -> None:
    server, _thread, upstream_port = start_mock_openai()
    proxy_port = free_port()
    process = start_proxy(
        "openai-chat-proxy.js",
        proxy_port,
        {
            "CC_PROVIDER": "mock-openai",
            "CC_UPSTREAM_BASE_URL": f"http://{HOST}:{upstream_port}/v1",
            "CC_MODELS": "mock-model",
        },
    )

    try:
        base_url = f"http://{HOST}:{proxy_port}"
        status, body = http_request("POST", f"{base_url}/v1/messages", base_anthropic_body())
        require(status == 200, f"non-stream conversion returned {status}: {body[:500]}")
        response = json.loads(body)
        require(response["content"][0]["type"] == "text", "Anthropic text response missing")
        tool_block = next((block for block in response["content"] if block.get("type") == "tool_use"), None)
        require(tool_block is not None, "OpenAI tool_call was not converted to Anthropic tool_use")
        require(tool_block["name"] == "read-file.path", "Sanitized tool name was not mapped back")
        require(tool_block["input"] == {"path": "README.md"}, "Tool arguments were not parsed")
        require(response["stop_reason"] == "tool_use", "Tool finish reason was not mapped")

        captured = server.captured[-1]
        upstream_body = captured["body"]
        require(captured["path"] == "/v1/chat/completions", "Wrong upstream chat completions path")
        require(captured["headers"].get("Authorization") == "Bearer test-key", "Authorization header was not forwarded")
        require(upstream_body["model"] == "mock-model", "Model was not forwarded")
        require(upstream_body["max_tokens"] == 64, "max_tokens was not forwarded")
        require(upstream_body["top_p"] == 0.7, "top_p was not forwarded")
        require(upstream_body["stop"] == ["STOP_TEST"], "stop_sequences were not converted to stop")
        require(upstream_body["parallel_tool_calls"] is False, "parallel_tool_calls was not forwarded")
        require(upstream_body["stream"] is False, "stream false was not forwarded")
        require(upstream_body["messages"][0] == {"role": "system", "content": "You are a precise test assistant."}, "System message was not converted")

        user_content = upstream_body["messages"][1]["content"]
        require(isinstance(user_content, list), "Image user content was not converted to OpenAI content parts")
        require(user_content[0] == {"type": "text", "text": "Inspect this image and then use the tool."}, "Text part was not preserved")
        require(user_content[1]["type"] == "image_url", "Image was not converted to image_url")
        require(user_content[1]["image_url"]["url"] == "data:image/png;base64,AA==", "Base64 image data URL was wrong")
        require(user_content[2]["type"] == "text", "Unknown user content was not preserved as text fallback")
        require("Document fallback text" in user_content[2]["text"], "Unknown document text was dropped")

        tool = upstream_body["tools"][0]["function"]
        require(tool["name"] == "read-file_path", "Anthropic tool name was not sanitized for OpenAI")
        require(tool["parameters"]["required"] == ["path"], "Tool JSON schema was not preserved")
        require(upstream_body["tool_choice"]["function"]["name"] == "read-file_path", "tool_choice was not converted")

        assistant_message = upstream_body["messages"][2]
        require(assistant_message["role"] == "assistant", "Assistant role was not preserved")
        require("internal note should be preserved" in assistant_message["content"], "Unknown assistant content was dropped")
        require(assistant_message["tool_calls"][0]["id"] == "toolu_test123", "tool_use id was not preserved")
        require(assistant_message["tool_calls"][0]["function"]["name"] == "read-file_path", "tool_use name was not sanitized")
        require(json.loads(assistant_message["tool_calls"][0]["function"]["arguments"]) == {"path": "README.md"}, "tool_use input was not serialized")

        tool_message = upstream_body["messages"][3]
        require(tool_message == {"role": "tool", "tool_call_id": "toolu_test123", "content": "README contents"}, "tool_result was not converted to OpenAI tool role")

        stream_body = base_anthropic_body()
        stream_body["stream"] = True
        status, stream_text = http_request("POST", f"{base_url}/v1/messages", stream_body, timeout=15)
        require(status == 200, f"stream conversion returned {status}: {stream_text[:500]}")
        require("event: message_start" in stream_text, "Anthropic stream message_start missing")
        require("Streaming works." in stream_text, "OpenAI stream text delta was not converted")
        require("\"type\":\"tool_use\"" in stream_text, "OpenAI stream tool_call was not converted")
        require("\"name\":\"read-file.path\"" in stream_text, "Stream tool name was not mapped back")
        require(server.captured[-1]["body"]["stream"] is True, "stream true was not forwarded upstream")
    finally:
        stop_process(process)
        server.shutdown()
        server.server_close()


def test_openai_response_content_array_and_object_args() -> None:
    server, _thread, upstream_port = start_mock_openai()
    proxy_port = free_port()
    process = start_proxy(
        "openai-chat-proxy.js",
        proxy_port,
        {
            "CC_PROVIDER": "mistral",
            "CC_UPSTREAM_BASE_URL": f"http://{HOST}:{upstream_port}/v1",
            "CC_MODELS": "array-response-model",
        },
    )

    try:
        body = base_anthropic_body()
        body["model"] = "array-response-model"
        status, response_body = http_request("POST", f"http://{HOST}:{proxy_port}/v1/messages", body)
        require(status == 200, f"array response conversion returned {status}: {response_body[:500]}")
        parsed = json.loads(response_body)
        text = "\n".join(block.get("text", "") for block in parsed["content"] if block.get("type") == "text")
        require("Array content works." in text, "OpenAI content array text was not converted")
        require("unknown_part" in text, "OpenAI unknown content part was not preserved")
        tool_block = next((block for block in parsed["content"] if block.get("type") == "tool_use"), None)
        require(tool_block is not None, "Object-shaped tool args were not converted to tool_use")
        require(tool_block["input"] == {"path": "README.md"}, "Object-shaped tool args were not preserved")
    finally:
        stop_process(process)
        server.shutdown()
        server.server_close()


def test_huggingface_kimi_options() -> None:
    server, _thread, upstream_port = start_mock_openai()
    proxy_port = free_port()
    process = start_proxy(
        "openai-chat-proxy.js",
        proxy_port,
        {
            "CC_PROVIDER": "huggingface",
            "CC_UPSTREAM_BASE_URL": f"http://{HOST}:{upstream_port}/v1",
            "CC_MODELS": "moonshotai/Kimi-K2.6,moonshotai/Kimi-K2.5",
        },
    )

    try:
        base_url = f"http://{HOST}:{proxy_port}"
        for model in ("moonshotai/Kimi-K2.6", "moonshotai/Kimi-K2.5"):
            body = {
                "model": model,
                "max_tokens": 64,
                "messages": [{"role": "user", "content": "Reply OK only."}],
            }
            status, response_body = http_request("POST", f"{base_url}/v1/messages", body)
            require(status == 200, f"{model} Hug option test returned {status}: {response_body[:500]}")

        kimi_26_body = server.captured[-2]["body"]
        require(
            kimi_26_body.get("chat_template_kwargs") == {"thinking": False},
            "Hugging Face Kimi-K2.6 missing chat_template_kwargs thinking=false",
        )
        require("thinking" not in kimi_26_body, "Hugging Face Kimi-K2.6 should not use thinking object")

        kimi_25_body = server.captured[-1]["body"]
        require(
            kimi_25_body.get("thinking") == {"type": "disabled"},
            "Hugging Face Kimi-K2.5 missing thinking disabled option",
        )
        require("chat_template_kwargs" not in kimi_25_body, "Hugging Face Kimi-K2.5 rejects chat_template_kwargs")
    finally:
        stop_process(process)
        server.shutdown()
        server.server_close()


def test_groq_provider_limits() -> None:
    server, _thread, upstream_port = start_mock_openai()
    proxy_port = free_port()
    process = start_proxy(
        "openai-chat-proxy.js",
        proxy_port,
        {
            "CC_PROVIDER": "groq",
            "CC_UPSTREAM_BASE_URL": f"http://{HOST}:{upstream_port}/openai/v1",
            "CC_MODELS": "openai/gpt-oss-120b",
        },
    )

    try:
        base_url = f"http://{HOST}:{proxy_port}"
        body = {
            "model": "openai/gpt-oss-120b",
            "max_tokens": 20000,
            "messages": [{"role": "user", "content": "Reply OK only."}],
        }
        status, response_body = http_request("POST", f"{base_url}/v1/messages", body)
        require(status == 200, f"Groq token clamp request returned {status}: {response_body[:500]}")
        upstream_body = server.captured[-1]["body"]
        require("max_tokens" not in upstream_body, "Groq should not receive deprecated max_tokens")
        require(upstream_body.get("max_completion_tokens") == 4096, "Groq max_completion_tokens was not clamped to 4096")
    finally:
        stop_process(process)
        server.shutdown()
        server.server_close()

    server, _thread, upstream_port = start_mock_openai()
    proxy_port = free_port()
    process = start_proxy(
        "openai-chat-proxy.js",
        proxy_port,
        {
            "CC_PROVIDER": "groq",
            "CC_UPSTREAM_BASE_URL": f"http://{HOST}:{upstream_port}/openai/v1",
            "CC_MODELS": "openai/gpt-oss-120b",
            "CC_MAX_REQUEST_BYTES": "512",
        },
    )

    try:
        base_url = f"http://{HOST}:{proxy_port}"
        large_body = {
            "model": "openai/gpt-oss-120b",
            "max_tokens": 100,
            "messages": [{"role": "user", "content": "x" * 2000}],
        }
        status, response_body = http_request("POST", f"{base_url}/v1/messages", large_body)
        require(status == 413, f"Groq oversized request returned {status}: {response_body[:500]}")
        require("Request too large" in response_body, "Groq oversized request did not explain the local size limit")
        require(not server.captured, "Oversized Groq request should not be forwarded upstream")
    finally:
        stop_process(process)
        server.shutdown()
        server.server_close()


def test_opencode_nemotron_cleaning_and_streaming() -> None:
    server, _thread, upstream_port = start_mock_opencode()
    proxy_port = free_port()
    process = start_proxy(
        "opencode-nemotron-proxy.js",
        proxy_port,
        {
            "CC_OPENCODE_CHAT_URL": f"http://{HOST}:{upstream_port}/zen/v1/chat/completions",
            "CC_MODELS": "nemotron-3-ultra-free",
        },
    )

    unsafe_body = {
        "model": "nemotron-3-ultra-free",
        "max_tokens": 32000,
        "system": [{"type": "text", "text": "Claude Code system prompt."}],
        "messages": [
            {
                "role": "user",
                "content": [{"type": "text", "text": "Hello OpenCode."}],
            },
            {
                "role": "assistant",
                "content": [
                    {"type": "text", "text": "I need the file."},
                    {"type": "tool_use", "id": "toolu_1", "name": "read-file.path", "input": {"path": "README.md"}},
                ],
            },
            {
                "role": "user",
                "content": [
                    {"type": "tool_result", "tool_use_id": "toolu_1", "content": "tool output"},
                ],
            },
        ],
        "tools": [
            {
                "name": "read-file.path",
                "description": "Read a project file.",
                "input_schema": {
                    "type": "object",
                    "properties": {"path": {"type": "string"}},
                    "required": ["path"],
                },
            }
        ],
        "tool_choice": {"type": "tool", "name": "read-file.path"},
        "thinking": {"type": "adaptive"},
        "context_management": {},
        "output_config": {"effort": "high"},
        "metadata": {"user_id": "tester"},
        "container": {"id": "container"},
        "mcp_servers": {"fs": {}},
        "service_tier": "auto",
        "betas": ["claude-code-only"],
    }

    try:
        base_url = f"http://{HOST}:{proxy_port}"
        status, response_body = http_request("POST", f"{base_url}/v1/messages?beta=true", unsafe_body)
        require(status == 200, f"OpenCode non-stream conversion returned {status}: {response_body[:500]}")
        parsed = json.loads(response_body)
        require(parsed["id"].startswith("msg_proxy_"), "OpenCode response id was not proxied")
        require(parsed["model"] == "nemotron-3-ultra-free", "OpenCode response model should use requested alias")
        require(parsed["content"][0] == {"type": "text", "text": "OpenCode says hello."}, "OpenCode text response was not normalized")
        tool_block = next((block for block in parsed["content"] if block.get("type") == "tool_use"), None)
        require(tool_block is not None, "OpenCode tool_call was not converted to Anthropic tool_use")
        require(tool_block["name"] == "read-file.path", "OpenCode sanitized tool name was not mapped back")
        require(tool_block["input"] == {"path": "README.md"}, "OpenCode tool arguments were not parsed")
        require(parsed["stop_reason"] == "tool_use", "OpenCode tool finish reason was not mapped")
        require(parsed["usage"]["input_tokens"] == 200, "OpenCode input usage was not preserved")
        require(parsed["usage"]["output_tokens"] == 53, "OpenCode output usage was not preserved")
        require(parsed["usage"]["cache_creation_input_tokens"] == 0, "OpenCode cache creation usage missing")
        require(parsed["usage"]["cache_read_input_tokens"] == 0, "OpenCode cache read usage missing")

        captured = server.captured[-1]
        upstream_body = captured["body"]
        require(captured["path"] == "/zen/v1/chat/completions", "OpenCode proxy used the wrong upstream path")
        require(captured["headers"].get("Authorization") == "Bearer test-key", "OpenCode auth header was not forwarded")
        require(upstream_body["stream"] is False, "OpenCode upstream stream must be forced false")
        require(upstream_body["model"] == "nemotron-3-ultra-free", "OpenCode model was not forwarded")
        require(upstream_body["max_tokens"] == 32000, "OpenCode max_tokens was not forwarded")
        require(
            upstream_body["messages"] == [
                {"role": "system", "content": "Claude Code system prompt."},
                {"role": "user", "content": "Hello OpenCode."},
                {
                    "role": "assistant",
                    "content": "I need the file.",
                    "tool_calls": [
                        {
                            "id": "toolu_1",
                            "type": "function",
                            "function": {"name": "read-file_path", "arguments": "{\"path\":\"README.md\"}"},
                        }
                    ],
                },
                {"role": "tool", "tool_call_id": "toolu_1", "content": "tool output"},
            ],
            "OpenCode messages were not converted to OpenAI-compatible tool-aware content",
        )
        require(upstream_body["tools"][0]["function"]["name"] == "read-file_path", "OpenCode tool name was not sanitized")
        require(upstream_body["tools"][0]["function"]["parameters"]["required"] == ["path"], "OpenCode tool schema was not preserved")
        require(upstream_body["tool_choice"]["function"]["name"] == "read-file_path", "OpenCode tool_choice was not converted")
        for stripped in (
            "thinking",
            "context_management",
            "output_config",
            "metadata",
            "container",
            "mcp_servers",
            "service_tier",
            "betas",
        ):
            require(stripped not in upstream_body, f"OpenCode upstream body leaked stripped field: {stripped}")

        stream_body = dict(unsafe_body)
        stream_body["stream"] = True
        status, stream_text = http_request("POST", f"{base_url}/v1/messages", stream_body, timeout=15)
        require(status == 200, f"OpenCode stream conversion returned {status}: {stream_text[:500]}")
        require("event: message_start" in stream_text, "OpenCode fake SSE missing message_start")
        require("event: content_block_delta" in stream_text, "OpenCode fake SSE missing content delta")
        require("OpenCode says hello." in stream_text, "OpenCode fake SSE missing final text")
        require("\"type\":\"tool_use\"" in stream_text, "OpenCode fake SSE missing tool_use block")
        require("\"name\":\"read-file.path\"" in stream_text, "OpenCode fake SSE did not map tool name back")
        require("event: message_stop" in stream_text, "OpenCode fake SSE missing message_stop")
        require(server.captured[-1]["body"]["stream"] is False, "OpenCode streaming request should still be non-stream upstream")
    finally:
        stop_process(process)
        server.shutdown()
        server.server_close()


def test_proxy_source_contracts() -> None:
    wrappers = {
        "codestral-anthropic-proxy.js": "https://codestral.mistral.ai/v1",
        "hug-anthropic-proxy.js": "https://router.huggingface.co/v1",
        "mistral-anthropic-proxy.js": "https://api.mistral.ai/v1",
        "mistral-vibe-anthropic-proxy.js": "https://api.mistral.ai/v1",
        "nvidia-anthropic-proxy.js": "https://integrate.api.nvidia.com/v1",
        "openrouter-anthropic-normalizer.js": "https://openrouter.ai/api/v1",
    }
    for script_name, base_url in wrappers.items():
        text = (PROXY_DIR / script_name).read_text(encoding="utf-8")
        require("require('./openai-chat-proxy')" in text, f"{script_name} is not using the shared converter")
        require(base_url in text, f"{script_name} missing provider base URL")
        require(
            "process.env.CC_UPSTREAM_BASE_URL = process.env.CC_UPSTREAM_BASE_URL ||" not in text,
            f"{script_name} must not inherit the local profile base URL as upstream",
        )

    gemini = (PROXY_DIR / "anthropic-gemini-proxy.js").read_text(encoding="utf-8")
    for marker in (
        "functionDeclarations",
        "functionCall",
        "functionResponse",
        "inlineData",
        "fileData",
        "thoughtSignature",
        "/v1/messages/count_tokens",
    ):
        require(marker in gemini, f"Gemini proxy missing conversion marker: {marker}")

    shared = (PROXY_DIR / "openai-chat-proxy.js").read_text(encoding="utf-8")
    for marker in (
        "image_url",
        "tool_calls",
        "tool_choice",
        "role: 'tool'",
        "content_block_delta",
        "chat_template_kwargs",
        "CC_HUGGINGFACE_DISABLE_KIMI_THINKING",
        "max_completion_tokens",
        "CC_MAX_REQUEST_BYTES",
        "response_format",
        "parallel_tool_calls",
        "u.protocol === 'http:' ? http : https",
    ):
        require(marker in shared, f"Shared OpenAI proxy missing conversion marker: {marker}")

    opencode = (PROXY_DIR / "opencode-nemotron-proxy.js").read_text(encoding="utf-8")
    for marker in (
        "https://opencode.ai/zen/v1/chat/completions",
        "function cleanOpenCodeRequest",
        "stream: false",
        "toOpenAiTools",
        "contentBlocksFromOpenAiMessage",
        "function writeFakeAnthropicStream",
        "content_block_delta",
    ):
        require(marker in opencode, f"OpenCode Nemotron proxy missing conversion marker: {marker}")

    profiles_root = PROXY_DIR.parent
    providers = (profiles_root / "providers.ps1").read_text(encoding="utf-8")
    for marker in (
        'Id = "nvidia-nim"',
        'Name = "NVIDIA NIM"',
        'ModelsEndpoint = "https://integrate.api.nvidia.com/v1/models"',
        'ProxyScript = \'Join-Path $PSScriptRoot "..\\proxy\\nvidia-anthropic-proxy.js"\'',
        'Id = "mistral"',
        'Mode = "mistral-proxy"',
        'ModelsEndpoint = "https://api.mistral.ai/v1/models"',
        'ProxyScript = \'Join-Path $PSScriptRoot "..\\proxy\\mistral-anthropic-proxy.js"\'',
        'Id = "mistral-vibe"',
        'Mode = "mistral-vibe-proxy"',
        'KeyName = "MISTRAL_VIBE_API_KEY"',
        'ProxyScript = \'Join-Path $PSScriptRoot "..\\proxy\\mistral-vibe-anthropic-proxy.js"\'',
        'Id = "codestral"',
        'Mode = "codestral-proxy"',
        'KeyName = "CODESTRAL_API_KEY"',
        'ProxyScript = \'Join-Path $PSScriptRoot "..\\proxy\\codestral-anthropic-proxy.js"\'',
        'Id = "opencode_nemotron"',
        'Mode = "opencode-nemotron-proxy"',
        'AuthMode = "auth_token"',
        'KeyName = "OPENCODE_API_KEY"',
        'ProxyScript = \'Join-Path $PSScriptRoot "..\\proxy\\opencode-nemotron-proxy.js"\'',
    ):
        require(marker in providers, f"Provider registry missing marker: {marker}")


def main() -> int:
    tests = [
        ("proxy endpoints", test_proxy_basic_endpoints),
        ("OpenAI-compatible conversion", test_openai_compatible_conversion),
        ("OpenAI response arrays/object args", test_openai_response_content_array_and_object_args),
        ("Hugging Face Kimi options", test_huggingface_kimi_options),
        ("Groq provider limits", test_groq_provider_limits),
        ("OpenCode Nemotron cleaning/streaming", test_opencode_nemotron_cleaning_and_streaming),
        ("source contracts", test_proxy_source_contracts),
    ]

    for name, test_func in tests:
        print(f"Testing {name}...")
        test_func()
        print(f"[OK] {name}")
    print("\nAll proxy conversion checks passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
