// Copyright (C) 2026 Lightpanda
//
// Chromium-compatible WebAssembly.compileStreaming/instantiateStreaming
// embedder bridge. V8 resolves Response promises before invoking this callback;
// this module validates and consumes the resolved Response without any
// site-specific behavior.

const js = @import("js.zig");
const Context = @import("Context.zig");
const TaggedOpaque = @import("TaggedOpaque.zig");

const Response = @import("../webapi/net/Response.zig");
const ReadableStream = @import("../webapi/streams/ReadableStream.zig");
const ReadableStreamDefaultReader = @import("../webapi/streams/ReadableStreamDefaultReader.zig");

const v8 = js.v8;

pub fn callback(
    isolate_handle_: ?*v8.Isolate,
    context_handle_: ?*const v8.Context,
    response_handle_: ?*const v8.Value,
    streaming_: ?*v8.WasmStreaming,
) callconv(.c) void {
    const streaming = streaming_ orelse return;
    const isolate_handle = isolate_handle_ orelse {
        v8.v8__WasmStreaming__Abort(streaming, null);
        return;
    };
    const context_handle = context_handle_ orelse {
        v8.v8__WasmStreaming__Abort(streaming, null);
        return;
    };
    const ctx = Context.fromC(context_handle) orelse {
        // Mirrors Blink: a detached/invalid execution context silently aborts
        // instead of trying to reject a promise in a dead realm.
        v8.v8__WasmStreaming__Abort(streaming, null);
        return;
    };

    var hs: js.HandleScope = undefined;
    hs.initWithIsolateHandle(isolate_handle);
    defer hs.deinit();

    var caller: js.Caller = undefined;
    caller.initWithContext(ctx, context_handle);
    defer caller.deinit();

    const local = &caller.local;
    const response_handle = response_handle_ orelse {
        return abortTypeError(local, streaming, "An argument must be provided, which must be a Response or Promise<Response> object");
    };
    const response_value = js.Value{ .local = local, .handle = response_handle };
    if (!response_value.isObject()) {
        return abortTypeError(local, streaming, "An argument must be provided, which must be a Response or Promise<Response> object");
    }

    const response = TaggedOpaque.fromJS(*Response, @ptrCast(response_handle)) catch {
        return abortTypeError(local, streaming, "An argument must be provided, which must be a Response or Promise<Response> object");
    };

    const body = response.beginWasmStreaming(&ctx.execution) catch |err| switch (err) {
        error.HttpStatusNotOk => return abortTypeError(local, streaming, "HTTP status code is not ok"),
        error.IncorrectMimeType => return abortTypeError(local, streaming, "Incorrect response MIME type. Expected 'application/wasm'."),
        error.BodyUnavailable => return abortTypeError(local, streaming, "Cannot compile WebAssembly.Module from an already read Response"),
        error.EmptyBody => return abortCompileError(local, streaming, "Empty WebAssembly module"),
        error.OutOfMemory => return abortTypeError(local, streaming, "WebAssembly compilation aborted: Out of memory"),
    };

    const url = response.getURL();
    v8.v8__WasmStreaming__SetUrl(streaming, url.ptr, url.len);

    switch (body) {
        .bytes => |bytes| {
            if (bytes.len != 0) {
                v8.v8__WasmStreaming__OnBytesReceived(streaming, bytes.ptr, bytes.len);
            }
            v8.v8__WasmStreaming__Finish(streaming);
        },
        .stream => |stream| StreamConsumer.start(streaming, stream, response, ctx) catch {
            abortTypeError(local, streaming, "WebAssembly compilation aborted: Failed to read Response body");
        },
    }
}

const validation_prefix = "Failed to execute 'compile' on 'WebAssembly': ";

fn abortTypeError(local: *const js.Local, streaming: *v8.WasmStreaming, comptime message: []const u8) void {
    v8.v8__WasmStreaming__Abort(streaming, local.isolate.createTypeError(validation_prefix ++ message));
}

fn abortCompileError(local: *const js.Local, streaming: *v8.WasmStreaming, comptime message: []const u8) void {
    v8.v8__WasmStreaming__Abort(streaming, local.isolate.createWasmCompileError(validation_prefix ++ message));
}

const StreamConsumer = struct {
    context: *Context,
    execution: *const js.Execution,
    response: *Response,
    reader: *ReadableStreamDefaultReader,
    streaming: ?*v8.WasmStreaming,

    fn start(
        streaming: *v8.WasmStreaming,
        stream: *ReadableStream,
        response: *Response,
        context: *Context,
    ) !void {
        const execution = &context.execution;
        const reader = try stream.getReader(execution);
        errdefer reader.releaseLock();

        const self = try execution.arena.create(StreamConsumer);
        self.* = .{
            .context = context,
            .execution = execution,
            .response = response,
            .reader = reader,
            .streaming = streaming,
        };

        response.acquireRef();
        errdefer response.releaseRef(execution.page);

        try context.registerPendingEmbedderOperation(.{
            .data = self,
            .cancel = cancelFromContext,
        });
        errdefer context.unregisterPendingEmbedderOperation(self);

        try self.pumpRead();
    }

    fn pumpRead(self: *StreamConsumer) !void {
        if (self.streaming == null) return;
        const local = self.execution.js.local.?;
        const read_promise = try self.reader.read(self.execution);
        const on_fulfilled = local.newCallback(onReadFulfilled, self);
        const on_rejected = local.newCallback(onReadRejected, self);
        _ = try read_promise.thenAndCatch(on_fulfilled, on_rejected);
    }

    const ReadData = struct {
        done: bool,
        value: js.Value,
    };

    fn onReadFulfilled(self: *StreamConsumer, data_: ?ReadData) void {
        const data = data_ orelse {
            self.abortWithTypeError("WebAssembly compilation aborted: Invalid Response body stream");
            return;
        };
        if (data.done) {
            self.finish();
            return;
        }

        const value = data.value;
        if (!(value.isTypedArray() or value.isArrayBufferView() or value.isArrayBuffer())) {
            self.abortWithTypeError("WebAssembly compilation aborted: Response body stream chunk is not a BufferSource");
            return;
        }

        const bytes = self.execution.js.local.?.jsValueToZig([]u8, value) catch {
            self.abortWithTypeError("WebAssembly compilation aborted: Invalid Response body stream chunk");
            return;
        };
        if (bytes.len != 0) {
            v8.v8__WasmStreaming__OnBytesReceived(self.streaming.?, bytes.ptr, bytes.len);
        }
        self.pumpRead() catch {
            self.abortWithTypeError("WebAssembly compilation aborted: Failed to read Response body");
        };
    }

    fn onReadRejected(self: *StreamConsumer) void {
        self.abortWithTypeError("WebAssembly compilation aborted: Network error");
    }

    fn finish(self: *StreamConsumer) void {
        const streaming = self.takeStreaming(true) orelse return;
        v8.v8__WasmStreaming__Finish(streaming);
    }

    fn abortWithTypeError(self: *StreamConsumer, message: []const u8) void {
        const streaming = self.takeStreaming(true) orelse return;
        const local = self.execution.js.local.?;
        v8.v8__WasmStreaming__Abort(streaming, local.isolate.createTypeError(message));
    }

    fn cancelFromContext(data: *anyopaque) void {
        const self: *StreamConsumer = @ptrCast(@alignCast(data));
        const streaming = self.takeStreaming(false) orelse return;
        // The realm is being destroyed. As in Blink's invalid-context path,
        // abort without a reason so V8 does not reject into a dead context.
        v8.v8__WasmStreaming__Abort(streaming, null);
    }

    fn takeStreaming(self: *StreamConsumer, unregister: bool) ?*v8.WasmStreaming {
        const streaming = self.streaming orelse return null;
        self.streaming = null;
        if (unregister) self.context.unregisterPendingEmbedderOperation(self);
        self.reader.releaseLock();
        self.response.releaseRef(self.execution.page);
        return streaming;
    }
};
