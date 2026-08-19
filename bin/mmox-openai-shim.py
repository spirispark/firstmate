#!/usr/bin/env python3
"""Local OpenAI-compat HTTP shim for graphify -> MiniMax Token Plan.

graphify can target any OpenAI-compatible server with OPENAI_BASE_URL +
OPENAI_API_KEY + OPENAI_MODEL. MiniMax does not publish an OpenAI-compat
chat endpoint of its own, so this script bridges the gap.

Two backends, chosen via MMOX_BACKEND env (default "direct"):

  - "direct" — POSTs straight to MiniMax's Anthropic-compat endpoint
    (`https://api.minimax.io/anthropic/v1/messages`) using urllib. No
    subprocess, no config-file reads, no EAGAIN risk. Recommended.

  - "mmx"    — shells each request out to `mmx text chat`. Kept around
    because the captain's mmx-cli skill is the documented MiniMax entry
    point; only enable if you specifically want mmx in the loop.

Usage:
    bin/mmox-openai-shim.py [--host 127.0.0.1] [--port 8765] [--backend direct|mmx]

Then:
    export OPENAI_BASE_URL=http://127.0.0.1:8765/v1
    export OPENAI_API_KEY=mmox-local                          # any non-empty value
    export OPENAI_MODEL=MiniMax-M3

Stdlib only (no pip). Quota flows through the same MiniMax Token Plan
whether you pick `direct` or `mmx`.
"""
from __future__ import annotations

import argparse
import json
import os
import secrets
import sys
import time
import urllib.error
import urllib.request
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Dict, List, Optional

DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8765
DEFAULT_MODEL = "MiniMax-M3"
DEFAULT_TIMEOUT_S = 600
DEFAULT_BACKEND = "direct"

ANTHROPIC_BASE_URL_GLOBAL = "https://api.minimax.io"
ANTHROPIC_BASE_URL_CN = "https://api.minimaxi.com"
ANTHROPIC_VERSION = "2023-06-01"

ALLOWED_HOSTS = {"127.0.0.1", "localhost", "::1"}

API_KEY_REAL = "mmox-local"  # any non-empty value works; auth happens upstream

_MMX_SUPPORTED = {
    "model",
    "messages",
    "temperature",
    "max_tokens",
    "top_p",
    "user",
}


def _now_ts() -> int:
    return int(time.time())


def _completion_id() -> str:
    return f"mmox-{secrets.token_hex(12)}"


def _err(message: str, *, etype: str = "invalid_request_error", code: int = 400) -> dict:
    return {
        "error": {
            "message": message,
            "type": etype,
            "param": None,
            "code": etype,
        },
        "status": code,
    }


def _write_json(handler: BaseHTTPRequestHandler, payload: Dict[str, Any], status: int = 200) -> None:
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json; charset=utf-8")
    handler.send_header("Content-Length", str(len(body)))
    handler.send_header("Connection", "close")
    handler.end_headers()
    handler.wfile.write(body)


# ---------------------------------------------------------------------------
# Backend: direct MiniMax Anthropic-compat endpoint
# ---------------------------------------------------------------------------

def _load_api_key() -> str:
    """Pull the MiniMax API key from the standard places mmx would read."""
    explicit = os.environ.get("MMOX_API_KEY")
    if explicit:
        return explicit

    candidates = [
        os.path.expanduser("~/.mmx/config.json"),
        os.environ.get("MMX_CONFIG_DIR", "") + "/config.json" if os.environ.get("MMX_CONFIG_DIR") else None,
    ]
    for path in candidates:
        if not path or not os.path.exists(path):
            continue
        try:
            with open(path, encoding="utf-8") as f:
                cfg = json.load(f)
            key = cfg.get("api_key")
            if isinstance(key, str) and key:
                return key
        except (OSError, json.JSONDecodeError):
            continue

    raise RuntimeError(
        "no MiniMax API key found — set MMOX_API_KEY=... or `mmx auth login --api-key ...`"
    )


def _load_region_and_base_url() -> tuple[str, str]:
    """Read region and base_url; default region=global, base_url=api.minimax.io."""
    region = "global"
    base_url = ANTHROPIC_BASE_URL_GLOBAL
    cfg_path = os.environ.get("MMX_CONFIG_DIR", "") + "/config.json" if os.environ.get("MMX_CONFIG_DIR") else None
    candidates = [os.path.expanduser("~/.mmx/config.json"), cfg_path]
    for path in candidates:
        if not path or not os.path.exists(path):
            continue
        try:
            with open(path, encoding="utf-8") as f:
                cfg = json.load(f)
            if isinstance(cfg.get("region"), str) and cfg["region"] in ("global", "cn"):
                region = cfg["region"]
            if isinstance(cfg.get("base_url"), str) and cfg["base_url"].startswith("http"):
                base_url = cfg["base_url"]
            break
        except (OSError, json.JSONDecodeError):
            continue
    if region == "cn":
        base_url = ANTHROPIC_BASE_URL_CN
    return region, base_url


def _openai_to_anthropic_messages(openai_messages: List[Dict[str, Any]]) -> tuple[Optional[str], List[Dict[str, Any]]]:
    """Split OpenAI messages into Anthropic-style (system_text, contents).
    system role maps to Anthropic's top-level `system`; user/assistant map to contents.
    """
    system_parts: List[str] = []
    contents: List[Dict[str, Any]] = []
    for m in openai_messages:
        role = m.get("role")
        content = m.get("content")
        if not isinstance(content, str):
            # Anthropic also accepts array-of-blocks; graphify only sends strings today.
            raise RuntimeError(f"unsupported content type for role={role}: {type(content).__name__}")
        if role == "system":
            system_parts.append(content)
        elif role in ("user", "assistant"):
            contents.append({"role": role, "content": content})
        else:
            raise RuntimeError(f"unsupported message role: {role!r}")
    system_text = "\n\n".join(system_parts) if system_parts else None
    return system_text, contents


def _anthropic_to_openai_text(anthropic_body: Dict[str, Any]) -> str:
    """Pull the assistant text out of an Anthropic response shape."""
    content = anthropic_body.get("content")
    if isinstance(content, list):
        chunks = []
        for block in content:
            if not isinstance(block, dict):
                continue
            if block.get("type") == "text" and isinstance(block.get("text"), str):
                chunks.append(block["text"])
        if chunks:
            return "".join(chunks)
    if isinstance(content, str):
        return content
    raise RuntimeError(
        f"anthropic response missing text content (got keys: {sorted(anthropic_body.keys())})"
    )


def _anthropic_usage_tokens(body: Dict[str, Any]) -> tuple[int, int]:
    """Anthropic reports input_tokens/output_tokens; return (prompt, completion)."""
    usage = body.get("usage") if isinstance(body, dict) else None
    if not isinstance(usage, dict):
        return 0, 0
    return int(usage.get("input_tokens") or 0), int(usage.get("output_tokens") or 0)


def _is_anthropic_retryable(body: Dict[str, Any], status: int) -> bool:
    """Anthropic maps overload (529), rate_limit_error (429), and connection
    errors onto retryable; everything else is final."""
    if status in (408, 409, 429, 500, 502, 503, 504, 529):
        return True
    err = body.get("error") if isinstance(body, dict) else None
    if isinstance(err, dict):
        etype = err.get("type", "")
        if etype in ("rate_limit_error", "overloaded_error", "timeout_error"):
            return True
    return False


def _call_direct_anthropic(
    payload: Dict[str, Any], *, timeout_s: int
) -> Dict[str, Any]:
    """POST one OpenAI-shape chat request to MiniMax via Anthropic-compat API.

    Raises RuntimeError on transport/auth errors; returns parsed JSON body on
    success. Caller is responsible for retry policy.
    """
    api_key = _load_api_key()
    region, base_url = _load_region_and_base_url()

    system_text, contents = _openai_to_anthropic_messages(payload["messages"])
    anthropic_body: Dict[str, Any] = {
        "model": payload.get("model") or DEFAULT_MODEL,
        "max_tokens": int(payload.get("max_tokens") or payload.get("max_completion_tokens") or 1024),
        "messages": contents,
    }
    if system_text is not None:
        anthropic_body["system"] = system_text
    if payload.get("temperature") is not None:
        anthropic_body["temperature"] = float(payload["temperature"])
    if payload.get("top_p") is not None:
        anthropic_body["top_p"] = float(payload["top_p"])

    url = base_url.rstrip("/") + "/anthropic/v1/messages"
    request = urllib.request.Request(
        url,
        data=json.dumps(anthropic_body).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "x-api-key": api_key,
            "anthropic-version": ANTHROPIC_VERSION,
        },
    )

    try:
        resp = urllib.request.urlopen(request, timeout=timeout_s)
        status = resp.status
        raw = resp.read()
    except urllib.error.HTTPError as exc:
        status = exc.code
        raw = exc.read() if hasattr(exc, "read") else b""
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise RuntimeError(f"transport error: {exc}") from exc

    try:
        body = json.loads(raw.decode("utf-8")) if raw else {}
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise RuntimeError(
            f"non-JSON response (status={status}, len={len(raw)}): {raw[:200]!r}"
        ) from exc

    if status >= 400:
        raise RuntimeError(
            f"anthropic returned {status}: {json.dumps(body, ensure_ascii=False)[:400]}"
        )

    return body


def _run_direct(
    payload: Dict[str, Any], *, timeout_s: int, retry_attempts: int, retry_base_sleep: float
) -> Dict[str, Any]:
    """Run _call_direct_anthropic with the same retry envelope as the mmx path."""
    last_err: Optional[str] = None
    for attempt in range(1, retry_attempts + 1):
        try:
            body = _call_direct_anthropic(payload, timeout_s=timeout_s)
            return body
        except RuntimeError as exc:
            last_err = str(exc)
            if attempt >= retry_attempts:
                break
            sleep_for = retry_base_sleep * (2 ** (attempt - 1))
            sys.stderr.write(
                f"[mmox-shim] direct attempt {attempt}/{retry_attempts} failed: "
                f"{last_err[:200]}; sleeping {sleep_for:.1f}s before retry\n"
            )
            time.sleep(sleep_for)
    raise RuntimeError(last_err or "unknown direct error")


# ---------------------------------------------------------------------------
# Backend: mmx subprocess (legacy; kept for parity)
# ---------------------------------------------------------------------------

def _is_mmx_retryable(stderr: str, returncode: int) -> bool:
    if returncode == 0:
        return False
    haystack = (stderr or "").lower()
    return ("eagain" in haystack) or ("rate limit" in haystack) or ("429" in haystack)


def _run_mmx_subprocess(
    payload: Dict[str, Any], *, timeout_s: int, retry_attempts: int, retry_base_sleep: float
) -> Dict[str, Any]:
    import subprocess
    import threading
    cmd = [
        "mmx",
        "text",
        "chat",
        "--messages-file",
        "-",
        "--model",
        payload.get("model") or DEFAULT_MODEL,
        "--output",
        "json",
        "--quiet",
        "--stream",
        "false",
    ]
    if payload.get("temperature") is not None:
        cmd.extend(["--temperature", str(payload["temperature"])])
    if payload.get("max_tokens") is not None:
        cmd.extend(["--max-tokens", str(payload["max_tokens"])])
    if payload.get("top_p") is not None:
        cmd.extend(["--top-p", str(payload["top_p"])])

    messages = payload["messages"]
    body_in = json.dumps(messages, ensure_ascii=False).encode("utf-8")

    semaphore = threading.BoundedSemaphore(1)

    last_err = ""
    for attempt in range(1, retry_attempts + 1):
        with semaphore:
            try:
                proc = subprocess.run(
                    cmd,
                    input=body_in,
                    capture_output=True,
                    timeout=timeout_s,
                    check=False,
                    env={**os.environ, "MMX_AGENT_ROLE": "user"},
                )
            except subprocess.TimeoutExpired as exc:
                raise RuntimeError(f"mmx timed out after {timeout_s}s") from exc
            except FileNotFoundError as exc:
                raise RuntimeError(
                    "mmx CLI not found in PATH; install via `npm install -g mmx-cli`"
                ) from exc

            stdout = (proc.stdout or b"").decode("utf-8", errors="replace").strip()
            stderr = (proc.stderr or b"").decode("utf-8", errors="replace").strip()

            if proc.returncode == 0 and stdout:
                try:
                    return json.loads(stdout)
                except json.JSONDecodeError:
                    pass

            last_err = (
                f"mmx exited {proc.returncode}: stderr={stderr!r} stdout={stdout!r}"
            )
            if not _is_mmx_retryable(stderr, proc.returncode) or attempt >= retry_attempts:
                break

            sleep_for = retry_base_sleep * (2 ** (attempt - 1))
            sys.stderr.write(
                f"[mmox-shim] mmx transient (attempt {attempt}/{retry_attempts}): "
                f"{last_err[:200]}; sleeping {sleep_for:.1f}s before retry\n"
            )
            time.sleep(sleep_for)

    raise RuntimeError(last_err)


def _normalize_mmx_response(raw: Dict[str, Any]) -> str:
    content = raw.get("content")
    if isinstance(content, str):
        return content
    choices = raw.get("choices")
    if isinstance(choices, list) and choices:
        message = choices[0].get("message", {})
        if isinstance(message, dict):
            c = message.get("content")
            if isinstance(c, str):
                return c
    text = raw.get("text")
    if isinstance(text, str):
        return text
    raise RuntimeError(
        f"mmx response missing 'content' (got keys: {sorted(raw.keys())})"
    )


# ---------------------------------------------------------------------------
# HTTP handler
# ---------------------------------------------------------------------------

class ShimHandler(BaseHTTPRequestHandler):
    server_version = "mmox-openai-shim/2.0"

    def log_message(self, format: str, *args: Any) -> None:  # noqa: A002 - stdlib name
        sys.stderr.write(f"[mmox-shim] {self.address_string()} - {format % args}\n")

    def address_string(self) -> str:  # type: ignore[override]
        return f"{self.client_address[0]}:{self.client_address[1]}"

    def _check_loopback(self) -> bool:
        host = self.client_address[0]
        return host in ALLOWED_HOSTS

    def _resolve_backend(self) -> str:
        choice = os.environ.get("MMOX_BACKEND", DEFAULT_BACKEND).strip().lower()
        if choice not in ("direct", "mmx"):
            sys.stderr.write(f"[mmox-shim] MMOX_BACKEND={choice!r} unknown; using direct\n")
            return "direct"
        return choice

    def do_GET(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0]
        if not self._check_loopback():
            _write_json(self, _err("loopback-only"), code=403)
            return
        if path == "/healthz":
            _write_json(self, {"status": "ok", "ts": _now_ts()})
            return
        if path == "/v1/models":
            _write_json(
                self,
                {
                    "object": "list",
                    "data": [
                        {
                            "id": DEFAULT_MODEL,
                            "object": "model",
                            "created": _now_ts(),
                            "owned_by": "MiniMax",
                        }
                    ],
                },
            )
            return
        _write_json(self, _err(f"no route for GET {path}"), code=404)

    def do_POST(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0]
        if not self._check_loopback():
            _write_json(self, _err("loopback-only"), code=403)
            return
        if path != "/v1/chat/completions":
            _write_json(self, _err(f"no route for POST {path}"), code=404)
            return

        content_length = int(self.headers.get("content-length", "0") or "0")
        if content_length <= 0:
            _write_json(self, _err("missing request body"))
            return
        if content_length > 32 * 1024 * 1024:
            _write_json(self, _err("request body too large (>32MB)"))
            return

        try:
            raw_body = self.rfile.read(content_length)
            body = json.loads(raw_body.decode("utf-8"))
        except (json.JSONDecodeError, UnicodeDecodeError) as exc:
            _write_json(self, _err(f"bad request body: {exc}"))
            return
        if not isinstance(body, dict):
            _write_json(self, _err("request body must be a JSON object"))
            return

        messages = body.get("messages")
        if not isinstance(messages, list) or not messages:
            _write_json(self, _err("messages must be a non-empty list"))
            return

        # Tolerate unknown body fields; OpenAI clients send extras like
        # stream, user, max_completion_tokens alongside max_tokens.
        unknown = sorted(set(body.keys()) - _MMX_SUPPORTED)
        if unknown:
            sys.stderr.write(f"[mmox-shim] ignoring body fields: {unknown}\n")

        model = body.get("model") or DEFAULT_MODEL
        timeout_s = int(os.environ.get("MMOX_SHIM_TIMEOUT", str(DEFAULT_TIMEOUT_S)))
        retry_attempts = max(1, int(os.environ.get("MMOX_SHIM_RETRY", "3")))
        retry_base_sleep = float(os.environ.get("MMOX_SHIM_RETRY_SLEEP", "1.5"))

        backend = self._resolve_backend()
        started = time.monotonic()
        try:
            if backend == "direct":
                upstream = _run_direct(
                    body,
                    timeout_s=timeout_s,
                    retry_attempts=retry_attempts,
                    retry_base_sleep=retry_base_sleep,
                )
                content = _anthropic_to_openai_text(upstream)
                prompt_tokens, completion_tokens = _anthropic_usage_tokens(upstream)
            else:
                upstream = _run_mmx_subprocess(
                    body,
                    timeout_s=timeout_s,
                    retry_attempts=retry_attempts,
                    retry_base_sleep=retry_base_sleep,
                )
                content = _normalize_mmx_response(upstream)
                prompt_tokens, completion_tokens = 0, 0
        except RuntimeError as exc:
            elapsed = time.monotonic() - started
            sys.stderr.write(
                f"[mmox-shim] backend={backend} failed after {elapsed:.1f}s: {exc}\n"
            )
            _write_json(
                self,
                _err(f"upstream failed: {exc}", etype="server_error", code=502),
                status=HTTPStatus.BAD_GATEWAY,
            )
            return

        elapsed = time.monotonic() - started

        response = {
            "id": _completion_id(),
            "object": "chat.completion",
            "created": _now_ts(),
            "model": model,
            "choices": [
                {
                    "index": 0,
                    "message": {"role": "assistant", "content": content},
                    "finish_reason": "stop",
                    "logprobs": None,
                }
            ],
            "usage": {
                "prompt_tokens": prompt_tokens,
                "completion_tokens": completion_tokens,
                "total_tokens": prompt_tokens + completion_tokens,
            },
            "mmox": {"elapsed_s": round(elapsed, 3), "backend": backend},
        }
        sys.stderr.write(
            f"[mmox-shim] backend={backend} model={model} elapsed={elapsed:.2f}s "
            f"in={prompt_tokens} out={completion_tokens}\n"
        )
        _write_json(self, response)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    ap.add_argument("--host", default=os.environ.get("MMOX_SHIM_HOST", DEFAULT_HOST))
    ap.add_argument("--port", type=int, default=int(os.environ.get("MMOX_SHIM_PORT", DEFAULT_PORT)))
    ap.add_argument(
        "--backend",
        choices=("direct", "mmx"),
        default=os.environ.get("MMOX_BACKEND", DEFAULT_BACKEND),
    )
    args = ap.parse_args()

    if args.host not in ALLOWED_HOSTS:
        sys.stderr.write(
            f"[mmox-shim] refusing to bind {args.host}: loopback-only. "
            f"Allowed: {sorted(ALLOWED_HOSTS)}.\n"
        )
        return 2

    os.environ.setdefault("MMOX_BACKEND", args.backend)

    server = ThreadingHTTPServer((args.host, args.port), ShimHandler)
    sys.stderr.write(
        f"[mmox-shim] listening on http://{args.host}:{args.port}/v1 "
        f"(backend={args.backend}, default model: {DEFAULT_MODEL})\n"
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        sys.stderr.write("[mmox-shim] shutting down\n")
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
