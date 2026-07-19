// Exercises setTimeout / setInterval inside a WorkerGlobalScope.
// Mirrors src/browser/tests/window/timers.html.
(async function() {
  try {
    const results = {};

    const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

    // setTimeout: returns a number; passes extra args through; `this` is self.
    {
      let timeout_this = null;
      const sum = await new Promise((resolve) => {
        const id = setTimeout(function (a, b) {
          timeout_this = this;
          resolve(a + b);
        }, 1, 2, 3);
        results.setTimeout_id_is_number = (typeof id === 'number');
      });
      results.setTimeout_args = sum;
      results.setTimeout_this_is_self = (timeout_this === self);
      results.setTimeout_length = setTimeout.length;
    }

    // setInterval fires repeatedly; clearInterval stops it.
    // A second timer cleared before its first tick must never fire.
    {
      let count1 = 0;
      const id1 = setInterval(() => { count1 += 1; }, 1);

      let fired2 = false;
      const id2 = setInterval(() => { fired2 = true; }, 1);
      clearInterval(id2);

      results.setInterval_ids_distinct = (id1 !== id2);

      await sleep(10);
      clearInterval(id1);
      const after_clear = count1;
      await sleep(5);

      results.setInterval_fired_multiple = (after_clear >= 1);
      results.setInterval_clear_stops = (count1 === after_clear);
      results.setInterval_pre_clear_silent = !fired2;
    }

    // This interval is installed by the microtask which resumes the async
    // function after the two sleep timers above. Timer-task microtasks inherit
    // timer nesting, so Chrome 149 installs it at nesting level 4: callbacks
    // one through three are immediate and the fourth is 4 ms-clamped. The
    // Window timer suite separately covers a top-level interval (six immediate
    // callbacks). The sentinel compares task ordering without relying on a
    // narrow performance.now() threshold.
    {
      let count = 0;
      const countAtSentinel = await new Promise((resolve) => {
        let interval;
        interval = setInterval(() => {
          count += 1;
          if (count === 1) {
            setTimeout(() => {
              clearInterval(interval);
              resolve(count);
            }, 2);
          }
        }, 0);
      });
      results.setInterval_zero_preclamp_count = countAtSentinel;
    }

    // Microtasks stay inside the current timer task and inherit its nesting
    // level. MessagePort delivery starts a new task and resets that level.
    {
      const order = await new Promise((resolve) => {
        const channel = new MessageChannel();
        const values = [];
        let settled = false;

        const finish = (result) => {
          if (settled) return;
          settled = true;
          clearTimeout(watchdog);
          channel.port1.close();
          channel.port2.close();
          resolve(result);
        };
        const watchdog = setTimeout(() => finish(['watchdog']), 100);
        const record = (value) => {
          values.push(value);
          if (values.length === 2) finish(values);
        };

        channel.port1.onmessage = () => {
          setTimeout(() => record('message-task-timer'), 0);
        };

        const nest = (level) => {
          if (level < 6) {
            setTimeout(() => nest(level + 1), 0);
            return;
          }
          queueMicrotask(() => {
            setTimeout(() => record('microtask-timer'), 0);
          });
          channel.port2.postMessage(null);
        };
        setTimeout(() => nest(1), 0);
      });
      results.timer_nesting_task_order = order.join(',');
    }

    // clearTimeout / clearInterval with bogus ids must be silent.
    {
      let threw = false;
      try {
        clearTimeout(-1);
        clearInterval(-2);
      } catch (_) { threw = true; }
      results.clear_invalid_silent = !threw;
    }

    // Legacy: setTimeout("...", n) compiles the string into a function body.
    {
      self.__st_string_ran = 0;
      const id = setTimeout("self.__st_string_ran = 42;", 1);
      results.setTimeout_string_id_is_number = (typeof id === 'number');
      await sleep(5);
      results.setTimeout_string_ran = self.__st_string_ran;
    }

    // Legacy: setInterval("...", n) compiles the string into a function body.
    {
      self.__si_string_ran = 0;
      const id = setInterval("self.__si_string_ran += 1;", 1);
      await sleep(5);
      clearInterval(id);
      results.setInterval_string_ran = (self.__si_string_ran >= 1);
    }

    // The legacy DOMString overload accepts non-function handlers.
    {
      let threw = false;
      try { setTimeout(123, 1); } catch (_) { threw = true; }
      results.setTimeout_invalid_throws = threw;
    }

    postMessage({ ok: true, results });
  } catch (e) {
    postMessage({ ok: false, err: String(e), stack: e.stack });
  }
})();
