"""Compare JavaScript-engine and embedder-visible behavior with a live Chrome.

This is intentionally a differential probe, not an anti-bot-site special case.
It talks to the real Chrome CDP endpoint only for the Chrome half; the
DarkPanda half uses the direct in-process Python ABI.
"""

from __future__ import annotations

import argparse
import json
import os
import time
import urllib.request
from pathlib import Path
from typing import Any

import websocket

from darkpanda import ClientProfile, Runtime


PROBE = r"""(async () => {
  const bits = value => {
    const buffer = new ArrayBuffer(8);
    const view = new DataView(buffer);
    view.setFloat64(0, value, false);
    return view.getUint32(0, false).toString(16).padStart(8, '0') +
      view.getUint32(4, false).toString(16).padStart(8, '0');
  };
  const ownKeys = value => Reflect.ownKeys(value).map(String);
  const descriptor = (object, key) => {
    const desc = Object.getOwnPropertyDescriptor(object, key);
    if (!desc) return null;
    return {
      writable: desc.writable,
      enumerable: desc.enumerable,
      configurable: desc.configurable,
      get: desc.get && Function.prototype.toString.call(desc.get),
      set: desc.set && Function.prototype.toString.call(desc.set),
      valueType: typeof desc.value,
    };
  };
  const thrown = callback => {
    try {
      callback();
      return null;
    } catch (error) {
      return {
        name: error.name,
        message: error.message,
        stack: String(error.stack),
      };
    }
  };
  function stackOuter() { return stackInner(); }
  function stackInner() { return new Error('probe').stack; }

  const math = [
    ['sin', Math.sin, 1e300],
    ['sinTiny', Math.sin, 1e-300],
    ['cos', Math.cos, 1e300],
    ['tan', Math.tan, 1e300],
    ['exp', Math.exp, 0.1],
    ['expm1', Math.expm1, 1e-10],
    ['log', Math.log, 10],
    ['log1p', Math.log1p, 1e-10],
    ['cbrtNegativeZero', Math.cbrt, -0],
    ['atanh', Math.atanh, 0.5],
    ['sinh', Math.sinh, 0.1],
    ['tanh', Math.tanh, 20],
  ].map(([name, fn, input]) => [name, bits(fn(input))]);
  math.push(['atan2NegativeZero', bits(Math.atan2(-0, -0))]);
  math.push(['pow', bits(Math.pow(1.0000000000000002, 4503599627370496))]);
  math.push(['hypot', bits(Math.hypot(3, 4, 1e-300))]);

  const hashDoubles = values => {
    const buffer = new ArrayBuffer(8);
    const view = new DataView(buffer);
    let hash = 0xcbf29ce484222325n;
    for (const value of values) {
      view.setFloat64(0, value, false);
      for (let index = 0; index < 8; index++) {
        hash ^= BigInt(view.getUint8(index));
        hash = BigInt.asUintN(64, hash * 0x100000001b3n);
      }
    }
    return hash.toString(16).padStart(16, '0');
  };
  let randomState = 0x6d2b79f5;
  const unit = () => {
    randomState ^= randomState << 13;
    randomState ^= randomState >>> 17;
    randomState ^= randomState << 5;
    return (randomState >>> 0) / 0x100000000;
  };
  const mathCorpusValues = {
    trigonometric: [],
    exponential: [],
    hyperbolic: [],
    powers: [],
  };
  for (let index = 0; index < 512; index++) {
    const x = unit() * 2 - 1;
    const y = unit() * 2 - 1;
    mathCorpusValues.trigonometric.push(
      Math.sin(x * 1e12),
      Math.cos(x * 1e12),
      Math.tan(x * 1e12),
      Math.asin(x),
      Math.acos(x),
      Math.atan(x * 1e6),
      Math.atan2(x, y),
    );
    mathCorpusValues.exponential.push(
      Math.exp(x * 16),
      Math.expm1(x),
      Math.log(Math.abs(x) + 1e-300),
      Math.log1p(Math.abs(x)),
      Math.log2(Math.abs(x) + 1e-300),
      Math.log10(Math.abs(x) + 1e-300),
    );
    mathCorpusValues.hyperbolic.push(
      Math.sinh(x * 16),
      Math.cosh(x * 16),
      Math.tanh(x * 16),
      Math.asinh(x * 1e6),
      Math.acosh(Math.abs(x) * 1e6 + 1),
      Math.atanh(x),
    );
    mathCorpusValues.powers.push(
      Math.pow(Math.abs(x) + 1e-9, y * 32),
      Math.cbrt(x * 1e300),
      Math.hypot(x * 1e300, y * 1e-300, 1),
    );
  }
  const mathCorpus = Object.fromEntries(
    Object.entries(mathCorpusValues).map(([name, values]) => [
      name,
      hashDoubles(values),
    ]),
  );

  const wasmBytes = new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0]);
  const wasmModule = new WebAssembly.Module(wasmBytes);

  const microtasks = [];
  queueMicrotask(() => microtasks.push('queueMicrotask'));
  Promise.resolve().then(() => microtasks.push('promise'));
  microtasks.push('script');
  await new Promise(resolve => setTimeout(() => {
    microtasks.push('timeout');
    resolve();
  }, 0));

  const sharedBuffer = new WebAssembly.Memory({
    initial: 1,
    maximum: 1,
    shared: true,
  }).buffer;

  const recursionLimit = (() => {
    let depth = 0;
    try {
      (function recurse() {
        depth++;
        recurse();
      })();
    } catch (error) {
      return {depth, name: error.name, message: error.message};
    }
    return {depth, name: '', message: ''};
  })();

  return {
    userAgent: navigator.userAgent,
    features: Object.fromEntries([
      'Temporal',
      'Iterator',
      'SharedArrayBuffer',
      'WebAssembly',
      'BigInt64Array',
      'FinalizationRegistry',
      'WeakRef',
      'ShadowRealm',
      'DisposableStack',
      'AsyncDisposableStack',
      'Atomics',
      'structuredClone',
    ].map(key => [key, typeof globalThis[key]])),
    methods: {
      regexpEscape: typeof RegExp.escape,
      promiseTry: typeof Promise.try,
      promiseWithResolvers: typeof Promise.withResolvers,
      arrayFromAsync: typeof Array.fromAsync,
      iteratorFrom: typeof globalThis.Iterator?.from,
      atomicsWaitAsync: typeof Atomics.waitAsync,
      wasmCompileStreaming: typeof WebAssembly.compileStreaming,
      errorIsError: typeof Error.isError,
    },
    nativeSource: {
      arrayMap: Function.prototype.toString.call(Array.prototype.map),
      promiseResolve: Function.prototype.toString.call(Promise.resolve),
      mathSin: Function.prototype.toString.call(Math.sin),
      eval: Function.prototype.toString.call(eval),
      fetch: Function.prototype.toString.call(fetch),
      createElement: Function.prototype.toString.call(
        Document.prototype.createElement,
      ),
    },
    ownKeys: {
      Promise: ownKeys(Promise),
      Error: ownKeys(Error),
      Atomics: ownKeys(Atomics),
      WebAssembly: ownKeys(WebAssembly),
      Intl: ownKeys(Intl),
    },
    descriptors: {
      errorStackTraceLimit: descriptor(Error, 'stackTraceLimit'),
      promiseResolve: descriptor(Promise, 'resolve'),
      arrayMap: descriptor(Array.prototype, 'map'),
      documentCreateElement: descriptor(
        Document.prototype,
        'createElement',
      ),
    },
    stack: stackOuter(),
    recursionLimit,
    evalSyntax: thrown(() => eval('function {')),
    illegalInvocation: thrown(() =>
      Document.prototype.createElement.call({}),
    ),
    math,
    mathCorpus,
    intl: {
      dateTimeFormat: new Intl.DateTimeFormat().resolvedOptions(),
      numberFormat: new Intl.NumberFormat().resolvedOptions(),
      supportedCalendars: Intl.supportedValuesOf
        ? Intl.supportedValuesOf('calendar').slice(0, 8)
        : null,
      canonicalLocales: Intl.getCanonicalLocales(['EN-us', 'iw-il']),
    },
    wasm: {
      moduleTag: Object.prototype.toString.call(wasmModule),
      invalidModule: thrown(() =>
        new WebAssembly.Module(new Uint8Array([0])),
      ),
      sharedBufferTag: Object.prototype.toString.call(sharedBuffer),
      mainThreadWait: thrown(() =>
        Atomics.wait(new Int32Array(sharedBuffer), 0, 0, 0),
      ),
    },
    microtasks,
  };
})()
//# sourceURL=anonymous"""


class CDP:
    def __init__(self, socket: websocket.WebSocket) -> None:
        self.socket = socket
        self.next_id = 0

    def call(
        self,
        method: str,
        params: dict[str, Any] | None = None,
        session_id: str | None = None,
    ) -> dict[str, Any]:
        self.next_id += 1
        call_id = self.next_id
        message: dict[str, Any] = {"id": call_id, "method": method}
        if params is not None:
            message["params"] = params
        if session_id is not None:
            message["sessionId"] = session_id
        self.socket.send(json.dumps(message, separators=(",", ":")))

        while True:
            response = json.loads(self.socket.recv())
            if response.get("id") != call_id:
                continue
            if "error" in response:
                raise RuntimeError(f"{method}: {response['error']}")
            return response.get("result", {})


def chrome_probe(endpoint: str, url: str) -> tuple[dict[str, Any], dict[str, Any]]:
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(endpoint.rstrip("/") + "/json/version", timeout=10) as response:
        version = json.load(response)

    os.environ["NO_PROXY"] = "127.0.0.1,localhost"
    os.environ["no_proxy"] = "127.0.0.1,localhost"
    socket = websocket.create_connection(
        version["webSocketDebuggerUrl"],
        timeout=30,
        suppress_origin=True,
        http_no_proxy=["127.0.0.1", "localhost"],
    )
    cdp = CDP(socket)
    target_id: str | None = None
    try:
        browser_version = cdp.call("Browser.getVersion")
        if browser_version.get("jsVersion"):
            version["V8-Version"] = browser_version["jsVersion"]
        target_id = cdp.call("Target.createTarget", {"url": url})["targetId"]
        session_id = cdp.call(
            "Target.attachToTarget",
            {"targetId": target_id, "flatten": True},
        )["sessionId"]
        cdp.call("Runtime.enable", session_id=session_id)
        cdp.call("Page.enable", session_id=session_id)

        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            ready = cdp.call(
                "Runtime.evaluate",
                {"expression": "document.readyState", "returnByValue": True},
                session_id,
            )
            if ready.get("result", {}).get("value") == "complete":
                break
            time.sleep(0.05)
        else:
            raise TimeoutError("Chrome test page did not reach readyState=complete")

        evaluated = cdp.call(
            "Runtime.evaluate",
            {
                "expression": PROBE,
                "awaitPromise": True,
                "returnByValue": True,
            },
            session_id,
        )
        if "exceptionDetails" in evaluated:
            raise RuntimeError(evaluated["exceptionDetails"])
        return version, evaluated["result"]["value"]
    finally:
        if target_id is not None:
            cdp.call("Target.closeTarget", {"targetId": target_id})
        socket.close()


def darkpanda_probe(
    library: Path,
    wreq: Path,
    url: str,
    locale: str,
    timezone: str | None,
) -> dict[str, Any]:
    with Runtime(
        library_path=library,
        wreq_library_path=wreq,
        locale=locale,
        timezone=timezone,
        profile=ClientProfile.CHROME149,
    ) as runtime:
        with runtime.new_page() as page:
            page.navigate(url, timeout_ms=30_000)
            return json.loads(page.evaluate(PROBE, promise_timeout_ms=30_000))


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser()
    parser.add_argument("--chrome-endpoint", default="http://127.0.0.1:9222")
    parser.add_argument(
        "--url",
        default=(
            "http://127.0.0.1:9583/src/browser/tests/"
            "performance_resource_timing_fixture.html"
        ),
    )
    parser.add_argument("--library", type=Path, default=root / "zig-out/bin/darkpanda.dll")
    parser.add_argument("--wreq", type=Path, default=root / "zig-out/bin/wreq.dll")
    parser.add_argument("--locale", default="en-US")
    parser.add_argument("--timezone", default="UTC")
    args = parser.parse_args()

    version, chrome = chrome_probe(args.chrome_endpoint, args.url)
    darkpanda = darkpanda_probe(
        args.library,
        args.wreq,
        args.url,
        args.locale,
        args.timezone or None,
    )

    print(
        f"Chrome: {version['Browser']} / "
        f"V8 {version.get('V8-Version', 'not reported')}"
    )
    for key, chrome_value in chrome.items():
        darkpanda_value = darkpanda.get(key)
        if chrome_value == darkpanda_value:
            print(f"SAME {key}")
            continue
        print(f"DIFF {key}")
        print("  chrome   " + json.dumps(chrome_value, ensure_ascii=False, separators=(",", ":")))
        print("  darkpanda " + json.dumps(darkpanda_value, ensure_ascii=False, separators=(",", ":")))


if __name__ == "__main__":
    main()
