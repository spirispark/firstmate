#!/usr/bin/env python3
"""Behavioral tests for bin/mmox-openai-shim.py.

Covered invariants:
- Retry honors retryability: no retry on 400, 401, or 403.
- An upstream exception carries status and body so retry classification can read them.
- The mmx subprocess path holds no serial-retry semaphore.
"""
import http.client
import importlib.util
import io
import json
import os
import shutil
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock


SHIM_PATH = Path(__file__).parents[1] / "bin" / "mmox-openai-shim.py"
SPEC = importlib.util.spec_from_file_location("mmox_shim", SHIM_PATH)
SHIM = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SHIM)


class _FakeHTTPResponse:
    """Stand-in for urllib's HTTPResponse, with .status, .read()."""

    def __init__(self, *, status: int, body: bytes):
        self.status = status
        self._body = body

    def read(self) -> bytes:
        return self._body


class _FakeHTTPError(SHIM.urllib.error.HTTPError):
    """Stand-in for urllib.error.HTTPError carrying status + parsed body."""

    def __init__(self, *, status: int, body: bytes):
        # urllib.error.HTTPError(url, code, msg, hdrs, fp) — fp is the file-like
        # body source. We use a BytesIO so the read() shim below returns it.
        super().__init__(
            url="https://api.minimax.io/anthropic/v1/messages",
            code=status,
            msg=f"HTTP {status}",
            hdrs={},
            fp=io.BytesIO(body),
        )
        self._body = body

    def read(self) -> bytes:
        return self._body


def _payload() -> dict:
    return {
        "model": "MiniMax-M3",
        "messages": [{"role": "user", "content": "hi"}],
    }


def _upstream_200() -> _FakeHTTPResponse:
    return _FakeHTTPResponse(
        status=200,
        body=json.dumps(
            {
                "content": [{"type": "text", "text": "hello"}],
                "usage": {"input_tokens": 1, "output_tokens": 2},
            }
        ).encode("utf-8"),
    )


def _upstream_error(status: int, *, etype: str = "invalid_request_error") -> _FakeHTTPError:
    return _FakeHTTPError(
        status=status,
        body=json.dumps({"error": {"type": etype, "message": "boom"}}).encode("utf-8"),
    )


def _quiet_stderr():
    return mock.patch.object(sys, "stderr", new_callable=io.StringIO)


def _serve_shim(test: unittest.TestCase) -> tuple:
    """Start the real shim on an ephemeral loopback port for the duration of one test."""
    server = SHIM.ThreadingHTTPServer(("127.0.0.1", 0), SHIM.ShimHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    test.addCleanup(thread.join, 5)
    test.addCleanup(server.server_close)
    test.addCleanup(server.shutdown)
    return server.server_address[0], server.server_address[1]


def _post_chat(host: str, port: int) -> tuple:
    """POST one completion request; return (status, body_text)."""
    conn = http.client.HTTPConnection(host, port, timeout=10)
    try:
        conn.request(
            "POST",
            "/v1/chat/completions",
            body=json.dumps(_payload()).encode("utf-8"),
            headers={"Content-Type": "application/json"},
        )
        response = conn.getresponse()
        return response.status, response.read().decode("utf-8")
    finally:
        conn.close()


class RetryabilityTest(unittest.TestCase):
    """Finding #1: _run_direct must consult _is_anthropic_retryable."""

    def test_400_does_not_retry(self):
        # Each call returns 400; the retry layer should give up after one attempt
        # because 400 is not retryable.
        urlopen = mock.Mock(side_effect=[_upstream_error(400)])
        sleep = mock.Mock()
        raised = None
        with _quiet_stderr(), \
                mock.patch.object(SHIM.urllib.request, "urlopen", urlopen), \
                mock.patch.object(SHIM.time, "sleep", sleep), \
                mock.patch.object(SHIM, "_load_api_key", return_value="k"), \
                mock.patch.object(SHIM, "_load_region_and_base_url",
                                  return_value=("global", "https://api.minimax.io")):
            try:
                SHIM._run_direct(
                    _payload(),
                    timeout_s=10,
                    retry_attempts=3,
                    retry_base_sleep=0.01,
                )
            except BaseException as e:
                raised = e
        self.assertIsInstance(raised, RuntimeError,
                              f"expected RuntimeError; got {type(raised).__name__}: {raised}")
        self.assertEqual(urlopen.call_count, 1,
                         f"400 must not be retried; urlopen was called {urlopen.call_count} times")
        self.assertEqual(sleep.call_count, 0,
                         "no retry sleep when error is not retryable")

    def test_401_does_not_retry(self):
        urlopen = mock.Mock(side_effect=[_upstream_error(401, etype="authentication_error")])
        sleep = mock.Mock()
        raised = None
        with _quiet_stderr(), \
                mock.patch.object(SHIM.urllib.request, "urlopen", urlopen), \
                mock.patch.object(SHIM.time, "sleep", sleep), \
                mock.patch.object(SHIM, "_load_api_key", return_value="k"), \
                mock.patch.object(SHIM, "_load_region_and_base_url",
                                  return_value=("global", "https://api.minimax.io")):
            try:
                SHIM._run_direct(
                    _payload(),
                    timeout_s=10,
                    retry_attempts=3,
                    retry_base_sleep=0.01,
                )
            except BaseException as e:
                raised = e
        self.assertIsInstance(raised, RuntimeError,
                              f"expected RuntimeError; got {type(raised).__name__}: {raised}")
        self.assertEqual(urlopen.call_count, 1,
                         f"401 must not be retried; urlopen was called {urlopen.call_count} times")

    def test_403_does_not_retry(self):
        urlopen = mock.Mock(side_effect=[_upstream_error(403, etype="permission_error")])
        sleep = mock.Mock()
        raised = None
        with _quiet_stderr(), \
                mock.patch.object(SHIM.urllib.request, "urlopen", urlopen), \
                mock.patch.object(SHIM.time, "sleep", sleep), \
                mock.patch.object(SHIM, "_load_api_key", return_value="k"), \
                mock.patch.object(SHIM, "_load_region_and_base_url",
                                  return_value=("global", "https://api.minimax.io")):
            try:
                SHIM._run_direct(
                    _payload(),
                    timeout_s=10,
                    retry_attempts=3,
                    retry_base_sleep=0.01,
                )
            except BaseException as e:
                raised = e
        self.assertIsInstance(raised, RuntimeError,
                              f"expected RuntimeError; got {type(raised).__name__}: {raised}")
        self.assertEqual(urlopen.call_count, 1,
                         f"403 must not be retried; urlopen was called {urlopen.call_count} times")

    def test_429_retries_then_raises(self):
        urlopen = mock.Mock(side_effect=[
            _upstream_error(429, etype="rate_limit_error"),
            _upstream_error(429, etype="rate_limit_error"),
            _upstream_error(429, etype="rate_limit_error"),
        ])
        sleep = mock.Mock()
        with _quiet_stderr(), \
                mock.patch.object(SHIM.urllib.request, "urlopen", urlopen), \
                mock.patch.object(SHIM.time, "sleep", sleep), \
                mock.patch.object(SHIM, "_load_api_key", return_value="k"), \
                mock.patch.object(SHIM, "_load_region_and_base_url",
                                  return_value=("global", "https://api.minimax.io")):
            with self.assertRaises(RuntimeError):
                SHIM._run_direct(
                    _payload(),
                    timeout_s=10,
                    retry_attempts=3,
                    retry_base_sleep=0.01,
                )
        self.assertEqual(urlopen.call_count, 3,
                         "429 must be retried up to retry_attempts")
        self.assertEqual(sleep.call_count, 2,
                         "two backoff sleeps between three attempts")

    def test_529_retries(self):
        urlopen = mock.Mock(side_effect=[
            _upstream_error(529, etype="overloaded_error"),
            _upstream_200(),
        ])
        sleep = mock.Mock()
        with _quiet_stderr(), \
                mock.patch.object(SHIM.urllib.request, "urlopen", urlopen), \
                mock.patch.object(SHIM.time, "sleep", sleep), \
                mock.patch.object(SHIM, "_load_api_key", return_value="k"), \
                mock.patch.object(SHIM, "_load_region_and_base_url",
                                  return_value=("global", "https://api.minimax.io")):
            body = SHIM._run_direct(
                _payload(),
                timeout_s=10,
                retry_attempts=3,
                retry_base_sleep=0.01,
            )
        self.assertEqual(urlopen.call_count, 2,
                         "529 must retry then succeed")
        self.assertEqual(body["usage"]["output_tokens"], 2)

    def test_400_then_200_does_not_retry(self):
        # 400 must surface as final error; the second call is unreachable.
        urlopen = mock.Mock(side_effect=[_upstream_error(400), _upstream_200()])
        sleep = mock.Mock()
        raised = None
        with _quiet_stderr(), \
                mock.patch.object(SHIM.urllib.request, "urlopen", urlopen), \
                mock.patch.object(SHIM.time, "sleep", sleep), \
                mock.patch.object(SHIM, "_load_api_key", return_value="k"), \
                mock.patch.object(SHIM, "_load_region_and_base_url",
                                  return_value=("global", "https://api.minimax.io")):
            try:
                SHIM._run_direct(
                    _payload(),
                    timeout_s=10,
                    retry_attempts=3,
                    retry_base_sleep=0.01,
                )
            except BaseException as e:
                raised = e
        self.assertIsInstance(raised, RuntimeError,
                              f"expected RuntimeError; got {type(raised).__name__}: {raised}")
        self.assertEqual(urlopen.call_count, 1)


class ExceptionCarriesStatusTest(unittest.TestCase):
    """Finding #2: caller must see status + parsed body for retry classification."""

    def test_exception_exposes_status_and_body(self):
        urlopen = mock.Mock(side_effect=[_upstream_error(429, etype="rate_limit_error")])
        with _quiet_stderr(), \
                mock.patch.object(SHIM.urllib.request, "urlopen", urlopen), \
                mock.patch.object(SHIM.time, "sleep", mock.Mock()), \
                mock.patch.object(SHIM, "_load_api_key", return_value="k"), \
                mock.patch.object(SHIM, "_load_region_and_base_url",
                                  return_value=("global", "https://api.minimax.io")):
            with self.assertRaises(Exception) as ctx:
                SHIM._run_direct(
                    _payload(),
                    timeout_s=10,
                    retry_attempts=1,
                    retry_base_sleep=0.01,
                )
        exc = ctx.exception
        # The exception must expose status (so retry layer can decide).
        self.assertTrue(hasattr(exc, "status"),
                        "upstream exception must carry a 'status' attribute")
        self.assertEqual(exc.status, 429)
        # The exception must expose parsed body (so retry layer can classify).
        self.assertTrue(hasattr(exc, "body"),
                        "upstream exception must carry a 'body' attribute")
        self.assertEqual(exc.body.get("error", {}).get("type"), "rate_limit_error")

    def test_transport_error_carries_no_status(self):
        # Connection-level failures (URLError, OSError) have no HTTP status.
        urlopen = mock.Mock(side_effect=SHIM.urllib.error.URLError("connection refused"))
        with _quiet_stderr(), \
                mock.patch.object(SHIM.urllib.request, "urlopen", urlopen), \
                mock.patch.object(SHIM.time, "sleep", mock.Mock()), \
                mock.patch.object(SHIM, "_load_api_key", return_value="k"), \
                mock.patch.object(SHIM, "_load_region_and_base_url",
                                  return_value=("global", "https://api.minimax.io")):
            with self.assertRaises(RuntimeError) as ctx:
                SHIM._run_direct(
                    _payload(),
                    timeout_s=10,
                    retry_attempts=1,
                    retry_base_sleep=0.01,
                )
        # Plain transport errors should be retryable (no status = transient).
        # The exception can be a plain RuntimeError without status/body.
        self.assertNotIsInstance(ctx.exception, AttributeError)


class NoSerialRetrySemaphoreTest(unittest.TestCase):
    """Finding #3: _run_mmx_subprocess must not gate calls behind a semaphore."""

    def test_concurrent_mmx_calls_are_not_serialized(self):
        # Requests arrive on ThreadingHTTPServer, so two clients reach
        # _run_mmx_subprocess at once. Any semaphore gating the retry loop lets
        # only one through, so the second thread never reaches the barrier and
        # both raise BrokenBarrierError instead of completing.
        barrier = threading.Barrier(2, timeout=5)
        failures = []

        def fake_run(cmd, input=None, capture_output=False, timeout=None,
                     check=False, env=None):
            barrier.wait()
            return mock.Mock(returncode=0,
                             stdout=b'{"content": "ok"}',
                             stderr=b"")

        def call():
            try:
                SHIM._run_mmx_subprocess(
                    _payload(),
                    timeout_s=10,
                    retry_attempts=1,
                    retry_base_sleep=0.01,
                )
            except BaseException as exc:  # noqa: BLE001 - surfaced by assert
                failures.append(exc)

        with _quiet_stderr(), mock.patch("subprocess.run", side_effect=fake_run):
            threads = [threading.Thread(target=call) for _ in range(2)]
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join(timeout=10)

        self.assertEqual(failures, [],
                         "concurrent mmx calls must overlap, not serialize")

    def test_mmx_retry_still_works_without_semaphore(self):
        # Behavioral guarantee: retry semantics are unchanged after removal.
        calls = {"n": 0}

        def fake_run(cmd, input=None, capture_output=False, timeout=None,
                     check=False, env=None):
            calls["n"] += 1
            if calls["n"] < 3:
                # EAGAIN => retryable per _is_mmx_retryable.
                return mock.Mock(returncode=1,
                                 stdout=b"",
                                 stderr=b"EAGAIN: try again")
            return mock.Mock(returncode=0,
                             stdout=b'{"content": "hello from mmx"}',
                             stderr=b"")

        with _quiet_stderr(), \
                mock.patch("subprocess.run", side_effect=fake_run), \
                mock.patch.object(SHIM.time, "sleep", mock.Mock()):
            body = SHIM._run_mmx_subprocess(
                _payload(),
                timeout_s=10,
                retry_attempts=3,
                retry_base_sleep=0.01,
            )
        self.assertEqual(calls["n"], 3,
                         "mmx should retry EAGAIN exactly retry_attempts times")
        self.assertEqual(body["content"], "hello from mmx")


class UpstreamRetryClassificationHelpersTest(unittest.TestCase):
    """Helper invariants the retry layer relies on."""

    def test_retryable_statuses(self):
        for status in (408, 409, 429, 500, 502, 503, 504, 529):
            self.assertTrue(SHIM._is_anthropic_retryable({}, status),
                            f"status {status} must be retryable")

    def test_nonretryable_statuses(self):
        for status in (200, 400, 401, 403):
            self.assertFalse(SHIM._is_anthropic_retryable({}, status),
                             f"status {status} must NOT be retryable")

    def test_retryable_error_types(self):
        for etype in ("rate_limit_error", "overloaded_error", "timeout_error"):
            self.assertTrue(
                SHIM._is_anthropic_retryable({"error": {"type": etype}}, 400),
                f"error type {etype} must be retryable",
            )


SECRET = "sk-secret-abcdef1234567890"
UPSTREAM_MARKER = "internal-upstream-trace-9f3c"


def _upstream_error_echoing_secret(status: int = 401) -> _FakeHTTPError:
    """Upstream auth/config errors routinely echo the offending credential."""
    return _FakeHTTPError(
        status=status,
        body=json.dumps(
            {
                "error": {
                    "type": "authentication_error",
                    "message": f"invalid x-api-key {SECRET} {UPSTREAM_MARKER}",
                }
            }
        ).encode("utf-8"),
    )


class _SecretRegistryIsolated(unittest.TestCase):
    """Base for redaction tests: the module-level secret registry is global, so
    a leaked entry from an earlier test would mask a missing registration."""

    def setUp(self):
        saved = set(SHIM._SECRET_VALUES)

        def restore():
            SHIM._SECRET_VALUES.clear()
            SHIM._SECRET_VALUES.update(saved)

        self.addCleanup(restore)
        SHIM._SECRET_VALUES.clear()


class ApiKeyRedactionTest(_SecretRegistryIsolated):
    """Acceptance: errors and logs must not leak the API key."""

    def test_direct_error_and_log_do_not_contain_api_key(self):
        # 429 is retryable, so the retry log actually runs and can be asserted on.
        urlopen = mock.Mock(side_effect=[_upstream_error_echoing_secret(429),
                                         _upstream_error_echoing_secret(429)])
        stderr = io.StringIO()
        with mock.patch.object(sys, "stderr", stderr), \
                mock.patch.object(SHIM.urllib.request, "urlopen", urlopen), \
                mock.patch.object(SHIM.time, "sleep", mock.Mock()), \
                mock.patch.object(SHIM, "_load_api_key", return_value=SECRET), \
                mock.patch.object(SHIM, "_load_region_and_base_url",
                                  return_value=("global", "https://api.minimax.io")):
            with self.assertRaises(RuntimeError) as ctx:
                SHIM._run_direct(
                    _payload(),
                    timeout_s=10,
                    retry_attempts=2,
                    retry_base_sleep=0.01,
                )
        logged = stderr.getvalue()
        self.assertIn("sleeping", logged, "the retry log must have been emitted")
        self.assertIn(SHIM._REDACTED, logged)
        self.assertNotIn(SECRET, str(ctx.exception))
        self.assertNotIn(SECRET, logged)

    def test_mmx_subprocess_output_is_redacted(self):
        def fake_run(cmd, input=None, capture_output=False, timeout=None,
                     check=False, env=None):
            return mock.Mock(
                returncode=1,
                stdout=b"",
                stderr=f"config error: api_key={SECRET}".encode("utf-8"),
            )

        with _quiet_stderr(), \
                mock.patch.dict(os.environ, {"MMOX_API_KEY": SECRET}), \
                mock.patch("subprocess.run", side_effect=fake_run), \
                mock.patch.object(SHIM.time, "sleep", mock.Mock()):
            with self.assertRaises(RuntimeError) as ctx:
                SHIM._run_mmx_subprocess(
                    _payload(),
                    timeout_s=10,
                    retry_attempts=1,
                    retry_base_sleep=0.01,
                )
        self.assertNotIn(SECRET, str(ctx.exception))


class MmxConfigFileRedactionTest(_SecretRegistryIsolated):
    """Acceptance: a key only ~/.mmx/config.json holds must not reach the log.

    The mmx backend never calls _load_api_key — mmx reads the config in its own
    process — so the shim has to register config credentials on its own.
    """

    CONFIG_SECRET = "sk-config-only-0123456789abcdef"

    def _config_home(self) -> str:
        home = tempfile.mkdtemp(prefix="mmox-config-")
        self.addCleanup(shutil.rmtree, home, True)
        config_dir = os.path.join(home, ".mmx")
        os.makedirs(config_dir)
        with open(os.path.join(config_dir, "config.json"), "w", encoding="utf-8") as f:
            json.dump({"api_key": self.CONFIG_SECRET, "region": "global"}, f)
        return home

    def test_mmx_error_redacts_key_read_from_config_file(self):
        home = self._config_home()

        def fake_run(cmd, input=None, capture_output=False, timeout=None,
                     check=False, env=None):
            # EAGAIN is retryable, so the mmx retry log runs and can be asserted on.
            return mock.Mock(
                returncode=1,
                stdout=b"",
                stderr=f"EAGAIN config error: api_key={self.CONFIG_SECRET}".encode("utf-8"),
            )

        stderr = io.StringIO()
        with mock.patch.object(sys, "stderr", stderr), \
                mock.patch.dict(os.environ, {"HOME": home}, clear=True), \
                mock.patch("subprocess.run", side_effect=fake_run), \
                mock.patch.object(SHIM.time, "sleep", mock.Mock()):
            self.assertIsNone(os.environ.get("MMOX_API_KEY"),
                              "the config file must be the only secret source")
            with self.assertRaises(RuntimeError) as ctx:
                SHIM._run_mmx_subprocess(
                    _payload(),
                    timeout_s=10,
                    retry_attempts=2,
                    retry_base_sleep=0.01,
                )
        logged = stderr.getvalue()
        self.assertIn("sleeping", logged, "the retry log must have been emitted")
        self.assertIn(SHIM._REDACTED, logged)
        self.assertNotIn(self.CONFIG_SECRET, str(ctx.exception))
        self.assertNotIn(self.CONFIG_SECRET, logged)


class CorruptConfigResponseTest(_SecretRegistryIsolated):
    """A corrupt ~/.mmx/config.json must still produce an HTTP error response.

    Config parsing sits under every request on both backends, so a failure that
    is neither OSError nor JSONDecodeError would escape the handler's
    `except RuntimeError` and drop the connection instead of answering.
    """

    def _home_with_config(self, raw: bytes) -> str:
        home = tempfile.mkdtemp(prefix="mmox-corrupt-")
        self.addCleanup(shutil.rmtree, home, True)
        config_dir = os.path.join(home, ".mmx")
        os.makedirs(config_dir)
        with open(os.path.join(config_dir, "config.json"), "wb") as f:
            f.write(raw)
        return home

    def _post_with_config(self, raw: bytes) -> tuple:
        home = self._home_with_config(raw)
        host, port = _serve_shim(self)
        with _quiet_stderr(), \
                mock.patch.dict(os.environ,
                                {"HOME": home, "MMOX_BACKEND": "direct",
                                 "MMOX_SHIM_RETRY": "1"},
                                clear=True), \
                mock.patch.object(SHIM.time, "sleep", mock.Mock()):
            return _post_chat(host, port)

    def test_non_object_config_yields_error_response(self):
        status, raw = self._post_with_config(b"[]")
        self.assertEqual(status, 502)
        self.assertEqual(json.loads(raw)["error"]["type"], "server_error")

    def test_invalid_utf8_config_yields_error_response(self):
        status, raw = self._post_with_config(b'{"api_key": "\xff\xfe"}')
        self.assertEqual(status, 502)
        self.assertEqual(json.loads(raw)["error"]["type"], "server_error")


class ErrorResponseSafetyTest(_SecretRegistryIsolated):
    """Acceptance: the 502 body carries neither the key nor upstream output."""

    def test_bad_gateway_body_is_scrubbed(self):
        host, port = _serve_shim(self)
        urlopen = mock.Mock(side_effect=[_upstream_error_echoing_secret()])
        with _quiet_stderr(), \
                mock.patch.dict(os.environ, {"MMOX_BACKEND": "direct",
                                             "MMOX_SHIM_RETRY": "1"}), \
                mock.patch.object(SHIM.urllib.request, "urlopen", urlopen), \
                mock.patch.object(SHIM.time, "sleep", mock.Mock()), \
                mock.patch.object(SHIM, "_load_api_key", return_value=SECRET), \
                mock.patch.object(SHIM, "_load_region_and_base_url",
                                  return_value=("global", "https://api.minimax.io")):
            status, raw = _post_chat(host, port)

        self.assertEqual(status, 502)
        self.assertNotIn(SECRET, raw)
        self.assertNotIn(UPSTREAM_MARKER, raw)
        self.assertEqual(json.loads(raw)["error"]["type"], "server_error")


if __name__ == "__main__":
    unittest.main()
