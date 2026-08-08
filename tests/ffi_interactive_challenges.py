"""Opt-in live interactive challenge acceptance through the native Python ABI.

All selection is generic: attached/visible child-frame metadata, positive owner
geometry, and a closed-shadow-piercing checkbox selector. Production runtime
code contains no host, site-key, or challenge-specific branch. Tokens are never
printed; reports contain lengths and trusted completion metadata only.
"""

from __future__ import annotations

import argparse
from pathlib import Path
import json
import re
import time
from dataclasses import asdict
from urllib.parse import urlparse

from darkpanda import ClientProfile, DarkPandaError, FrameInfo, JavaScriptError, Runtime


PEET_MANAGED = "https://peet.ws/turnstile-test/managed.html"
NOPECHA_TURNSTILE = "https://nopecha.com/captcha/turnstile"
NOPECHA_SITE_CHALLENGE = "https://nopecha.com/demo/cloudflare"
CHECKBOX_SELECTOR = 'input[type="checkbox"]'
NOPECHA_VERIFY_ORIGIN = "https://api.nopecha.com"
NOPECHA_VERIFY_PATH = "/captcha/verify/turnstile"


MONITOR_SCRIPT = r"""
(() => {
  if (window.__darkpandaChallengeMonitor) return true;
  const state = window.__darkpandaChallengeMonitor = {
    sequence: [],
    complete: false,
    trustedComplete: false,
    completeOrigin: '',
    messageTokenLength: 0
  };
  addEventListener('message', event => {
    const data = event.data;
    if (!data || typeof data !== 'object' || data.source !== 'cloudflare-challenge') return;
    state.sequence.push(String(data.event || 'unknown'));
    if (data.event === 'complete') {
      state.complete = true;
      state.trustedComplete = event.isTrusted;
      state.completeOrigin = event.origin;
      state.messageTokenLength = String(data.token || '').length;
    }
  }, true);
  return true;
})()
"""


NOPECHA_BACKEND_MONITOR_SCRIPT = r"""
(() => {
  const stateKey = '__darkpandaNopechaVerifyMonitor';
  if (globalThis[stateKey]) return true;
  const originalFetch = globalThis.fetch;
  if (typeof originalFetch !== 'function') {
    throw new Error('NopeCHA backend monitor requires global fetch');
  }
  const targetPath = '/captcha/verify/turnstile';
  const state = {
    pending: 0,
    calls: [],
    lastSettledAt: 0
  };
  Object.defineProperty(globalThis, stateKey, {
    value: state,
    configurable: true
  });

  globalThis.fetch = async function(...args) {
    const input = args[0];
    const init = args[1];
    const rawUrl = typeof input === 'string' || input instanceof URL
      ? String(input)
      : String(input && input.url || '');
    let url;
    try {
      url = new URL(rawUrl, location.href);
    } catch (_) {
      return Reflect.apply(originalFetch, this, args);
    }
    if (url.pathname !== targetPath) {
      return Reflect.apply(originalFetch, this, args);
    }

    const inputMethod = input && typeof input === 'object' ? input.method : '';
    const method = String(init && init.method || inputMethod || 'GET').toUpperCase();
    const base = {
      method,
      origin: url.origin,
      path: url.pathname
    };
    state.pending += 1;
    try {
      const response = await Reflect.apply(originalFetch, this, args);
      const record = {
        ...base,
        status: Number(response.status) || 0,
        ok: response.ok === true,
        jsonParsed: false,
        errorPresent: false
      };
      try {
        const payload = await response.clone().json();
        record.jsonParsed = true;
        if (payload && typeof payload === 'object' && !Array.isArray(payload)) {
          record.errorPresent = Object.prototype.hasOwnProperty.call(payload, 'error');
          for (const key of ['success', 'verified']) {
            if (!Object.prototype.hasOwnProperty.call(payload, key)) continue;
            if (typeof payload[key] === 'boolean') record[key] = payload[key];
            else record.errorPresent = true;
          }
        } else {
          // A parsed primitive/array is not the verification response contract.
          record.errorPresent = true;
        }
      } catch (_) {
        // jsonParsed remains false and the original response remains readable:
        // only a clone was consumed by this monitor.
      }
      state.calls.push(record);
      return response;
    } catch (error) {
      state.calls.push({
        ...base,
        status: 0,
        ok: false,
        jsonParsed: false,
        errorPresent: true
      });
      throw error;
    } finally {
      state.pending -= 1;
      state.lastSettledAt = Date.now();
    }
  };
  return true;
})()
"""


NOPECHA_BACKEND_EVIDENCE_SCRIPT = r"""
new Promise((resolve, reject) => {
  const deadline = Date.now() + 30000;
  const quietWindowMs = 1000;
  const poll = () => {
    const state = globalThis.__darkpandaNopechaVerifyMonitor;
    if (state && state.calls.length > 0 && state.pending === 0 &&
        Date.now() - state.lastSettledAt >= quietWindowMs) {
      return resolve({
        pending: state.pending,
        verifyCalls: state.calls.map(call => ({...call}))
      });
    }
    if (Date.now() >= deadline) {
      return reject(new Error(JSON.stringify({
        reason: 'NopeCHA backend verification timeout',
        pending: state ? state.pending : null,
        verifyCalls: state ? state.calls.map(call => ({...call})) : []
      })));
    }
    setTimeout(poll, 25);
  };
  poll();
})
"""


TURNSTILE_EVIDENCE_SCRIPT = r"""
new Promise((resolve, reject) => {
  const deadline = Date.now() + 30000;
  const poll = () => {
    const monitor = window.__darkpandaChallengeMonitor || {};
    const lengths = Array.from(document.querySelectorAll(
      'input[name="cf-turnstile-response"],textarea[name="cf-turnstile-response"]'
    ), node => String(node.value || '').length);
    const nonEmpty = lengths.filter(length => length > 0);
    if (monitor.complete && nonEmpty.length > 0) {
      return resolve({
        sequence: monitor.sequence || [],
        complete: true,
        trustedComplete: monitor.trustedComplete === true,
        completeOrigin: monitor.completeOrigin || '',
        messageTokenLength: Number(monitor.messageTokenLength || 0),
        responseCount: lengths.length,
        nonEmptyResponseCount: nonEmpty.length,
        responseLengths: nonEmpty
      });
    }
    if (Date.now() >= deadline) {
      return reject(new Error(JSON.stringify({
        reason: 'challenge completion timeout',
        sequence: monitor.sequence || [],
        complete: monitor.complete === true,
        responseLengths: lengths
      })));
    }
    setTimeout(poll, 25);
  };
  poll();
})
"""


def pause_browser(page: object, milliseconds: int = 50) -> None:
    """Pump a short browser timer without sleeping inside native/V8 code."""
    try:
        page.evaluate(
            f"new Promise(resolve => setTimeout(() => resolve(true), {milliseconds}))",
            promise_timeout_ms=milliseconds + 2_000,
        )
    except (DarkPandaError, JavaScriptError):
        # A root navigation may detach the evaluating realm. The next call
        # resolves against the replacement Page/Frame.
        pass


def current_location(page: object) -> dict[str, str]:
    for _ in range(20):
        try:
            return json.loads(page.evaluate("({href:location.href,pathname:location.pathname})"))
        except (DarkPandaError, JavaScriptError):
            pause_browser(page)
    raise AssertionError("could not read location from a stable root frame")


def validate_nopecha_backend_evidence(evidence: object) -> dict[str, object]:
    """Validate and return token-free NopeCHA verification evidence."""

    if not isinstance(evidence, dict):
        raise AssertionError("NopeCHA backend evidence must be an object")
    unexpected_evidence_keys = set(evidence) - {"pending", "verifyCalls"}
    if unexpected_evidence_keys:
        raise AssertionError(
            "NopeCHA backend evidence has forbidden fields: "
            f"{sorted(unexpected_evidence_keys)!r}"
        )
    if evidence.get("pending") != 0:
        raise AssertionError("NopeCHA backend verification did not settle")
    calls = evidence.get("verifyCalls")
    if not isinstance(calls, list) or not calls:
        raise AssertionError("No NopeCHA backend verification call was observed")

    required = {
        "method",
        "origin",
        "path",
        "status",
        "ok",
        "jsonParsed",
        "errorPresent",
    }
    allowed = required | {"success", "verified"}
    sanitized_calls: list[dict[str, object]] = []
    for index, call in enumerate(calls):
        if not isinstance(call, dict):
            raise AssertionError(f"NopeCHA verify call {index} must be an object")
        missing = required - set(call)
        forbidden = set(call) - allowed
        if missing or forbidden:
            raise AssertionError(
                f"NopeCHA verify call {index} field mismatch: "
                f"missing={sorted(missing)!r} forbidden={sorted(forbidden)!r}"
            )
        if call["method"] != "POST":
            raise AssertionError(f"NopeCHA verify call {index} did not use POST")
        if call["origin"] != NOPECHA_VERIFY_ORIGIN:
            raise AssertionError(f"NopeCHA verify call {index} used the wrong origin")
        if call["path"] != NOPECHA_VERIFY_PATH:
            raise AssertionError(f"NopeCHA verify call {index} used the wrong path")
        status = call["status"]
        if not isinstance(status, int) or isinstance(status, bool):
            raise AssertionError(f"NopeCHA verify call {index} has an invalid status")
        if not 200 <= status < 300:
            raise AssertionError(
                f"NopeCHA verify call {index} returned non-2xx status {status}"
            )
        if call["ok"] is not True:
            raise AssertionError(f"NopeCHA verify call {index} was not Response.ok")
        if call["jsonParsed"] is not True:
            raise AssertionError(f"NopeCHA verify call {index} did not return JSON")
        if call["errorPresent"] is not False:
            raise AssertionError(
                f"NopeCHA verify call {index} returned an error response"
            )
        for optional_boolean in ("success", "verified"):
            if optional_boolean in call and call[optional_boolean] is not True:
                raise AssertionError(
                    f"NopeCHA verify call {index} has false {optional_boolean}"
                )
        sanitized_calls.append(dict(call))

    # NopeCHA currently renders two widgets. A click should normally produce
    # one callback, but exact cardinality is not part of the public contract.
    # Require at least one and reject the run if any actually observed callback
    # has a non-accepted response.
    return {
        "accepted": True,
        "verifyCallCount": len(sanitized_calls),
        "verifyCalls": sanitized_calls,
    }


def _unit_test_nopecha_backend_evidence() -> None:
    base: dict[str, object] = {
        "method": "POST",
        "origin": NOPECHA_VERIFY_ORIGIN,
        "path": NOPECHA_VERIFY_PATH,
        "status": 200,
        "ok": True,
        "jsonParsed": True,
        "errorPresent": False,
    }
    accepted = validate_nopecha_backend_evidence(
        {"pending": 0, "verifyCalls": [base, {**base, "verified": True}]}
    )
    assert accepted["accepted"] is True
    assert accepted["verifyCallCount"] == 2

    def expect_rejected(value: object) -> None:
        try:
            validate_nopecha_backend_evidence(value)
        except AssertionError:
            return
        raise AssertionError(f"invalid backend evidence was accepted: {value!r}")

    expect_rejected({"pending": 0, "verifyCalls": []})
    expect_rejected({"pending": 1, "verifyCalls": [base]})
    expect_rejected({"pending": 0, "verifyCalls": [{**base, "method": "GET"}]})
    expect_rejected(
        {"pending": 0, "verifyCalls": [{**base, "origin": "https://nopecha.com"}]}
    )
    expect_rejected(
        {"pending": 0, "verifyCalls": [{**base, "path": "/wrong-path"}]}
    )
    expect_rejected({"pending": 0, "verifyCalls": [{**base, "status": 500}]})
    expect_rejected(
        {"pending": 0, "verifyCalls": [base, {**base, "status": 500}]}
    )
    expect_rejected({"pending": 0, "verifyCalls": [{**base, "ok": False}]})
    expect_rejected({"pending": 0, "verifyCalls": [{**base, "jsonParsed": False}]})
    expect_rejected({"pending": 0, "verifyCalls": [{**base, "errorPresent": True}]})
    expect_rejected({"pending": 0, "verifyCalls": [{**base, "success": False}]})
    expect_rejected({"pending": 0, "verifyCalls": [{**base, "verified": False}]})
    expect_rejected({"pending": 0, "verifyCalls": [{**base, "token": "forbidden"}]})


def frame_score(frame: FrameInfo) -> tuple[float, int, float, int]:
    rect = frame.owner_rect
    assert rect is not None
    # Interactive checkbox owners are normally close to 300x65. This is only
    # generic geometry ranking: candidates were already filtered by attached,
    # visible and positive rect, and no URL/site-key participates.
    return (
        abs(rect.width - 300) + abs(rect.height - 65),
        0 if frame.child_count == 0 else 1,
        rect.width * rect.height,
        frame.frame_id,
    )


def wait_for_visible_child(page: object, timeout_s: float = 30.0) -> FrameInfo:
    deadline = time.monotonic() + timeout_s
    last_frames: list[FrameInfo] = []
    while time.monotonic() < deadline:
        last_frames = page.frames(visible=True, attached=True)
        candidates = [
            frame
            for frame in last_frames
            if not frame.is_root
            and frame.owner_rect is not None
            and frame.owner_rect.width > 0
            and frame.owner_rect.height > 0
        ]
        if candidates:
            return min(candidates, key=frame_score)
        pause_browser(page)
    safe_frames = [public_frame_evidence(frame) for frame in last_frames]
    raise AssertionError(f"no attached visible positive-rect child frame: {safe_frames!r}")


def public_frame_evidence(frame: FrameInfo) -> dict[str, object]:
    value = asdict(frame)
    # Strip query/fragment and redact opaque path components so ephemeral
    # challenge parameters are never logged.
    parsed = urlparse(frame.url)
    segments = []
    for segment in parsed.path.split("/"):
        opaque = len(segment) > 32 or (
            len(segment) >= 16 and re.fullmatch(r"[0-9a-fA-F]+", segment) is not None
        )
        segments.append(f"<opaque:{len(segment)}>" if opaque else segment)
    value["url"] = f"{parsed.scheme}://{parsed.netloc}{'/'.join(segments)}"
    return value


def run_turnstile_case(runtime: Runtime, url: str, label: str) -> dict[str, object]:
    with runtime.new_page() as page:
        page.navigate(url, timeout_ms=30_000)
        assert page.evaluate(MONITOR_SCRIPT) == "true"
        require_backend_acceptance = label == "nopecha-turnstile"
        if require_backend_acceptance:
            assert page.evaluate(NOPECHA_BACKEND_MONITOR_SCRIPT) == "true"
        frame = wait_for_visible_child(page)
        page.click(
            CHECKBOX_SELECTOR,
            frame_id=frame.frame_id,
            pierce_shadow=True,
            timeout_ms=30_000,
            move_delay_ms=16,
            press_delay_ms=60,
        )
        evidence = json.loads(
            page.evaluate(TURNSTILE_EVIDENCE_SCRIPT, promise_timeout_ms=35_000)
        )
        assert evidence["complete"] is True, evidence
        assert evidence["trustedComplete"] is True, evidence
        assert evidence["completeOrigin"] == "https://challenges.cloudflare.com", evidence
        assert int(evidence["messageTokenLength"]) > 0, evidence
        assert int(evidence["nonEmptyResponseCount"]) > 0, evidence
        assert all(int(length) > 0 for length in evidence["responseLengths"]), evidence
        if require_backend_acceptance:
            backend_evidence = json.loads(
                page.evaluate(
                    NOPECHA_BACKEND_EVIDENCE_SCRIPT,
                    promise_timeout_ms=35_000,
                )
            )
            evidence["backendAcceptance"] = validate_nopecha_backend_evidence(
                backend_evidence
            )
        report = {
            "case": label,
            "url": url,
            "frame": public_frame_evidence(frame),
            **evidence,
        }
        print(json.dumps(report, ensure_ascii=False, separators=(",", ":")))
        return report


def run_site_challenge(runtime: Runtime) -> dict[str, object]:
    with runtime.new_page() as page:
        page.navigate(NOPECHA_SITE_CHALLENGE, timeout_ms=60_000)
        initial = current_location(page)
        if initial["pathname"] == "/demo":
            report = {
                "case": "nopecha-site-challenge",
                "url": NOPECHA_SITE_CHALLENGE,
                "challengePresent": False,
                "finalPath": "/demo",
            }
            print(json.dumps(report, separators=(",", ":")))
            return report
        initial_url = urlparse(initial["href"])
        if initial_url.hostname != "nopecha.com" or initial["pathname"] != "/demo/cloudflare":
            raise AssertionError({
                "reason": "root navigation did not commit the managed challenge",
                "origin": f"{initial_url.scheme}://{initial_url.netloc}",
                "pathname": initial["pathname"],
            })

        # A managed challenge may replace its widget/frame after a completed
        # interaction while retaining the root URL. Treat each newly attached,
        # visible browsing context as a fresh generic input target, but never
        # click the same frame id twice. The total deadline bounds retries.
        deadline = time.monotonic() + 120
        attempted_frame_ids: set[int] = set()
        attempts: list[dict[str, object]] = []
        final = current_location(page)
        while final["pathname"] != "/demo" and time.monotonic() < deadline:
            frames = page.frames(visible=True, attached=True)
            candidates = sorted(
                (
                    frame
                    for frame in frames
                    if not frame.is_root
                    and frame.frame_id not in attempted_frame_ids
                    and frame.owner_rect is not None
                    # A physical checkbox cannot be actionable through an
                    # embedding viewport smaller than a generic pointer target.
                    # This excludes hidden 5x5 retry/measurement descendants
                    # without using URL/site-key knowledge.
                    and frame.owner_rect.width >= 20
                    and frame.owner_rect.height >= 20
                    and frame.owner_rect.width * frame.owner_rect.height >= 400
                ),
                key=frame_score,
            )
            if not candidates:
                pause_browser(page, 100)
                final = current_location(page)
                continue

            frame = candidates[0]
            attempted_frame_ids.add(frame.frame_id)
            attempt: dict[str, object] = {
                "round": len(attempts) + 1,
                "frame": public_frame_evidence(frame),
            }
            try:
                remaining_ms = max(1, int((deadline - time.monotonic()) * 1000))
                page.click(
                    CHECKBOX_SELECTOR,
                    frame_id=frame.frame_id,
                    pierce_shadow=True,
                    timeout_ms=min(30_000, remaining_ms),
                    move_delay_ms=16,
                    press_delay_ms=60,
                )
                attempt["clickReturned"] = True
            except DarkPandaError as error:
                # Frame replacement between enumeration and a phase boundary
                # is expected during a managed retry. Preserve only status and
                # exception class; challenge URLs/payloads stay out of logs.
                attempt["clickReturned"] = False
                attempt["errorType"] = type(error).__name__
                attempt["status"] = int(error.status)
            attempts.append(attempt)
            print(json.dumps({
                "case": "nopecha-site-challenge",
                "phase": "click-attempt",
                **attempt,
            }, ensure_ascii=False, separators=(",", ":")))
            pause_browser(page, 100)
            final = current_location(page)
        safe_final = {
            "origin": f"{urlparse(final['href']).scheme}://{urlparse(final['href']).netloc}",
            "pathname": final["pathname"],
            "attemptCount": len(attempts),
            "attempts": attempts,
        }
        assert final["pathname"] == "/demo", safe_final
        assert urlparse(final["href"]).hostname == "nopecha.com", safe_final
        report = {
            "case": "nopecha-site-challenge",
            "url": NOPECHA_SITE_CHALLENGE,
            "challengePresent": True,
            "attemptCount": len(attempts),
            "attempts": attempts,
            "finalPath": final["pathname"],
        }
        print(json.dumps(report, ensure_ascii=False, separators=(",", ":")))
        return report


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--library", required=True)
    parser.add_argument("--wreq", required=True)
    parser.add_argument(
        "--fingerprint-profile-json",
        help="optional strict schema-v2 fingerprint profile JSON",
    )
    parser.add_argument(
        "--case",
        choices=("all", "peet", "nopecha-turnstile", "nopecha-site"),
        default="all",
    )
    args = parser.parse_args()

    fingerprint_profile = None
    timezone = "UTC"
    if args.fingerprint_profile_json:
        fingerprint_profile = Path(args.fingerprint_profile_json).read_text(
            encoding="utf-8"
        )
        fingerprint_mapping = json.loads(fingerprint_profile)
        timezone = fingerprint_mapping["locale"]["timezone"]

    with Runtime(
        library_path=args.library,
        wreq_library_path=args.wreq,
        navigation_timeout_ms=30_000,
        locale="en-US",
        timezone=timezone,
        profile=ClientProfile.CHROME149,
        fingerprint_profile_json=fingerprint_profile,
    ) as runtime:
        if args.case in ("all", "peet"):
            run_turnstile_case(runtime, PEET_MANAGED, "peet-managed")
        if args.case in ("all", "nopecha-turnstile"):
            run_turnstile_case(runtime, NOPECHA_TURNSTILE, "nopecha-turnstile")
        if args.case in ("all", "nopecha-site"):
            run_site_challenge(runtime)

    print("ffi interactive challenges: PASS")


if __name__ == "__main__":
    main()
