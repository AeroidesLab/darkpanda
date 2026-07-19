(async () => {
  const high = await navigator.userAgentData.getHighEntropyValues([
    'architecture', 'bitness', 'platformVersion', 'uaFullVersion',
    'fullVersionList', 'wow64', 'formFactors',
  ]);
  postMessage({
    userAgent: navigator.userAgent,
    appVersion: navigator.appVersion,
    platform: navigator.platform,
    language: navigator.language,
    languages: navigator.languages,
    deviceMemory: navigator.deviceMemory,
    hardwareConcurrency: navigator.hardwareConcurrency,
    maxTouchPoints: navigator.maxTouchPoints,
    brands: navigator.userAgentData.brands,
    mobile: navigator.userAgentData.mobile,
    uaPlatform: navigator.userAgentData.platform,
    high,
    ownKeys: Reflect.ownKeys(navigator),
  });
})().catch((error) => postMessage({ error: String(error && error.stack || error) }));
