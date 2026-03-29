#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import tempfile


def extract_text_content(content):
    if isinstance(content, str):
        return content.strip()
    if isinstance(content, list):
        chunks = []
        for item in content:
            if not isinstance(item, dict):
                continue
            item_type = item.get("type")
            if item_type == "text" and isinstance(item.get("text"), str):
                chunks.append(item["text"])
            elif isinstance(item.get("text"), str):
                chunks.append(item["text"])
        return "\n".join(chunk.strip() for chunk in chunks if chunk and chunk.strip()).strip()
    return ""


def fail(message: str, body: str = "") -> int:
    print(message, file=sys.stderr)
    if body:
        print(body, file=sys.stderr)
    return 1


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: call_api.py <payload-json-path>", file=sys.stderr)
        return 2

    payload_path = sys.argv[1]
    endpoint = os.environ.get("INPUT_API_ENDPOINT", "").strip()
    api_key = os.environ.get("INPUT_API_KEY", "").strip()
    if not endpoint:
        return fail("missing api_endpoint")
    if not api_key:
        return fail("missing api_key")

    with tempfile.NamedTemporaryFile(delete=False) as response_file:
        response_path = response_file.name

    curl_cmd = [
        "curl",
        "--silent",
        "--show-error",
        "--location",
        "--output",
        response_path,
        "--write-out",
        "%{http_code}",
        "--request",
        "POST",
        "--header",
        f"Authorization: Bearer {api_key}",
        "--header",
        "Content-Type: application/json",
        "--data-binary",
        f"@{payload_path}",
        endpoint,
    ]

    try:
        result = subprocess.run(curl_cmd, check=False, capture_output=True, text=True)
    except OSError as exc:
        return fail(f"failed to execute curl: {exc}")

    if result.returncode != 0:
        return fail(f"curl request failed with exit code {result.returncode}", result.stderr.strip())

    status_text = result.stdout.strip()
    try:
        status = int(status_text)
    except ValueError:
        return fail("curl did not return a valid HTTP status code", status_text)

    with open(response_path, "r", encoding="utf-8", errors="replace") as handle:
        response_body = handle.read()

    if status < 200 or status >= 300:
        return fail(f"Chat Completions API returned HTTP {status}", response_body)

    try:
        parsed = json.loads(response_body)
    except json.JSONDecodeError:
        return fail("Chat Completions API returned invalid JSON", response_body)

    choices = parsed.get("choices")
    if not isinstance(choices, list) or not choices:
        return fail("Chat Completions API response did not include choices[0]", response_body)

    message = choices[0].get("message") if isinstance(choices[0], dict) else None
    if not isinstance(message, dict):
        return fail("Chat Completions API response did not include choices[0].message", response_body)

    content = extract_text_content(message.get("content"))
    if not content:
        return fail("model returned empty content", response_body)

    sys.stdout.write(content)
    if not content.endswith("\n"):
        sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
