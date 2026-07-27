"""Compare high-signal Web API surface topology with an exact Chrome build.

The Chrome half uses CDP only to evaluate the same probe in a real page.  The
DarkPanda half uses the direct in-process Python ABI.  No target-site names or
challenge-specific constants are part of the probe.
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
from v8_chromium_probe import CDP


PROBE = r"""(() => {
  const key = value => typeof value === 'symbol' ? value.toString() : value;
  const keys = value => Reflect.ownKeys(value).map(key);
  const descriptor = (object, name) => {
    const desc = Object.getOwnPropertyDescriptor(object, name);
    if (!desc) return null;
    return {
      valueType: typeof desc.value,
      getType: typeof desc.get,
      setType: typeof desc.set,
      writable: desc.writable,
      enumerable: desc.enumerable,
      configurable: desc.configurable,
    };
  };
  const prototypeChain = value => {
    const result = [];
    for (let object = value, depth = 0; object && depth < 12;
         object = Object.getPrototypeOf(object), depth++) {
      result.push({
        depth,
        tag: Object.prototype.toString.call(object),
        constructorName: object.constructor?.name ?? null,
        keys: keys(object),
      });
    }
    return result;
  };

  const element = document.createElement('div');
  element.style.cssText = 'display:block;color:rgb(1, 2, 3);margin:1px 2px';
  document.documentElement.appendChild(element);
  const computed = getComputedStyle(element);

  const canvas = document.createElement('canvas');
  canvas.width = 2;
  canvas.height = 1;
  const context = canvas.getContext('2d');
  context.fillStyle = 'rgba(255, 0, 0, 0.5)';
  context.fillRect(0, 0, 1, 1);

  const ownNames = Object.getOwnPropertyNames(window);
  const ownFunctions = ownNames.filter(name => {
    try { return typeof window[name] === 'function'; }
    catch { return false; }
  });

  const result = {
    window: {
      objectKeys: Object.keys(window),
      ownNames,
      ownKeys: keys(window),
      ownFunctions,
      prototypeChain: prototypeChain(window),
      holders: Object.fromEntries([
        'document', 'fetch', 'setTimeout', 'postMessage', 'devicePixelRatio',
        'addEventListener', 'console', 'TEMPORARY', 'PERSISTENT',
      ].map(name => [name, {
        window: Object.hasOwn(window, name),
        windowPrototype: Object.hasOwn(Window.prototype, name),
        eventTargetPrototype: Object.hasOwn(EventTarget.prototype, name),
        descriptor: descriptor(window, name),
      }])),
    },
    navigator: {
      ownKeys: keys(navigator),
      prototypeKeys: keys(Navigator.prototype),
      chain: prototypeChain(navigator),
    },
    css: {
      objectKeys: Object.keys(computed),
      ownNames: Object.getOwnPropertyNames(computed),
      ownKeys: keys(computed),
      prototypeKeys: keys(CSSStyleDeclaration.prototype),
      length: computed.length,
      indexed: Array.from(computed),
      values: {
        display: computed.getPropertyValue('display'),
        color: computed.getPropertyValue('color'),
        marginTop: computed.getPropertyValue('margin-top'),
      },
      index0: descriptor(computed, '0'),
    },
    canvas: {
      elementPrototypeKeys: keys(HTMLCanvasElement.prototype),
      contextPrototypeKeys: keys(CanvasRenderingContext2D.prototype),
      elementChain: prototypeChain(canvas),
      contextChain: prototypeChain(context),
      pixels: Array.from(context.getImageData(0, 0, 2, 1).data),
      descriptors: {
        width: descriptor(HTMLCanvasElement.prototype, 'width'),
        fillStyle: descriptor(CanvasRenderingContext2D.prototype, 'fillStyle'),
        globalAlpha: descriptor(CanvasRenderingContext2D.prototype, 'globalAlpha'),
        fillRect: descriptor(CanvasRenderingContext2D.prototype, 'fillRect'),
      },
      methods: Object.fromEntries([
        'toDataURL', 'toBlob', 'captureStream', 'measureText', 'roundRect',
        'isPointInPath', 'getTransform', 'reset',
      ].map(name => [name,
        typeof (name in canvas ? canvas[name] : context[name])
      ])),
    },
    selectedGlobals: Object.fromEntries([
      'Console', 'CrossOriginWindow', 'Css', 'StorageEstimate',
      'ModelContextClient', 'ReadableStreamAsyncIterator',
      'WEBGL_debug_renderer_info', 'WEBGL_lose_context', 'setImmediate',
    ].map(name => [name, {
      present: name in window,
      own: Object.hasOwn(window, name),
      type: typeof window[name],
    }])),
  };
  element.remove();
  return result;
})()"""


def chrome_probe(endpoint: str, url: str) -> tuple[dict[str, Any], dict[str, Any]]:
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(endpoint.rstrip('/') + '/json/version', timeout=10) as response:
        version = json.load(response)

    os.environ['NO_PROXY'] = '127.0.0.1,localhost'
    os.environ['no_proxy'] = '127.0.0.1,localhost'
    socket = websocket.create_connection(
        version['webSocketDebuggerUrl'],
        timeout=30,
        suppress_origin=True,
        http_no_proxy=['127.0.0.1', 'localhost'],
    )
    cdp = CDP(socket)
    target_id: str | None = None
    try:
        browser_version = cdp.call('Browser.getVersion')
        version['V8-Version'] = browser_version.get('jsVersion')
        target_id = cdp.call('Target.createTarget', {'url': url})['targetId']
        session_id = cdp.call(
            'Target.attachToTarget',
            {'targetId': target_id, 'flatten': True},
        )['sessionId']
        cdp.call('Runtime.enable', session_id=session_id)
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            ready = cdp.call(
                'Runtime.evaluate',
                {'expression': 'document.readyState', 'returnByValue': True},
                session_id,
            )
            if ready.get('result', {}).get('value') == 'complete':
                break
            time.sleep(0.05)
        else:
            raise TimeoutError('Chrome fixture did not finish loading')

        evaluated = cdp.call(
            'Runtime.evaluate',
            {'expression': PROBE, 'returnByValue': True},
            session_id,
        )
        if 'exceptionDetails' in evaluated:
            raise RuntimeError(evaluated['exceptionDetails'])
        return version, evaluated['result']['value']
    finally:
        if target_id is not None:
            cdp.call('Target.closeTarget', {'targetId': target_id})
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
            return json.loads(page.evaluate(f'JSON.stringify({PROBE})'))


def path_diff(left: Any, right: Any, path: str = '') -> list[str]:
    if type(left) is not type(right):
        return [path or '<root>']
    if isinstance(left, dict):
        result: list[str] = []
        for key in sorted(set(left) | set(right)):
            child = f'{path}.{key}' if path else key
            if key not in left or key not in right:
                result.append(child)
            else:
                result.extend(path_diff(left[key], right[key], child))
        return result
    if isinstance(left, list):
        return [] if left == right else [path or '<root>']
    return [] if left == right else [path or '<root>']


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser()
    parser.add_argument('--chrome-endpoint', default='http://127.0.0.1:9223')
    parser.add_argument(
        '--url',
        default='http://127.0.0.1:9583/src/browser/tests/window/webapi_surface_fixture.html',
    )
    parser.add_argument('--library', type=Path, default=root / 'zig-out/bin/darkpanda.dll')
    parser.add_argument('--wreq', type=Path, default=root / 'zig-out/bin/wreq.dll')
    parser.add_argument('--locale', default='en-US')
    parser.add_argument('--timezone', default='Asia/Shanghai')
    parser.add_argument('--json-output', type=Path)
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
        f"Chrome: {version.get('Browser')} / "
        f"V8 {version.get('V8-Version', 'unknown')}"
    )
    print(
        'window counts:',
        f"Object.keys {len(chrome['window']['objectKeys'])} / "
        f"{len(darkpanda['window']['objectKeys'])};",
        f"ownNames {len(chrome['window']['ownNames'])} / "
        f"{len(darkpanda['window']['ownNames'])}",
    )
    print(
        'computed style:',
        f"keys {len(chrome['css']['objectKeys'])} / "
        f"{len(darkpanda['css']['objectKeys'])};",
        f"length {chrome['css']['length']} / {darkpanda['css']['length']}",
    )
    differences = path_diff(chrome, darkpanda)
    print(f'different groups: {len(differences)}')
    for item in differences:
        print(f'DIFF {item}')

    if args.json_output:
        args.json_output.parent.mkdir(parents=True, exist_ok=True)
        args.json_output.write_text(
            json.dumps(
                {'version': version, 'chrome': chrome, 'darkpanda': darkpanda},
                ensure_ascii=False,
                indent=2,
            ),
            encoding='utf-8',
        )


if __name__ == '__main__':
    main()
