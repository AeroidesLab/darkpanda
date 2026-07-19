// Exposes WorkerNavigator (navigator) inside a WorkerGlobalScope.
// Replies with either { ok: true, results: {...} } or { ok: false, err }.
onmessage = async function(event) {
  try {
    const probeGetterOnlyAssignment = (target, prototype, property) => {
      const descriptor = Object.getOwnPropertyDescriptor(prototype, property);
      const beforeOwn = Object.prototype.hasOwnProperty.call(target, property);
      let strictError;
      try {
        (function(object, name) {
          'use strict';
          object[name] = 1;
        })(target, property);
      } catch (error) {
        strictError = { name: error.name, message: error.message };
      }

      const afterStrictOwn = Object.prototype.hasOwnProperty.call(
        target,
        property,
      );
      Function('object', 'name', 'object[name] = 1;')(target, property);
      const afterSloppyOwn = Object.prototype.hasOwnProperty.call(
        target,
        property,
      );
      const reflectResult = Reflect.set(target, property, 1);
      const afterReflectOwn = Object.prototype.hasOwnProperty.call(
        target,
        property,
      );

      return {
        descriptor: {
          get: typeof descriptor?.get,
          set: typeof descriptor?.set,
          enumerable: descriptor?.enumerable,
          configurable: descriptor?.configurable,
        },
        strictError,
        beforeOwn,
        afterStrictOwn,
        afterSloppyOwn,
        reflectResult,
        afterReflectOwn,
      };
    };

    const workerNavigatorPrototype = Object.getPrototypeOf(navigator);
    const userAgentDescriptor = Object.getOwnPropertyDescriptor(
      workerNavigatorPrototype,
      'userAgent',
    );
    let illegalInvocation;
    try {
      userAgentDescriptor.get.call({});
      illegalInvocation = null;
    } catch (error) {
      illegalInvocation = {
        name: error.name,
        message: error.message,
        ownKeys: Reflect.ownKeys(error).map(String),
      };
    }

    // Permissions (transitively reachable: navigator.permissions -> Permissions
    // -> PermissionStatus). Must not depend on a Frame.
    const status = await navigator.permissions.query({ name: 'geolocation' });

    // StorageManager (navigator.storage -> StorageManager -> StorageEstimate).
    const estimate = await navigator.storage.estimate();

    // NavigatorUAData (navigator.userAgentData -> getHighEntropyValues()).
    const ua = navigator.userAgentData;
    const high_entropy = ua ? await ua.getHighEntropyValues([
      'architecture', 'fullVersionList', 'uaFullVersion', 'formFactors',
    ]) : null;

    const capabilityNames = [
      'connection', 'hid', 'mediaCapabilities', 'serial', 'usb', 'locks',
      'gpu', 'storageBuckets',
    ];
    const describeCapability = (name) => {
      const value = navigator[name];
      const prototype = Object.getPrototypeOf(value);
      const descriptor = Object.getOwnPropertyDescriptor(
        workerNavigatorPrototype,
        name,
      );
      return {
        type: typeof value,
        tag: Object.prototype.toString.call(value),
        constructor: value.constructor?.name,
        stable: value === navigator[name],
        ownKeys: Reflect.ownKeys(value).map(String),
        prototypeKeys: Reflect.ownKeys(prototype).map(String),
        prototypeParent: Object.getPrototypeOf(prototype)?.constructor?.name,
        descriptor: {
          get: typeof descriptor?.get,
          set: typeof descriptor?.set,
          enumerable: descriptor?.enumerable,
          configurable: descriptor?.configurable,
          getterName: descriptor?.get?.name,
          getterLength: descriptor?.get?.length,
        },
      };
    };
    const capabilities = Object.fromEntries(
      capabilityNames.map((name) => [name, describeCapability(name)]),
    );
    const [hidDevices, serialPorts, usbDevices, lockSnapshot, bucketKeys] =
      await Promise.all([
        navigator.hid.getDevices(),
        navigator.serial.getPorts(),
        navigator.usb.getDevices(),
        navigator.locks.query(),
        navigator.storageBuckets.keys(),
      ]);
    const changeHandler = () => {};
    navigator.connection.onchange = changeHandler;

    const results = {
      has_navigator: typeof navigator !== 'undefined',
      worker_navigator_type: typeof WorkerNavigator,
      window_navigator_type: typeof Navigator,
      worker_navigator_tag: Object.prototype.toString.call(navigator),
      worker_navigator_constructor: navigator.constructor?.name,
      worker_navigator_instance:
        typeof WorkerNavigator === 'function' && navigator instanceof WorkerNavigator,
      worker_navigator_prototype_keys:
        Reflect.ownKeys(workerNavigatorPrototype).map(String),
      user_agent_descriptor: {
        get: typeof userAgentDescriptor?.get,
        set: typeof userAgentDescriptor?.set,
        enumerable: userAgentDescriptor?.enumerable,
        configurable: userAgentDescriptor?.configurable,
        getter_name: userAgentDescriptor?.get?.name,
        getter_length: userAgentDescriptor?.get?.length,
      },
      user_agent_illegal_invocation: illegalInvocation,
      getter_only_worker_navigator: probeGetterOnlyAssignment(
        navigator,
        WorkerNavigator.prototype,
        'userAgent',
      ),
      getter_only_worker_location: probeGetterOnlyAssignment(
        location,
        WorkerLocation.prototype,
        'href',
      ),
      getter_only_worker_global: probeGetterOnlyAssignment(
        self,
        WorkerGlobalScope.prototype,
        'navigator',
      ),
      // userAgent must match the value the page sees (passed in via postMessage).
      user_agent: navigator.userAgent,
      user_agent_matches_page: navigator.userAgent === event.data.pageUserAgent,
      app_name: navigator.appName,
      app_version: navigator.appVersion,
      platform: navigator.platform,
      language: navigator.language,
      languages: navigator.languages,
      hardware_concurrency: navigator.hardwareConcurrency,
      device_memory: navigator.deviceMemory,
      max_touch_points: navigator.maxTouchPoints,
      vendor: navigator.vendor,
      product: navigator.product,
      on_line: navigator.onLine,
      // SameObject: navigator should be stable across reads.
      identity_stable: navigator === navigator,
      instance_keys: Reflect.ownKeys(navigator),

      capabilities,
      capability_constructor_types: Object.fromEntries([
        'NetworkInformation', 'HID', 'MediaCapabilities', 'Serial', 'USB',
        'LockManager', 'GPU', 'StorageBucketManager',
      ].map((name) => [name, typeof globalThis[name]])),
      capability_results: {
        connection: {
          effectiveType: navigator.connection.effectiveType,
          rtt: navigator.connection.rtt,
          downlink: navigator.connection.downlink,
          saveData: navigator.connection.saveData,
          handlerStable: navigator.connection.onchange === changeHandler,
          eventTarget: navigator.connection instanceof EventTarget,
        },
        hidDevices,
        serialPorts,
        usbDevices,
        lockSnapshot,
        bucketKeys,
        preferredCanvasFormat: navigator.gpu.getPreferredCanvasFormat(),
        gpuAdapter: await navigator.gpu.requestAdapter(),
        wgslFeaturesStable:
          navigator.gpu.wgslLanguageFeatures ===
          navigator.gpu.wgslLanguageFeatures,
      },

      // Permissions
      permission_name: status.name,
      permission_state: status.state,

      // StorageManager
      storage_quota: estimate.quota,
      storage_usage: estimate.usage,

      // NavigatorUAData
      has_ua_data: ua != null,
      ua_brands: ua ? ua.brands : null,
      ua_mobile: ua ? ua.mobile : null,
      ua_platform: ua ? ua.platform : null,
      ua_high_entropy_arch: high_entropy ? high_entropy.architecture : null,
      ua_full_version: high_entropy ? high_entropy.uaFullVersion : null,
      ua_full_version_list: high_entropy ? high_entropy.fullVersionList : null,
      ua_form_factors: high_entropy ? high_entropy.formFactors : null,

      // [Exposed=Window] members must NOT leak into the worker realm.
      no_plugins: navigator.plugins === undefined,
      no_register_protocol_handler: navigator.registerProtocolHandler === undefined,
      no_model_context: navigator.modelContext === undefined,
      no_vendor: navigator.vendor === undefined,
      no_vendor_sub: navigator.vendorSub === undefined,
      no_product_sub: navigator.productSub === undefined,
      no_max_touch_points: navigator.maxTouchPoints === undefined,
      no_cookie_enabled: navigator.cookieEnabled === undefined,
      no_webdriver: navigator.webdriver === undefined,
      no_java_enabled: navigator.javaEnabled === undefined,
    };
    postMessage({ ok: true, results });
  } catch (e) {
    postMessage({ ok: false, err: e.message });
  }
};
