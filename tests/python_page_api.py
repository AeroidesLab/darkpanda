"""Pure-Python contract test for Page.frames/Page.click marshaling."""

from __future__ import annotations

import ctypes
import json

from darkpanda import Page
from darkpanda._native import _Bytes, _ClickOptions, _Error


class FakeDLL:
    def __init__(self) -> None:
        self._buffers: list[object] = []
        self.click: dict[str, object] | None = None

    def dp_page_frames(self, handle: object, output_pointer: object, error_pointer: object) -> int:
        del handle, error_pointer
        payload = json.dumps([
            {
                "frameId": 1,
                "parentFrameId": None,
                "url": "http://fixture/",
                "name": "",
                "isRoot": True,
                "attached": True,
                "visible": True,
                "ownerRect": None,
                "childCount": 2,
            },
            {
                "frameId": 2,
                "parentFrameId": 1,
                "url": "http://fixture/hidden",
                "name": "retry",
                "isRoot": False,
                "attached": True,
                "visible": False,
                "ownerRect": {"x": 0, "y": 0, "width": 0, "height": 0},
                "childCount": 0,
            },
            {
                "frameId": 3,
                "parentFrameId": 1,
                "url": "http://fixture/visible",
                "name": "challenge",
                "isRoot": False,
                "attached": True,
                "visible": True,
                "ownerRect": {"x": 8, "y": 9, "width": 300, "height": 65},
                "childCount": 0,
            },
        ], separators=(",", ":")).encode()
        storage = (ctypes.c_uint8 * len(payload)).from_buffer_copy(payload)
        self._buffers.append(storage)
        output = ctypes.cast(output_pointer, ctypes.POINTER(_Bytes)).contents
        output.ptr = ctypes.cast(storage, ctypes.POINTER(ctypes.c_uint8))
        output.len = len(payload)
        return 0

    def dp_bytes_free(self, output_pointer: object) -> None:
        output = ctypes.cast(output_pointer, ctypes.POINTER(_Bytes)).contents
        output.ptr = ctypes.POINTER(ctypes.c_uint8)()
        output.len = 0

    def dp_click_options_init(self, options_pointer: object) -> None:
        options = ctypes.cast(options_pointer, ctypes.POINTER(_ClickOptions)).contents
        options.abi_version = 1
        options.struct_size = ctypes.sizeof(_ClickOptions)
        options.move_delay_ms = 16
        options.press_delay_ms = 60

    def dp_page_click(
        self,
        handle: object,
        selector: object,
        options_pointer: object,
        error_pointer: object,
    ) -> int:
        del handle, error_pointer
        options = ctypes.cast(options_pointer, ctypes.POINTER(_ClickOptions)).contents
        self.click = {
            "selector": ctypes.string_at(selector.ptr, selector.len).decode(),
            "frame_id": options.frame_id,
            "timeout_ms": options.timeout_ms,
            "pierce": bool(options.pierce_shadow),
            "move_delay_ms": options.move_delay_ms,
            "press_delay_ms": options.press_delay_ms,
        }
        return 0


class FakeLibrary:
    def __init__(self) -> None:
        self.dll = FakeDLL()

    def checked(self, status: int, error: _Error) -> None:
        del error
        assert status == 0


class FakeRuntime:
    def __init__(self) -> None:
        self.closed = False
        self._library = FakeLibrary()


def main() -> None:
    runtime = FakeRuntime()
    page = Page.__new__(Page)
    page._runtime = runtime
    page._handle = ctypes.c_uint64(7)

    frames = page.frames(attached=True)
    assert len(frames) == 3
    visible_children = [frame for frame in page.frames(visible=True) if not frame.is_root]
    assert len(visible_children) == 1
    frame = visible_children[0]
    assert frame.frame_id == frame.id == 3
    assert frame.parent_frame_id == frame.parent_id == 1
    assert frame.visible == frame.is_visible
    assert frame.owner_rect is not None
    assert (frame.owner_rect.width, frame.owner_rect.height) == (300, 65)

    try:
        page.frames(visible=1)  # type: ignore[arg-type]
    except TypeError as error:
        assert "visible" in str(error)
    else:
        raise AssertionError("non-bool visible filter was accepted")

    page.click("#secret", 3, True, 4_000, 17, 61)
    assert runtime._library.dll.click == {
        "selector": "#secret",
        "frame_id": 3,
        "timeout_ms": 4_000,
        "pierce": True,
        "move_delay_ms": 17,
        "press_delay_ms": 61,
    }

    try:
        page.click("#secret", move_delay_ms=60_001)
    except ValueError as error:
        assert "60000" in str(error)
    else:
        raise AssertionError("oversized phase delay was accepted")

    print("python Page API: PASS")


if __name__ == "__main__":
    main()
