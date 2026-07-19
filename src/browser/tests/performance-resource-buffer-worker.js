self.onmessage = async (message) => {
  try {
    const keys = Reflect.ownKeys(Performance.prototype).map(String);
    const isPerformance = performance instanceof Performance;
    const isEventTarget = performance instanceof EventTarget;
    const parentIsEventTarget =
      Object.getPrototypeOf(Performance.prototype) === EventTarget.prototype;
    const windowMembersAbsent = [
      "timing",
      "navigation",
      "memory",
      "eventCounts",
      "interactionCount",
    ].every((name) => !(name in performance));
    const descriptor = Object.getOwnPropertyDescriptor(
      Performance.prototype,
      "onresourcetimingbufferfull",
    );
    const handlerDescriptor = descriptor.enumerable === true &&
      descriptor.configurable === true &&
      descriptor.get.name === "get onresourcetimingbufferfull" &&
      descriptor.set.name === "set onresourcetimingbufferfull";

    let listenerCalls = 0;
    const listener = () => listenerCalls++;
    performance.addEventListener("worker-performance-probe", listener);
    performance.dispatchEvent(new Event("worker-performance-probe"));
    performance.removeEventListener("worker-performance-probe", listener);
    performance.dispatchEvent(new Event("worker-performance-probe"));

    performance.clearResourceTimings();
    performance.setResourceTimingBufferSize(0);
    let observed = 0;
    let resolveObserved;
    const observedDone = new Promise((resolve) => {
      resolveObserved = resolve;
    });
    const observer = new PerformanceObserver((list) => {
      observed += list.getEntriesByType("resource").length;
      resolveObserved();
    });
    observer.observe({ type: "resource" });

    let eventCalls = 0;
    let eventTarget = false;
    let resolveEvent;
    const eventDone = new Promise((resolve) => {
      resolveEvent = resolve;
    });
    performance.onresourcetimingbufferfull = (event) => {
      eventCalls++;
      eventTarget = event.target === performance &&
        event.currentTarget === performance;
      resolveEvent();
    };

    const response = await fetch(message.data.url);
    await response.text();
    await Promise.all([observedDone, eventDone]);
    await new Promise((resolve) => setTimeout(resolve, 0));
    observer.disconnect();

    postMessage({
      ok: true,
      keys,
      isPerformance,
      isEventTarget,
      parentIsEventTarget,
      listenerRemoved: listenerCalls === 1,
      windowMembersAbsent,
      handlerDescriptor,
      observed,
      primary: performance.getEntriesByType("resource").length,
      eventCalls,
      eventTarget,
    });
  } catch (error) {
    postMessage({
      ok: false,
      error: String(error),
      stack: error && error.stack,
    });
  }
};
