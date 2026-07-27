from __future__ import annotations

import io
from pathlib import Path
import tarfile
import tempfile
import unittest
import zipfile

from tools.ci import build_python_wheel as subject


class BuildPythonWheelTests(unittest.TestCase):
    def test_rejects_unsafe_archive_names(self) -> None:
        for name in ("../escape", "/absolute", r"C:\absolute", r"dir\file"):
            with self.subTest(name=name), self.assertRaises(ValueError):
                subject.safe_archive_name(name)

    def test_copies_the_exact_windows_runtime_closure(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / "runtime.zip"
            libraries = subject.TARGETS["windows-x86_64"]["libraries"]
            with zipfile.ZipFile(archive, "w") as bundle:
                for name in libraries:
                    bundle.writestr(f"darkpanda/bin/{name}", name.encode())
                bundle.writestr("darkpanda/bin/darkpanda.exe", b"cli")
            output = root / "native"

            copied = subject.copy_runtime_libraries(
                archive, "windows-x86_64", output
            )

            self.assertEqual(copied, libraries)
            self.assertEqual(
                sorted(path.name for path in output.iterdir()), sorted(libraries)
            )
            self.assertFalse((output / "darkpanda.exe").exists())

    def test_copies_the_exact_linux_runtime_closure(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / "runtime.tar.gz"
            libraries = subject.TARGETS["linux-x86_64"]["libraries"]
            with tarfile.open(archive, "w:gz") as bundle:
                for name in libraries:
                    payload = name.encode()
                    info = tarfile.TarInfo(f"darkpanda/bin/{name}")
                    info.size = len(payload)
                    bundle.addfile(info, io.BytesIO(payload))
            output = root / "native"

            copied = subject.copy_runtime_libraries(
                archive, "linux-x86_64", output
            )

            self.assertEqual(copied, libraries)
            self.assertEqual(
                sorted(path.name for path in output.iterdir()), sorted(libraries)
            )

    def test_wheel_must_contain_pyo3_and_all_native_libraries(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            wheel = Path(temporary) / "package.whl"
            libraries = ("darkpanda.dll", "wreq.dll")
            with zipfile.ZipFile(wheel, "w") as bundle:
                for name in (
                    "darkpanda/__init__.py",
                    "darkpanda/_api.py",
                    "darkpanda/_cdp.py",
                    "darkpanda/_native.pyi",
                    "darkpanda/py.typed",
                    "darkpanda/_native.cp310-win_amd64.pyd",
                    "darkpanda/_native_libs/darkpanda.dll",
                    "darkpanda/_native_libs/wreq.dll",
                ):
                    bundle.writestr(name, b"x")

            subject.validate_wheel(wheel, libraries)

            with zipfile.ZipFile(wheel, "a") as bundle:
                bundle.writestr("darkpanda/_native.py", b"legacy")
            with self.assertRaisesRegex(ValueError, "PyO3"):
                subject.validate_wheel(wheel, libraries)

    def test_windows_rust_build_uses_chromium_lld_link(self) -> None:
        root = Path("C:/chromium-toolchain")
        tools = {
            "cargo": root / "rust/bin/cargo.exe",
            "rustc": root / "rust/bin/rustc.exe",
            "cc": root / "llvm/bin/clang-cl.exe",
            "cxx": root / "llvm/bin/clang-cl.exe",
            "linker": root / "llvm/bin/lld-link.exe",
        }

        environment = subject.build_environment(
            tools, "windows-x86_64", Path("C:/cargo-target"), 4
        )

        self.assertEqual(
            environment["CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_LINKER"],
            str(tools["linker"]),
        )
        self.assertEqual(environment["RUSTC"], str(tools["rustc"]))

    def test_linux_rust_build_pins_chromium_clang_lld_and_sysroot(self) -> None:
        root = Path("/chromium-toolchain")
        tools = {
            "cargo": root / "rust/bin/cargo",
            "rustc": root / "rust/bin/rustc",
            "cc": root / "llvm/bin/clang",
            "cxx": root / "llvm/bin/clang++",
            "linker": root / "llvm/bin/ld.lld",
            "sysroot": root / "sysroot",
        }

        environment = subject.build_environment(
            tools, "linux-x86_64", Path("/cargo-target"), 2
        )

        self.assertEqual(
            environment["CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER"],
            str(tools["cc"]),
        )
        flags = environment["CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_RUSTFLAGS"]
        self.assertIn(f"--ld-path={tools['linker']}", flags)
        self.assertIn(f"--sysroot={tools['sysroot']}", flags)


if __name__ == "__main__":
    unittest.main()
