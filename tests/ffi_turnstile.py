"""Turnstile immutable v1 client-acceptance matrix through the native ABI.

The peet.ws fixtures have no form, backend, Siteverify endpoint, or published
secret.  This test therefore proves only that the unmodified Cloudflare widget
delivered a trusted ``complete`` message and that its client response plumbing
is coherent.  It deliberately does not label that token server-validated and
must not be used to localize a failure's root cause.
"""

from __future__ import annotations

import argparse
from collections import Counter
import json
import time
from urllib.parse import urlparse

from darkpanda import ClientProfile, Runtime


CONTRACT_VERSION = "turnstile-client-acceptance-v1"
CLOUDFLARE_CHALLENGE_ORIGIN = "https://challenges.cloudflare.com"
CLOUDFLARE_MESSAGE_SOURCE = "cloudflare-challenge"
RESPONSE_SURFACES = ("message", "cfInput", "compatInput", "api")

# This tuple and validate_fixture_result() are the executable acceptance
# contract.  Do not add permissive fallbacks based on page appearance, iframe
# presence, a single response surface, or a fixture-specific exception.
FIXTURES = (
    {
        "name": "non-interactive",
        "url": "https://peet.ws/turnstile-test/non-interactive.html",
        "native_input_policy": "forbidden",
    },
    {
        "name": "invisible",
        "url": "https://peet.ws/turnstile-test/invisible.html",
        "native_input_policy": "forbidden",
    },
    {
        "name": "managed",
        "url": "https://peet.ws/turnstile-test/managed.html",
        "native_input_policy": "required_before_complete",
    },
)


INSTALL_ACCEPTANCE_MONITOR = r"""
(() => {
    const key = '__darkpandaTurnstileAcceptance';
    const old = globalThis[key];
    if (old && old.listener) removeEventListener('message', old.listener, true);

    const state = {
        contractVersion: 'turnstile-client-acceptance-v1',
        sequence: [],
        forbiddenEvents: [],
        result: null,
        error: null,
        resetEvidence: null,
        listener: null
    };
    const onMessage = event => {
        const data = event.data;
        if (!data || typeof data !== 'object' ||
            data.source !== 'cloudflare-challenge') {
            return;
        }
        state.sequence.push(String(data.event || 'unknown'));
        if (data.event === 'fail' || data.event === 'unsupported') {
            state.forbiddenEvents.push(String(data.event));
            state.error = `Turnstile ${data.event}`;
            return;
        }
        if (data.event !== 'complete') return;

        const messageToken = typeof data.token === 'string' ? data.token : '';
        const trusted = event.isTrusted;
        const origin = event.origin;
        const protocolSource = String(data.source || '');
        const windowSourcePresent = event.source !== null;
        const windowSourceIsTop = event.source === globalThis;
        setTimeout(() => {
            const cfValue = document.querySelector(
                '[name=cf-turnstile-response]'
            )?.value || '';
            const compatValue = document.querySelector(
                '[name=g-recaptcha-response]'
            )?.value || '';
            let apiValue = '';
            try { apiValue = turnstile.getResponse() || ''; } catch (_) {}
            state.result = {
                contractVersion: state.contractVersion,
                result: 'CLIENT_FIXTURE_COMPLETE',
                validationLevel: 'client_completed',
                siteverify: false,
                sequence: state.sequence.slice(),
                forbiddenEvents: state.forbiddenEvents.slice(),
                trusted,
                origin,
                protocolSource,
                windowSourcePresent,
                windowSourceIsTop,
                tokenLength: messageToken.length,
                responseLengths: {
                    message: messageToken.length,
                    cfInput: cfValue.length,
                    compatInput: compatValue.length,
                    api: apiValue.length
                },
                responsesEqual:
                    messageToken === cfValue &&
                    messageToken === compatValue &&
                    messageToken === apiValue,
                expired: turnstile.isExpired(),
                resetEvidence: state.resetEvidence,
                userAgent: navigator.userAgent,
                brands: navigator.userAgentData?.brands || [],
                platform: navigator.userAgentData?.platform || '',
                secure: isSecureContext
            };
        }, 0);
    };
    state.listener = onMessage;
    globalThis[key] = state;
    addEventListener('message', onMessage, true);
    turnstile.reset();
    let apiAfterReset = '__getResponse_threw__';
    try { apiAfterReset = turnstile.getResponse() || ''; } catch (_) {}
    const cfAfterReset =
        document.querySelector('[name=cf-turnstile-response]')?.value || '';
    const compatAfterReset =
        document.querySelector('[name=g-recaptcha-response]')?.value || '';
    const messageCleared =
        !state.sequence.includes('complete') && state.result === null;
    state.resetEvidence = {
        performedBeforeCompletion: messageCleared,
        messageCleared,
        cfInputCleared: cfAfterReset === '',
        compatInputCleared: compatAfterReset === '',
        apiCleared: apiAfterReset === '',
        allSurfacesCleared:
            messageCleared && cfAfterReset === '' &&
            compatAfterReset === '' && apiAfterReset === ''
    };
    return true;
})()
"""


def pump(page: object, delay_ms: int = 100) -> None:
    page.evaluate(
        f"new Promise(resolve => setTimeout(resolve, {delay_ms}))",
        promise_timeout_ms=max(2_000, delay_ms + 1_000),
    )


def require(condition: bool, message: str, evidence: object = None) -> None:
    """Enforce a contract condition even when Python runs with ``-O``."""

    if condition:
        return
    suffix = "" if evidence is None else f": {evidence!r}"
    raise AssertionError(f"{message}{suffix}")


def wait_for_turnstile(page: object, timeout_seconds: float = 30.0) -> None:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        ready = json.loads(
            page.evaluate(
                "typeof turnstile === 'object' && "
                "typeof turnstile.reset === 'function'"
            )
        )
        if ready is True:
            return
        pump(page)
    raise AssertionError("Turnstile public API did not become ready")


def choose_direct_frame(
    page: object,
    click_attempts: dict[int, int],
    last_click_at: dict[int, float],
    now: float,
):
    frames = page.frames(visible=True, attached=True)
    root = next((frame for frame in frames if frame.is_root), None)
    if root is None:
        return None
    candidates = []
    for frame in frames:
        parsed = urlparse(frame.url)
        if (
            frame.parent_frame_id != root.frame_id
            or parsed.scheme not in {"http", "https"}
            or f"{parsed.scheme}://{parsed.netloc}" != CLOUDFLARE_CHALLENGE_ORIGIN
            or frame.owner_rect is None
            or frame.owner_rect.width < 10
            or frame.owner_rect.height < 10
            or click_attempts.get(frame.frame_id, 0) >= 4
            or now - last_click_at.get(frame.frame_id, 0.0) < 2.0
        ):
            continue
        candidates.append(frame)
    if not candidates:
        return None
    return min(
        candidates,
        key=lambda frame: (
            click_attempts.get(frame.frame_id, 0),
            abs(frame.owner_rect.width - 300) + abs(frame.owner_rect.height - 65),
            frame.child_count,
            frame.frame_id,
        ),
    )


def wait_for_client_completion(
    page: object,
    *,
    fixture: dict[str, str],
    timeout_seconds: float = 45.0,
) -> dict:
    wait_for_turnstile(page)
    require(
        json.loads(page.evaluate(INSTALL_ACCEPTANCE_MONITOR)) is True,
        "Turnstile acceptance monitor installation failed",
    )

    input_policy = fixture["native_input_policy"]
    click_attempts: dict[int, int] = {}
    last_click_at: dict[int, float] = {}
    native_input_evidence: list[dict] = []
    deadline = time.monotonic() + timeout_seconds
    last_state: dict = {}
    while time.monotonic() < deadline:
        last_state = json.loads(
            page.evaluate(
                "({"
                "result: globalThis.__darkpandaTurnstileAcceptance?.result || null,"
                "error: globalThis.__darkpandaTurnstileAcceptance?.error || null,"
                "sequence: globalThis.__darkpandaTurnstileAcceptance?.sequence || [],"
                "forbiddenEvents: "
                "globalThis.__darkpandaTurnstileAcceptance?.forbiddenEvents || []"
                "})"
            )
        )
        if last_state.get("error"):
            raise AssertionError(str(last_state["error"]))
        if last_state.get("result") is not None:
            if input_policy == "required_before_complete" and not native_input_evidence:
                raise AssertionError(
                    "Managed complete was observed before any trusted native "
                    "page.click attempt"
                )

            # Give a terminal fail/unsupported message a deterministic chance
            # to invalidate an immediately preceding complete message.
            pump(page, 250)
            terminal_state = json.loads(
                page.evaluate(
                    "({"
                    "result: globalThis.__darkpandaTurnstileAcceptance?.result || null,"
                    "error: globalThis.__darkpandaTurnstileAcceptance?.error || null,"
                    "sequence: globalThis.__darkpandaTurnstileAcceptance?.sequence || [],"
                    "forbiddenEvents: "
                    "globalThis.__darkpandaTurnstileAcceptance?.forbiddenEvents || []"
                    "})"
                )
            )
            if terminal_state.get("error"):
                raise AssertionError(str(terminal_state["error"]))
            result = dict(terminal_state["result"])
            result.update(
                {
                    "resultType": "fixture",
                    "fixture": fixture["name"],
                    "url": fixture["url"],
                    "matrixComplete": False,
                    "nativeInputPolicy": input_policy,
                    "nativeInputAttempts": len(native_input_evidence),
                    "nativeInputEvidence": native_input_evidence,
                    "completionObservedAfterNativeInput": bool(
                        native_input_evidence
                    ),
                    "sequence": terminal_state.get("sequence", []),
                    "forbiddenEvents": terminal_state.get(
                        "forbiddenEvents", []
                    ),
                }
            )
            return result

        if input_policy == "required_before_complete":
            now = time.monotonic()
            frame = choose_direct_frame(page, click_attempts, last_click_at, now)
            if frame is not None:
                page.click(
                    "body",
                    frame_id=frame.frame_id,
                    pierce_shadow=True,
                    timeout_ms=5_000,
                    move_delay_ms=16,
                    press_delay_ms=60,
                )
                click_attempts[frame.frame_id] = click_attempts.get(frame.frame_id, 0) + 1
                last_click_at[frame.frame_id] = time.monotonic()
                parsed = urlparse(frame.url)
                native_input_evidence.append(
                    {
                        "kind": "trusted_native_input_attempt",
                        "dispatchPath": "page.click",
                        "target": "body",
                        "frameId": frame.frame_id,
                        "frameOrigin": f"{parsed.scheme}://{parsed.netloc}",
                    }
                )
        pump(page)

    failures = [
        {
            "host": observation.host,
            "pathCategory": observation.path_category,
            "resourceType": observation.resource_type,
            "initiatorContext": observation.initiator_context,
            "failureKind": observation.failure_kind,
        }
        for observation in page.network_observations().observations
        if observation.phase == "fail"
    ]
    raise AssertionError(
        "Turnstile trusted complete timeout: "
        f"sequenceCounts={dict(Counter(last_state.get('sequence', [])))!r} "
        f"clickAttempts={dict(sorted(click_attempts.items()))!r} failures={failures!r}"
    )


def validate_fixture_result(fixture: dict[str, str], result: dict) -> None:
    """Apply the immutable v1 client-completion contract without fallbacks."""

    def fixture_require(condition: bool, message: str) -> None:
        require(condition, message, result)

    fixture_require(
        result["contractVersion"] == CONTRACT_VERSION,
        "acceptance contract version mismatch",
    )
    fixture_require(result["resultType"] == "fixture", "invalid result type")
    fixture_require(result["fixture"] == fixture["name"], "fixture mismatch")
    fixture_require(result["url"] == fixture["url"], "fixture URL mismatch")
    fixture_require(
        result["result"] == "CLIENT_FIXTURE_COMPLETE",
        "fixture did not reach client completion",
    )
    fixture_require(
        result["validationLevel"] == "client_completed",
        "invalid validation level",
    )
    fixture_require(result["siteverify"] is False, "unexpected Siteverify claim")
    fixture_require(
        result["matrixComplete"] is False,
        "a fixture result cannot claim matrix completion",
    )

    # The accepted message itself must be a browser-trusted Cloudflare message
    # from the cross-origin challenge child, never a same-window postMessage.
    fixture_require(result["trusted"] is True, "complete message was not trusted")
    fixture_require(
        result["origin"] == CLOUDFLARE_CHALLENGE_ORIGIN,
        "complete message origin mismatch",
    )
    fixture_require(
        result["protocolSource"] == CLOUDFLARE_MESSAGE_SOURCE,
        "Cloudflare protocol source mismatch",
    )
    fixture_require(
        result["windowSourcePresent"] is True,
        "complete message Window source is absent",
    )
    fixture_require(
        result["windowSourceIsTop"] is False,
        "complete message came from the top Window",
    )
    fixture_require("complete" in result["sequence"], "complete event is absent")
    fixture_require(
        not any(
            event in {"fail", "unsupported"} for event in result["sequence"]
        ),
        "forbidden terminal event was observed",
    )
    fixture_require(
        result["forbiddenEvents"] == [],
        "fail/unsupported event was recorded",
    )

    # All four independently exposed response surfaces are mandatory.  A lone
    # message token, hidden input, compatibility input, or API response fails.
    response_lengths = result["responseLengths"]
    fixture_require(
        set(response_lengths) == set(RESPONSE_SURFACES),
        "response surface set mismatch",
    )
    fixture_require(
        all(int(response_lengths[name]) > 0 for name in RESPONSE_SURFACES),
        "one or more response surfaces are empty",
    )
    fixture_require(
        int(result["tokenLength"]) == int(response_lengths["message"]),
        "message response length mismatch",
    )
    fixture_require(
        len({int(response_lengths[name]) for name in RESPONSE_SURFACES}) == 1,
        "response surface lengths differ",
    )
    fixture_require(result["responsesEqual"] is True, "response surfaces differ")
    fixture_require(result["expired"] is False, "response is expired")

    reset = result["resetEvidence"]
    fixture_require(
        reset["performedBeforeCompletion"] is True,
        "reset did not precede completion",
    )
    fixture_require(reset["messageCleared"] is True, "reset left message response")
    fixture_require(reset["cfInputCleared"] is True, "reset left CF input response")
    fixture_require(
        reset["compatInputCleared"] is True,
        "reset left compatibility input response",
    )
    fixture_require(reset["apiCleared"] is True, "reset left API response")
    fixture_require(
        reset["allSurfacesCleared"] is True,
        "reset did not clear every response surface",
    )

    if fixture["native_input_policy"] == "forbidden":
        fixture_require(
            result["nativeInputAttempts"] == 0,
            "native input is forbidden for this fixture",
        )
        fixture_require(
            result["nativeInputEvidence"] == [],
            "native input evidence is forbidden for this fixture",
        )
        fixture_require(
            result["completionObservedAfterNativeInput"] is False,
            "zero-input fixture was marked input-dependent",
        )
    else:
        fixture_require(
            fixture["native_input_policy"] == "required_before_complete",
            "unknown native input policy",
        )
        fixture_require(
            int(result["nativeInputAttempts"]) > 0,
            "Managed requires native input before completion",
        )
        fixture_require(
            result["nativeInputAttempts"] == len(result["nativeInputEvidence"]),
            "native input count/evidence mismatch",
        )
        fixture_require(
            result["completionObservedAfterNativeInput"] is True,
            "Managed completion preceded native input",
        )
        fixture_require(
            all(
                evidence.get("kind") == "trusted_native_input_attempt"
                and evidence.get("dispatchPath") == "page.click"
                and evidence.get("frameOrigin") == CLOUDFLARE_CHALLENGE_ORIGIN
                for evidence in result["nativeInputEvidence"]
            ),
            "Managed native input evidence is invalid",
        )

    fixture_require(
        "Chrome/149.0.0.0" in str(result["userAgent"]),
        "Chrome 149 user agent contract mismatch",
    )
    fixture_require(result["platform"] == "Windows", "platform contract mismatch")
    fixture_require(result["secure"] is True, "fixture is not a secure context")
    fixture_require(
        any(
            brand.get("brand") == "Google Chrome"
            and brand.get("version") == "149"
            for brand in result["brands"]
        ),
        "Chrome 149 UA-CH brand contract mismatch",
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--library", required=True)
    parser.add_argument("--wreq", required=True)
    parser.add_argument(
        "--dns-nameserver",
        action="append",
        default=[],
        help="explicit IP-literal DNS endpoint; repeat for multiple resolvers",
    )
    parser.add_argument(
        "--only",
        choices=("all", *(fixture["name"] for fixture in FIXTURES)),
        default="all",
        help="run one fixture or the complete three-page matrix",
    )
    args = parser.parse_args()

    with Runtime(
        library_path=args.library,
        wreq_library_path=args.wreq,
        navigation_timeout_ms=30_000,
        locale="en-US",
        timezone="UTC",
        profile=ClientProfile.CHROME149,
        dns_nameservers=args.dns_nameserver or None,
    ) as runtime:
        selected_fixtures = (
            FIXTURES
            if args.only == "all"
            else tuple(
                fixture for fixture in FIXTURES if fixture["name"] == args.only
            )
        )
        fixture_results: dict[str, dict] = {}
        for fixture in selected_fixtures:
            with runtime.new_page() as page:
                page.navigate(fixture["url"], timeout_ms=30_000)
                result = wait_for_client_completion(
                    page,
                    fixture=fixture,
                )
                validate_fixture_result(fixture, result)
                fixture_results[fixture["name"]] = result
                # Never print the token itself; only expose non-sensitive
                # client-completion/profile evidence.
                print(json.dumps(result, separators=(",", ":")))

    if args.only == "all":
        require(
            set(fixture_results) == {fixture["name"] for fixture in FIXTURES},
            "complete fixture matrix was not collected",
            fixture_results,
        )
        print(
            json.dumps(
                {
                    "contractVersion": CONTRACT_VERSION,
                    "resultType": "matrix",
                    "result": "CLIENT_MATRIX_COMPLETE",
                    "validationLevel": "client_completed",
                    "siteverify": False,
                    "matrixComplete": True,
                    "fixtures": {
                        name: fixture_result["result"]
                        for name, fixture_result in fixture_results.items()
                    },
                },
                separators=(",", ":"),
            )
        )
    else:
        print(
            json.dumps(
                {
                    "contractVersion": CONTRACT_VERSION,
                    "resultType": "single_fixture_run",
                    "result": "CLIENT_FIXTURE_RUN_COMPLETE",
                    "validationLevel": "client_completed",
                    "siteverify": False,
                    "matrixComplete": False,
                    "fixture": args.only,
                },
                separators=(",", ":"),
            )
        )


if __name__ == "__main__":
    main()
