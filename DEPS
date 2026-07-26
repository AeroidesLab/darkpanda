# Minimal Chromium M149 dependency graph owned by the DarkPanda browser
# repository. Component repositories do not select or override this profile.
#
# gclient paths are relative to the workspace containing the "browser"
# solution, therefore every dependency is rooted at browser/.

vars = {
  'skia_revision': '75c589e1f436688fca8f5b7f7a8affeafaa4f923',
  'gn_version': 'git_revision:1740f5c25bcac5a650ee3d1c1ec22bfa25fcd756',
  'ninja_version': 'version:3@1.12.1.chromium.4',
}

deps = {
  'browser/chromium-toolchain/skia':
    'https://skia.googlesource.com/skia.git@' + Var('skia_revision'),

  # Only the Chrome M149 sources referenced by the CPU-only Canvas Ninja graph
  # are synchronized. libpng and zlib are patched Chromium source subtrees,
  # materialized separately by tools/ci/materialize_skia_cpu_deps.py.
  'browser/chromium-toolchain/skia/third_party/externals/freetype':
    'https://chromium.googlesource.com/chromium/src/third_party/freetype2.git@b6bcd2177f72bb4842c7701d7b7f633bb3fc951a',
  'browser/chromium-toolchain/skia/third_party/externals/harfbuzz':
    'https://chromium.googlesource.com/external/github.com/harfbuzz/harfbuzz.git@e6741e2205309752839da60ff075b7fa2e7cddd3',
  'browser/chromium-toolchain/skia/third_party/externals/icu':
    'https://chromium.googlesource.com/chromium/deps/icu.git@3859e64eed5d34544b27fbcab0ac1685ce83df3c',
  'browser/chromium-toolchain/skia/third_party/externals/libjpeg-turbo':
    'https://chromium.googlesource.com/chromium/deps/libjpeg_turbo.git@d1f5f2393e0d51f840207342ae86e55a86443288',
  'browser/chromium-toolchain/skia/third_party/externals/libwebp':
    'https://chromium.googlesource.com/webm/libwebp.git@c00d83f6642e7838a12bb03bca94237f03cc2e00',
  'browser/chromium-toolchain/skia/third_party/externals/wuffs':
    'https://skia.googlesource.com/external/github.com/google/wuffs-mirror-release-c.git@50869df0ea703b4f41b238bfe26aec6ec9c86889',

  'browser/chromium-toolchain/llvm': {
    'dep_type': 'gcs',
    'bucket': 'chromium-browser-clang',
    'objects': [
      {
        'object_name': 'Linux_x64/clang-llvmorg-23-init-10931-g20b6ec66-8.tar.xz',
        'sha256sum': '6aa45b7398e915919ce07a5e1e15e8710327957f61c1d97d18e77e5f167e9d14',
        'size_bytes': 69605340,
        'generation': 1777639339258203,
        'condition': 'host_os == "linux"',
      },
      {
        'object_name': 'Linux_x64/llvmobjdump-llvmorg-23-init-10931-g20b6ec66-8.tar.xz',
        'sha256sum': 'f3701a93e5ad4eae4d3aa0c853dd71a4e776d8f9cec5db3e0c800e1843d5a9a4',
        'size_bytes': 5793432,
        'generation': 1777639339446398,
        'condition': 'host_os == "linux"',
      },
      {
        'object_name': 'Mac/clang-llvmorg-23-init-10931-g20b6ec66-8.tar.xz',
        'sha256sum': 'd25493bb0c74e7aad55135b0aceed9dcca22d6477043cb005aa3ccce7d708b83',
        'size_bytes': 55341104,
        'generation': 1777639341141424,
        'condition': 'host_os == "mac" and host_cpu == "x64"',
      },
      {
        'object_name': 'Mac/llvmobjdump-llvmorg-23-init-10931-g20b6ec66-8.tar.xz',
        'sha256sum': '98ac084036e387b7da7729fdb4f0dde9724897b52642f2b1f20782968765c24f',
        'size_bytes': 5722328,
        'generation': 1777639341526564,
        'condition': 'host_os == "mac" and host_cpu == "x64"',
      },
      {
        'object_name': 'Mac_arm64/clang-llvmorg-23-init-10931-g20b6ec66-8.tar.xz',
        'sha256sum': 'f6fd465945dae58eff22819cdc62ccae2271dd3cf624a2fa68d87f634f32dcb7',
        'size_bytes': 46106304,
        'generation': 1777639351295488,
        'condition': 'host_os == "mac" and host_cpu == "arm64"',
      },
      {
        'object_name': 'Mac_arm64/llvmobjdump-llvmorg-23-init-10931-g20b6ec66-8.tar.xz',
        'sha256sum': 'd1e42c8009c5983bbb37867bba8522db876bd32bb76c6e5560bf5134a02f7aaf',
        'size_bytes': 5444568,
        'generation': 1777639351710887,
        'condition': 'host_os == "mac" and host_cpu == "arm64"',
      },
      {
        'object_name': 'Win/clang-llvmorg-23-init-10931-g20b6ec66-8.tar.xz',
        'sha256sum': '7fa1aa9bf477f565687a2f516bf75ff6bfdd13da9b36bf521a75ac8ae2761d6a',
        'size_bytes': 50211688,
        'generation': 1777639362668478,
        'condition': 'host_os == "win"',
      },
      {
        'object_name': 'Win/llvmobjdump-llvmorg-23-init-10931-g20b6ec66-8.tar.xz',
        'sha256sum': '9f3bf71579786784762963c50cdc908ad07213a8b8c7f81edca209c095b130a9',
        'size_bytes': 5868192,
        'generation': 1777639362899299,
        'condition': 'host_os == "win"',
      },
    ],
  },

  'browser/chromium-toolchain/rust': {
    'dep_type': 'gcs',
    'bucket': 'chromium-browser-clang',
    'objects': [
      {
        'object_name': 'Linux_x64/rust-toolchain-4c4205163abcbd08948b3efab796c543ba1ea687-2-llvmorg-23-init-10931-g20b6ec66.tar.xz',
        'sha256sum': 'a96863c5b811af23cbe3f20fcfc82939e637be2bd79f05a117f1762c3bb35fe5',
        'size_bytes': 274625900,
        'generation': 1776704596417466,
        'condition': 'host_os == "linux"',
      },
      {
        'object_name': 'Mac/rust-toolchain-4c4205163abcbd08948b3efab796c543ba1ea687-2-llvmorg-23-init-10931-g20b6ec66.tar.xz',
        'sha256sum': 'cfb1cfa17fe96540ae732b2ed8cef39792786f7d84c317f3aca2004f2495c3fa',
        'size_bytes': 262623268,
        'generation': 1776704598519695,
        'condition': 'host_os == "mac" and host_cpu == "x64"',
      },
      {
        'object_name': 'Mac_arm64/rust-toolchain-4c4205163abcbd08948b3efab796c543ba1ea687-2-llvmorg-23-init-10931-g20b6ec66.tar.xz',
        'sha256sum': 'f7b34f50331e3d22b9b79b8217b3645dd67700ee801bec801da09bcffb583f9c',
        'size_bytes': 245410044,
        'generation': 1776704600641512,
        'condition': 'host_os == "mac" and host_cpu == "arm64"',
      },
      {
        'object_name': 'Win/rust-toolchain-4c4205163abcbd08948b3efab796c543ba1ea687-2-llvmorg-23-init-10931-g20b6ec66.tar.xz',
        'sha256sum': 'bd99ed04453ccef4916211c6db0a7afd1185b69371e1921ebd94f9bec78af73e',
        'size_bytes': 413531112,
        'generation': 1776704602737316,
        'condition': 'host_os == "win"',
      },
    ],
  },

  'browser/chromium-toolchain/buildtools': {
    'dep_type': 'cipd',
    'packages': [
      {
        'package': 'gn/gn/${{platform}}',
        'version': Var('gn_version'),
      },
      {
        'package': 'infra/3pp/tools/ninja/${{platform}}',
        'version': Var('ninja_version'),
      },
    ],
  },

  'browser/chromium-toolchain/sysroot': {
    'dep_type': 'gcs',
    'bucket': 'chrome-linux-sysroot',
    'condition': 'host_os == "linux" and host_cpu == "x64"',
    'objects': [
      {
        'object_name': '52d61d4446ffebfaa3dda2cd02da4ab4876ff237853f46d273e7f9b666652e1d',
        'sha256sum': '52d61d4446ffebfaa3dda2cd02da4ab4876ff237853f46d273e7f9b666652e1d',
        'size_bytes': 19727236,
        'generation': 1770327973518330,
      },
    ],
  },
}
