// Generic V8 stack/tiering differential probe shared by Window and Worker.
//
// The probe deliberately reports the engine's real RangeError boundary.  It
// does not normalize, clamp, or replace any result.  Repeating several source
// shapes makes the result useful for distinguishing a fixed stack-budget
// offset from tier-specific frame-size differences.
(function installV8RecursionShapes(global) {
  // The differential harness validates this value on both Window and Worker.
  // It prevents a browser disk-cache entry for an older probe body from being
  // mistaken for a current V8 result.
  const sourceRevision = "v8-recursion-shapes-2026-07-15-1";

  function finish(shape, depth, started, error, sink) {
    return {
      shape,
      depth,
      errorName: error && error.name ? String(error.name) : "",
      errorMessage: error && error.message ? String(error.message) : "",
      durationMs: performance.now() - started,
      // Keeping a value live after recursive calls prevents the locals shape
      // from collapsing into the direct shape during optimization.
      sink,
    };
  }

  function directSloppy() {
    let depth = 0;
    const started = performance.now();
    try {
      (function recurse(remaining) {
        depth += 1;
        if (remaining === 0) return;
        recurse(remaining - 1);
      })(-1);
    } catch (error) {
      return finish("direct_sloppy", depth, started, error, 0);
    }
    return finish("direct_sloppy", depth, started, null, 0);
  }

  function directStrict() {
    let depth = 0;
    const started = performance.now();
    try {
      (function recurse(remaining) {
        "use strict";
        depth += 1;
        if (remaining === 0) return;
        recurse(remaining - 1);
      })(-1);
    } catch (error) {
      return finish("direct_strict", depth, started, error, 0);
    }
    return finish("direct_strict", depth, started, null, 0);
  }

  function localsLiveAcrossCall() {
    let depth = 0;
    let sink = 0;
    const started = performance.now();
    try {
      (function recurse(remaining) {
        const live = (remaining ^ depth) | 0;
        depth += 1;
        if (remaining === 0) {
          sink ^= live;
          return;
        }
        recurse(remaining - 1);
        sink ^= live;
      })(-1);
    } catch (error) {
      return finish("locals_live", depth, started, error, sink);
    }
    return finish("locals_live", depth, started, null, sink);
  }

  function argumentsAccess() {
    let depth = 0;
    const started = performance.now();
    try {
      (function recurse() {
        const remaining = arguments[0];
        depth += 1;
        if (remaining === 0) return;
        recurse(remaining - 1);
      })(-1);
    } catch (error) {
      return finish("arguments", depth, started, error, 0);
    }
    return finish("arguments", depth, started, null, 0);
  }

  function mutualRecursion() {
    let depth = 0;
    const started = performance.now();
    function left(remaining) {
      depth += 1;
      if (remaining === 0) return;
      right(remaining - 1);
    }
    function right(remaining) {
      depth += 1;
      if (remaining === 0) return;
      left(remaining - 1);
    }
    try {
      left(-1);
    } catch (error) {
      return finish("mutual", depth, started, error, 0);
    }
    return finish("mutual", depth, started, null, 0);
  }

  function reflectApply() {
    let depth = 0;
    const started = performance.now();
    try {
      (function recurse(remaining) {
        depth += 1;
        if (remaining === 0) return;
        Reflect.apply(recurse, undefined, [remaining - 1]);
      })(-1);
    } catch (error) {
      return finish("reflect_apply", depth, started, error, 0);
    }
    return finish("reflect_apply", depth, started, null, 0);
  }

  const shapes = [
    directSloppy,
    directStrict,
    localsLiveAcrossCall,
    argumentsAccess,
    mutualRecursion,
    reflectApply,
  ];

  function run(roundCount) {
    const rounds = Math.max(1, Math.min(20, Number(roundCount) || 1));
    const samples = [];
    const started = performance.now();
    for (let round = 0; round < rounds; round += 1) {
      // Rotate the order so a shape is not always measured at the same point
      // in the isolate's tiering/compilation history.
      for (let offset = 0; offset < shapes.length; offset += 1) {
        const shape = shapes[(round + offset) % shapes.length];
        const sample = shape();
        sample.round = round;
        sample.order = offset;
        samples.push(sample);
      }
    }
    return {
      sourceRevision,
      scope: typeof document === "undefined" ? global.constructor.name : "Window",
      rounds,
      startedAtMs: started,
      durationMs: performance.now() - started,
      samples,
    };
  }

  Object.defineProperty(global, "__runV8RecursionShapes", {
    value: run,
    writable: false,
    enumerable: false,
    configurable: true,
  });
})(globalThis);
