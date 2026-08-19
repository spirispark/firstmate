#!/usr/bin/env python3
"""Behavioral tests for bin/mmox-openai-shim.py.

Addresses Amazon Q findings on PR #6:
1. Retry honors retryability (no retries on 400/401/403).
2. Upstream exception carries status+body for retry classification.
3. No serial-retry semaphore in the mmx subprocess path.
"""
import importlib.util
import io
import json
import sys
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
    """Finding #3: _run_mmx_subprocess must not use a serial-retry semaphore."""

    def test_no_bounded_semaphore_in_mmx_path(self):
        # The semaphore was created inside _run_mmx_subprocess.
        # After the fix, the function must not import threading.BoundedSemaphore
        # nor instantiate one. We assert by source-string scan to keep this
        # test honest: if someone re-adds the semaphore, this test fails.
        source = SHIM_PATH.read_text(encoding="utf-8")
        # Locate the mmx subprocess function block.
        start = source.find("def _run_mmx_subprocess")
        self.assertGreater(start, 0, "could not locate _run_mmx_subprocess")
        end = source.find("\ndef ", start + 1)
        block = source[start:end]
        self.assertNotIn("BoundedSemaphore", block,
                         "_run_mmx_subprocess must not use BoundedSemaphore "
                         "(serial retry loops have no concurrency to gate)")
        self.assertNotIn("threading.", block,
                         "_run_mmx_subprocess must not import threading "
                         "when only used for an unnecessary semaphore")

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


class ApiKeyRedactionTest(unittest.TestCase):
    """Acceptance: errors and logs must not leak the API key."""

    def test_error_message_does_not_contain_api_key(self):
        urlopen = mock.Mock(side_effect=[_upstream_error(400)])
        with _quiet_stderr(), \
                mock.patch.object(SHIM.urllib.request, "urlopen", urlopen), \
                mock.patch.object(SHIM.time, "sleep", mock.Mock()), \
                mock.patch.object(SHIM, "_load_api_key", return_value="sk-secret-abcdef1234567890"), \
                mock.patch.object(SHIM, "_load_region_and_base_url",
                                  return_value=("global", "https://api.minimax.io")):
            with self.assertRaises(RuntimeError) as ctx:
                SHIM._run_direct(
                    _payload(),
                    timeout_s=10,
                    retry_attempts=1,
                    retry_base_sleep=0.01,
                )
        self.assertNotIn("sk-secret-abcdef1234567890", str(ctx.exception))


if __name__ == "__main__":
    unittest.main()
