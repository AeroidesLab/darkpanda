#![deny(unsafe_op_in_unsafe_fn)]

use futures_util::{FutureExt, StreamExt};
use hickory_resolver::{
    config::{ConnectionConfig, LookupIpStrategy, NameServerConfig, ResolverConfig},
    net::runtime::TokioRuntimeProvider,
    TokioResolver,
};
use std::any::Any;
#[cfg(windows)]
use std::collections::BTreeSet;
use std::collections::HashMap;
use std::ffi::c_char;
use std::future;
use std::mem::{align_of, size_of};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;
use std::slice;
use std::str;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicU8, Ordering};
use std::sync::mpsc::{self, RecvTimeoutError, TryRecvError};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;
use tokio::runtime::Runtime;
use tokio::sync::{mpsc as tokio_mpsc, oneshot, OwnedSemaphorePermit, Semaphore};
use tokio_util::sync::CancellationToken;
use wreq::dns::{Addrs, GaiResolver, Name, Resolve, Resolving};
use wreq::header::{HeaderMap, HeaderName, HeaderValue, OrigHeaderMap};
use wreq::{IntoEmulation, Method, Uri, Version};
use wreq_util::{Emulation, Platform, Profile};

#[cfg(windows)]
use schannel::cert_context::ValidUses;
#[cfg(windows)]
use schannel::cert_store::CertStore as WindowsCertStore;

pub const WREQ_TRANSPORT_OK: i32 = 0;
pub const WREQ_TRANSPORT_EMPTY: i32 = 1;
pub const WREQ_TRANSPORT_INVALID_ARGUMENT: i32 = -1;
pub const WREQ_TRANSPORT_NOT_FOUND: i32 = -2;
pub const WREQ_TRANSPORT_INVALID_STATE: i32 = -3;
pub const WREQ_TRANSPORT_SHUTTING_DOWN: i32 = -4;
pub const WREQ_TRANSPORT_INTERNAL_ERROR: i32 = -5;
pub const WREQ_TRANSPORT_PANIC: i32 = -6;
pub const WREQ_TRANSPORT_OVERFLOW: i32 = -7;
pub const WREQ_TRANSPORT_OUT_OF_MEMORY: i32 = -8;

pub const WREQ_EVENT_HEADERS: u32 = 1;
pub const WREQ_EVENT_DATA: u32 = 2;
pub const WREQ_EVENT_DONE: u32 = 3;
pub const WREQ_EVENT_ERROR: u32 = 4;
pub const WREQ_EVENT_CANCELLED: u32 = 5;
pub const WREQ_EVENT_WEBSOCKET_OPEN: u32 = 6;
pub const WREQ_EVENT_WEBSOCKET_TEXT: u32 = 7;
pub const WREQ_EVENT_WEBSOCKET_BINARY: u32 = 8;
pub const WREQ_EVENT_WEBSOCKET_CLOSE: u32 = 9;

pub const WREQ_WEBSOCKET_SEND_TEXT: u32 = 1;
pub const WREQ_WEBSOCKET_SEND_BINARY: u32 = 2;
pub const WREQ_WEBSOCKET_SEND_CLOSE: u32 = 3;

pub const WREQ_TRANSPORT_ABI_VERSION: u32 = 5;
pub const WREQ_TRANSPORT_DEFAULT_EVENT_CAPACITY: u32 = 256;
pub const WREQ_TRANSPORT_MAX_EVENT_CAPACITY: u32 = 65_536;
pub const WREQ_TRANSPORT_OPTION_INSECURE_SKIP_TLS_VERIFY: u64 = 1 << 0;
pub const WREQ_TRANSPORT_OPTION_CUSTOM_DNS: u64 = 1 << 1;
pub const WREQ_REQUEST_OPTION_CONFIG_OVERRIDE: u64 = 1 << 0;
pub const WREQ_REQUEST_OPTION_INSECURE_SKIP_TLS_VERIFY: u64 = 1 << 1;
pub const WREQ_REQUEST_OPTION_FOLLOW_REDIRECTS: u64 = 1 << 2;
pub const WREQ_TRANSPORT_PROFILE_DEFAULT: u32 = 0;
pub const WREQ_TRANSPORT_PROFILE_CHROME_124: u32 = 124;
pub const WREQ_TRANSPORT_PROFILE_CHROME_149: u32 = 149;
const VERSION_STRING: &[u8] =
    b"libwreq/0.4.0 abi/5 wreq/6.0.0-rc.29 wreq-util/3.0.0-rc.14 ws\0";

const STATE_QUEUED: u8 = 0;
const STATE_RUNNING: u8 = 1;
const STATE_AWAITING_HEADERS_ACK: u8 = 2;
const STATE_STREAMING: u8 = 3;
const STATE_TERMINAL: u8 = 4;

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct WreqSlice {
    pub ptr: *const u8,
    pub len: usize,
}

impl WreqSlice {
    const fn empty() -> Self {
        Self {
            ptr: ptr::null(),
            len: 0,
        }
    }
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct WreqHeader {
    pub name: WreqSlice,
    pub value: WreqSlice,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct WreqTransportOptions {
    pub struct_size: u32,
    pub abi_version: u32,
    pub flags: u64,
    pub proxy_url: WreqSlice,
    pub event_capacity: u32,
    pub profile_id: u32,
    pub reserved32: u32,
    pub dns_nameservers: WreqSlice,
}

/// Read only this fixed header before trusting `struct_size` enough to copy
/// the complete versioned options structure.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
struct WreqTransportOptionsHeader {
    struct_size: u32,
    abi_version: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct WreqRequest {
    pub struct_size: u32,
    pub abi_version: u32,
    pub method: WreqSlice,
    pub url: WreqSlice,
    pub headers: *const WreqHeader,
    pub header_count: usize,
    pub body: WreqSlice,
    pub timeout_ms: u64,
    pub flags: u64,
    pub proxy_url: WreqSlice,
}

#[repr(C)]
#[derive(Debug)]
pub struct WreqEvent {
    pub kind: u32,
    pub http_version: u32,
    pub request_id: u64,
    pub status_code: u16,
    pub reserved16: u16,
    pub reserved32: u32,
    pub encoded_body_size: u64,
    pub decoded_body_size: u64,
    pub headers: *const WreqHeader,
    pub header_count: usize,
    pub data: WreqSlice,
}

struct OwnedRequestHeader {
    original_name: String,
    name: HeaderName,
    value: HeaderValue,
}

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
struct ClientKey {
    verify_tls: bool,
    proxy_url: Option<String>,
}

/// Browser host resolution treats `localhost` and every subdomain of it as
/// loopback without consulting external DNS.
#[derive(Clone)]
struct LocalhostResolver {
    inner: Arc<dyn Resolve>,
}

/// Explicit upstream DNS with one resolver instance shared by every wreq
/// client owned by a transport. Cloning TokioResolver retains its response
/// cache instead of creating one cache per TLS/proxy client key.
#[derive(Clone)]
struct CustomDnsResolver {
    inner: TokioResolver,
}

impl CustomDnsResolver {
    fn new(nameservers: &[SocketAddr]) -> Result<Self, i32> {
        let name_servers = nameservers
            .iter()
            .map(|address| {
                let mut udp = ConnectionConfig::udp();
                udp.port = address.port();
                let mut tcp = ConnectionConfig::tcp();
                tcp.port = address.port();
                NameServerConfig::new(address.ip(), true, vec![udp, tcp])
            })
            .collect();
        let config = ResolverConfig::from_parts(None, Vec::new(), name_servers);
        let mut builder =
            TokioResolver::builder_with_config(config, TokioRuntimeProvider::default());
        builder.options_mut().ip_strategy = LookupIpStrategy::Ipv4AndIpv6;
        #[cfg(windows)]
        {
            // Let Winsock select the ephemeral UDP source port. Hickory's
            // explicit selection can trigger a Windows firewall prompt.
            builder.options_mut().os_port_selection = true;
        }
        let inner = builder.build().map_err(|_| WREQ_TRANSPORT_INTERNAL_ERROR)?;
        Ok(Self { inner })
    }
}

fn is_localhost_name(name: &str) -> bool {
    let bytes = name.as_bytes();
    let end = bytes
        .iter()
        .rposition(|byte| *byte != b'.')
        .map_or(0, |index| index + 1);
    let host = &bytes[..end];
    host.eq_ignore_ascii_case(b"localhost")
        || (host.len() > b".localhost".len()
            && host[host.len() - b".localhost".len()..].eq_ignore_ascii_case(b".localhost"))
}

impl Resolve for LocalhostResolver {
    fn resolve(&self, name: Name) -> Resolving {
        if !is_localhost_name(name.as_str()) {
            return self.inner.resolve(name);
        }
        let addresses = [
            SocketAddr::from((Ipv6Addr::LOCALHOST, 0)),
            SocketAddr::from((Ipv4Addr::LOCALHOST, 0)),
        ];
        Box::pin(future::ready(Ok(Box::new(addresses.into_iter()) as Addrs)))
    }
}

impl Resolve for CustomDnsResolver {
    fn resolve(&self, name: Name) -> Resolving {
        let resolver = self.inner.clone();
        Box::pin(async move {
            let lookup = resolver.lookup_ip(name.as_str()).await?;
            let addresses = lookup
                .iter()
                .map(|address| SocketAddr::new(address, 0))
                .collect::<Vec<_>>();
            Ok(Box::new(addresses.into_iter()) as Addrs)
        })
    }
}

struct OwnedRequest {
    method: Method,
    uri: Uri,
    headers: Vec<OwnedRequestHeader>,
    body: Vec<u8>,
    timeout: Option<Duration>,
    follow_redirects: bool,
    client_override: Option<ClientKey>,
}

struct OwnedHeaderBytes {
    name: Box<[u8]>,
    value: Box<[u8]>,
}

struct InternalEvent {
    kind: u32,
    http_version: u32,
    request_id: u64,
    status_code: u16,
    encoded_body_size: u64,
    decoded_body_size: u64,
    headers: Vec<OwnedHeaderBytes>,
    data: Vec<u8>,
}

struct QueuedEvent {
    event: InternalEvent,
    permit: OwnedSemaphorePermit,
}

enum QueueMessage {
    Event(QueuedEvent),
    Wake,
}

impl InternalEvent {
    fn terminal(kind: u32, request_id: u64, data: Vec<u8>) -> Self {
        Self {
            kind,
            http_version: 0,
            request_id,
            status_code: 0,
            encoded_body_size: 0,
            decoded_body_size: 0,
            headers: Vec::new(),
            data,
        }
    }

    fn terminal_with_body_sizes(
        kind: u32,
        request_id: u64,
        encoded_body_size: u64,
        decoded_body_size: u64,
    ) -> Self {
        Self {
            kind,
            http_version: 0,
            request_id,
            status_code: 0,
            encoded_body_size,
            decoded_body_size,
            headers: Vec::new(),
            data: Vec::new(),
        }
    }
}

struct RequestControl {
    cancel: CancellationToken,
    headers_ack: Mutex<Option<oneshot::Sender<()>>>,
    websocket_commands: Mutex<Option<tokio_mpsc::Sender<WebSocketCommand>>>,
    state: AtomicU8,
}

impl RequestControl {
    fn new() -> Self {
        Self {
            cancel: CancellationToken::new(),
            headers_ack: Mutex::new(None),
            websocket_commands: Mutex::new(None),
            state: AtomicU8::new(STATE_QUEUED),
        }
    }
}

enum WebSocketCommand {
    Text(String),
    Binary(Vec<u8>),
    Close { code: u16, reason: String },
}

type ControlTable = Arc<Mutex<HashMap<u64, Arc<RequestControl>>>>;

#[derive(Clone)]
struct TaskContext {
    request_id: u64,
    control: Arc<RequestControl>,
    controls: ControlTable,
    events: mpsc::Sender<QueueMessage>,
    event_slots: Arc<Semaphore>,
}

impl TaskContext {
    async fn emit(&self, event: InternalEvent) -> bool {
        let permit = match Arc::clone(&self.event_slots).acquire_owned().await {
            Ok(permit) => permit,
            Err(_) => return false,
        };
        self.events
            .send(QueueMessage::Event(QueuedEvent { event, permit }))
            .is_ok()
    }

    async fn finish(&self, kind: u32, data: Vec<u8>) {
        self.finish_event(InternalEvent::terminal(kind, self.request_id, data))
            .await;
    }

    async fn finish_event(&self, event: InternalEvent) {
        if self.control.state.swap(STATE_TERMINAL, Ordering::AcqRel) == STATE_TERMINAL {
            return;
        }

        lock_unpoisoned(&self.control.headers_ack).take();
        lock_unpoisoned(&self.control.websocket_commands).take();
        self.remove_from_table();
        let _ = self.emit(event).await;
    }

    fn retire_without_event(&self) {
        if self.control.state.swap(STATE_TERMINAL, Ordering::AcqRel) != STATE_TERMINAL {
            lock_unpoisoned(&self.control.headers_ack).take();
            lock_unpoisoned(&self.control.websocket_commands).take();
            self.remove_from_table();
        }
    }

    fn remove_from_table(&self) {
        let mut controls = lock_unpoisoned(&self.controls);
        let should_remove = controls
            .get(&self.request_id)
            .is_some_and(|entry| Arc::ptr_eq(entry, &self.control));
        if should_remove {
            controls.remove(&self.request_id);
        }
    }
}

struct ClientFactory {
    profile: Profile,
    base_resolver: Arc<dyn Resolve>,
    #[cfg(windows)]
    cert_store: Mutex<Option<wreq::tls::trust::CertStore>>,
}

fn emulation_for_profile(profile: Profile) -> Result<wreq::Emulation, i32> {
    let mut emulation = Emulation::builder()
        .profile(profile)
        .platform(Platform::Windows)
        .build()
        .into_emulation();
    if profile == Profile::Chrome149 {
        let tls_options = emulation
            .tls_options
            .as_mut()
            .ok_or(WREQ_TRANSPORT_INTERNAL_ERROR)?;
        // The same-machine Chrome149 field-trial cohort advertises Trust
        // Anchor Identifiers support even when DNS supplies no selected IDs.
        // BoringSSL encodes Some(empty) as extension 0xca34 with the two-byte
        // empty vector payload; no ClientHello bytes are forged.
        tls_options.requested_trust_anchors = Some(Vec::new().into());
    }
    Ok(emulation)
}

impl ClientFactory {
    fn build(&self, key: &ClientKey) -> Result<wreq::Client, i32> {
        let emulation = emulation_for_profile(self.profile)?;
        let mut client_builder = wreq::Client::builder()
            .emulation(emulation)
            .redirect(wreq::redirect::Policy::none())
            .no_proxy();
        let localhost_resolver = LocalhostResolver {
            inner: Arc::clone(&self.base_resolver),
        };
        client_builder = client_builder.dns_resolver(localhost_resolver);
        if let Some(proxy_url) = key.proxy_url.as_deref() {
            let proxy = wreq::Proxy::all(proxy_url).map_err(|_| WREQ_TRANSPORT_INVALID_ARGUMENT)?;
            client_builder = client_builder.proxy(proxy);
        }
        if !key.verify_tls {
            client_builder = client_builder
                .tls_cert_verification(false)
                .tls_verify_hostname(false);
        }
        #[cfg(windows)]
        if key.verify_tls {
            let cert_store = {
                let mut slot = lock_unpoisoned(&self.cert_store);
                if slot.is_none() {
                    *slot = Some(windows_native_cert_store()?);
                }
                slot.as_ref()
                    .expect("certificate store initialized")
                    .clone()
            };
            client_builder = client_builder.tls_cert_store(cert_store);
        }
        client_builder
            .build()
            .map_err(|_| WREQ_TRANSPORT_INTERNAL_ERROR)
    }
}

pub struct WreqTransport {
    runtime: Mutex<Option<Runtime>>,
    client_factory: ClientFactory,
    default_client_key: ClientKey,
    clients: Mutex<HashMap<ClientKey, wreq::Client>>,
    events_tx: mpsc::Sender<QueueMessage>,
    events_rx: Mutex<mpsc::Receiver<QueueMessage>>,
    event_slots: Arc<Semaphore>,
    wake_pending: AtomicBool,
    controls: ControlTable,
    next_request_id: AtomicU64,
    shutting_down: AtomicBool,
}

impl WreqTransport {
    fn client_for(&self, key: &ClientKey) -> Result<wreq::Client, i32> {
        if let Some(client) = lock_unpoisoned(&self.clients).get(key).cloned() {
            return Ok(client);
        }

        // Build outside the cache lock: loading the Windows root store and
        // constructing a TLS profile are relatively expensive, and submitters
        // using an already-cached profile should not be blocked behind them.
        let candidate = self.client_factory.build(key)?;
        let mut clients = lock_unpoisoned(&self.clients);
        Ok(clients.entry(key.clone()).or_insert(candidate).clone())
    }
}

impl Drop for WreqTransport {
    fn drop(&mut self) {
        self.shutting_down.store(true, Ordering::Release);

        let controls = lock_unpoisoned(&self.controls);
        for control in controls.values() {
            control.cancel.cancel();
        }
        drop(controls);
        self.event_slots.close();

        let runtime_slot = match self.runtime.get_mut() {
            Ok(slot) => slot,
            Err(poisoned) => poisoned.into_inner(),
        };
        if let Some(runtime) = runtime_slot.take() {
            // Dropping a Tokio runtime waits for spawn_blocking work (notably
            // GaiResolver's OS DNS call) to return. `shutdown_timeout` would
            // leak a still-running blocking thread after its deadline, making
            // it unsafe for a C host to unload this DLL after transport_free.
            // The ABI promises teardown, not background execution past free.
            drop(runtime);
        }
    }
}

#[repr(C)]
struct EventAllocation {
    public: WreqEvent,
    _header_storage: Box<[OwnedHeaderBytes]>,
    _header_views: Box<[WreqHeader]>,
    _data: Box<[u8]>,
    _queue_permit: Option<OwnedSemaphorePermit>,
}

impl EventAllocation {
    fn new(event: InternalEvent, queue_permit: Option<OwnedSemaphorePermit>) -> Self {
        let header_storage = event.headers.into_boxed_slice();
        let mut header_views = Vec::with_capacity(header_storage.len());
        for header in header_storage.iter() {
            header_views.push(WreqHeader {
                name: view_box(&header.name),
                value: view_box(&header.value),
            });
        }
        let header_views = header_views.into_boxed_slice();
        let data = event.data.into_boxed_slice();

        let public = WreqEvent {
            kind: event.kind,
            http_version: event.http_version,
            request_id: event.request_id,
            status_code: event.status_code,
            reserved16: 0,
            reserved32: 0,
            encoded_body_size: event.encoded_body_size,
            decoded_body_size: event.decoded_body_size,
            headers: if header_views.is_empty() {
                ptr::null()
            } else {
                header_views.as_ptr()
            },
            header_count: header_views.len(),
            data: view_box(&data),
        };

        Self {
            public,
            _header_storage: header_storage,
            _header_views: header_views,
            _data: data,
            _queue_permit: queue_permit,
        }
    }
}

fn lock_unpoisoned<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    match mutex.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    }
}

fn view_box(bytes: &[u8]) -> WreqSlice {
    if bytes.is_empty() {
        WreqSlice::empty()
    } else {
        WreqSlice {
            ptr: bytes.as_ptr(),
            len: bytes.len(),
        }
    }
}

fn ffi_status(f: impl FnOnce() -> i32) -> i32 {
    catch_unwind(AssertUnwindSafe(f)).unwrap_or(WREQ_TRANSPORT_PANIC)
}

fn ffi_void(f: impl FnOnce()) {
    let _ = catch_unwind(AssertUnwindSafe(f));
}

unsafe fn copy_bytes(input: WreqSlice) -> Result<Vec<u8>, i32> {
    if input.len == 0 {
        return Ok(Vec::new());
    }
    if input.ptr.is_null() || input.len > isize::MAX as usize {
        return Err(WREQ_TRANSPORT_INVALID_ARGUMENT);
    }
    let start = input.ptr as usize;
    if start.checked_add(input.len).is_none() {
        return Err(WREQ_TRANSPORT_INVALID_ARGUMENT);
    }

    let mut result = Vec::new();
    result
        .try_reserve_exact(input.len)
        .map_err(|_| WREQ_TRANSPORT_OUT_OF_MEMORY)?;
    // SAFETY: the caller promises that every non-empty input range is valid
    // for reads during the FFI call. Length and address overflow were checked.
    let source = unsafe { slice::from_raw_parts(input.ptr, input.len) };
    result.extend_from_slice(source);
    Ok(result)
}

unsafe fn copy_request(input: WreqRequest) -> Result<OwnedRequest, i32> {
    const KNOWN_FLAGS: u64 = WREQ_REQUEST_OPTION_CONFIG_OVERRIDE
        | WREQ_REQUEST_OPTION_INSECURE_SKIP_TLS_VERIFY
        | WREQ_REQUEST_OPTION_FOLLOW_REDIRECTS;
    if input.struct_size < size_of::<WreqRequest>() as u32
        || input.abi_version != WREQ_TRANSPORT_ABI_VERSION
        || input.flags & !KNOWN_FLAGS != 0
        || input.flags & WREQ_REQUEST_OPTION_INSECURE_SKIP_TLS_VERIFY != 0
            && input.flags & WREQ_REQUEST_OPTION_CONFIG_OVERRIDE == 0
    {
        return Err(WREQ_TRANSPORT_INVALID_ARGUMENT);
    }

    let method_bytes = unsafe { copy_bytes(input.method) }?;
    let method = Method::from_bytes(&method_bytes).map_err(|_| WREQ_TRANSPORT_INVALID_ARGUMENT)?;

    let url_bytes = unsafe { copy_bytes(input.url) }?;
    let url = str::from_utf8(&url_bytes).map_err(|_| WREQ_TRANSPORT_INVALID_ARGUMENT)?;
    let uri = Uri::try_from(url).map_err(|_| WREQ_TRANSPORT_INVALID_ARGUMENT)?;
    // The ordinary submit entry point rejects ws/wss below; accepting those
    // schemes while deep-copying lets the WebSocket-specific entry point share
    // the exact same versioned request/header/config layout.
    let scheme_is_supported = matches!(uri.scheme_str(), Some("http" | "https" | "ws" | "wss"));
    if !scheme_is_supported || uri.authority().is_none() {
        return Err(WREQ_TRANSPORT_INVALID_ARGUMENT);
    }

    let mut headers = Vec::new();
    if input.header_count != 0 {
        if input.headers.is_null()
            || (input.headers as usize) % align_of::<WreqHeader>() != 0
            || input.header_count > (isize::MAX as usize) / size_of::<WreqHeader>()
        {
            return Err(WREQ_TRANSPORT_INVALID_ARGUMENT);
        }
        let byte_len = input
            .header_count
            .checked_mul(size_of::<WreqHeader>())
            .ok_or(WREQ_TRANSPORT_INVALID_ARGUMENT)?;
        if (input.headers as usize).checked_add(byte_len).is_none() {
            return Err(WREQ_TRANSPORT_INVALID_ARGUMENT);
        }

        headers
            .try_reserve_exact(input.header_count)
            .map_err(|_| WREQ_TRANSPORT_OUT_OF_MEMORY)?;
        for index in 0..input.header_count {
            // SAFETY: the caller promises a readable array for header_count
            // entries; alignment, multiplication, and address overflow were
            // checked above. WreqHeader is Copy and contains only raw views.
            let raw = unsafe { ptr::read(input.headers.add(index)) };
            let original_name_bytes = unsafe { copy_bytes(raw.name) }?;
            let original_name = str::from_utf8(&original_name_bytes)
                .map_err(|_| WREQ_TRANSPORT_INVALID_ARGUMENT)?;
            let name = HeaderName::from_bytes(&original_name_bytes)
                .map_err(|_| WREQ_TRANSPORT_INVALID_ARGUMENT)?;
            let value_bytes = unsafe { copy_bytes(raw.value) }?;
            let value = HeaderValue::from_bytes(&value_bytes)
                .map_err(|_| WREQ_TRANSPORT_INVALID_ARGUMENT)?;
            headers.push(OwnedRequestHeader {
                original_name: original_name.to_owned(),
                name,
                value,
            });
        }
    } else if !input.headers.is_null() {
        // Non-NULL with zero entries is valid and deliberately ignored.
    }

    let body = unsafe { copy_bytes(input.body) }?;
    let client_override = if input.flags & WREQ_REQUEST_OPTION_CONFIG_OVERRIDE != 0 {
        let proxy_bytes = unsafe { copy_bytes(input.proxy_url) }?;
        let proxy_url = if proxy_bytes.is_empty() {
            None
        } else {
            let proxy =
                String::from_utf8(proxy_bytes).map_err(|_| WREQ_TRANSPORT_INVALID_ARGUMENT)?;
            validate_proxy_url(&proxy)?;
            Some(proxy)
        };
        Some(ClientKey {
            verify_tls: input.flags & WREQ_REQUEST_OPTION_INSECURE_SKIP_TLS_VERIFY == 0,
            proxy_url,
        })
    } else {
        if input.proxy_url.len != 0 {
            return Err(WREQ_TRANSPORT_INVALID_ARGUMENT);
        }
        None
    };
    Ok(OwnedRequest {
        method,
        uri,
        headers,
        body,
        timeout: (input.timeout_ms != 0).then(|| Duration::from_millis(input.timeout_ms)),
        follow_redirects: input.flags & WREQ_REQUEST_OPTION_FOLLOW_REDIRECTS != 0,
        client_override,
    })
}

fn validate_proxy_url(proxy: &str) -> Result<(), i32> {
    let uri = Uri::try_from(proxy).map_err(|_| WREQ_TRANSPORT_INVALID_ARGUMENT)?;
    if !matches!(uri.scheme_str(), Some("http" | "https")) || uri.authority().is_none() {
        return Err(WREQ_TRANSPORT_INVALID_ARGUMENT);
    }
    Ok(())
}

fn panic_payload(payload: Box<dyn Any + Send>) -> Vec<u8> {
    let message = if let Some(message) = payload.downcast_ref::<&str>() {
        (*message).to_owned()
    } else if let Some(message) = payload.downcast_ref::<String>() {
        message.clone()
    } else {
        "unknown Rust panic".to_owned()
    };
    format!("wreq transport task panicked: {message}").into_bytes()
}

fn response_version(version: Version) -> u32 {
    match version {
        Version::HTTP_09 => 9,
        Version::HTTP_10 => 10,
        Version::HTTP_11 => 11,
        Version::HTTP_2 => 20,
        Version::HTTP_3 => 30,
        _ => 0,
    }
}

fn response_headers(headers: &HeaderMap) -> Vec<OwnedHeaderBytes> {
    headers
        .iter()
        .map(|(name, value)| OwnedHeaderBytes {
            name: name.as_str().as_bytes().into(),
            value: value.as_bytes().into(),
        })
        .collect()
}

/// wreq follows reqwest's convention of removing Content-Encoding and
/// Content-Length after transparent decompression. Browser response headers
/// retain the server's original fields, so restore the captured values while
/// keeping their ordinary header names (no private/synthetic wire headers).
fn response_headers_with_decoding_metadata(response: &wreq::Response) -> Vec<OwnedHeaderBytes> {
    let mut headers = response_headers(response.headers());
    let Some(tracker) = response.encoded_body_size_tracker() else {
        return headers;
    };

    if !response
        .headers()
        .contains_key(wreq::header::CONTENT_ENCODING)
    {
        if let Some(value) = tracker.content_encoding() {
            headers.push(OwnedHeaderBytes {
                name: Box::from(&b"content-encoding"[..]),
                value: Box::from(value.as_bytes()),
            });
        }
    }
    if !response
        .headers()
        .contains_key(wreq::header::CONTENT_LENGTH)
    {
        if let Some(value) = tracker.declared() {
            headers.push(OwnedHeaderBytes {
                name: Box::from(&b"content-length"[..]),
                value: value.to_string().into_bytes().into_boxed_slice(),
            });
        }
    }
    headers
}

async fn run_request(context: TaskContext, client: wreq::Client, request: OwnedRequest) {
    if context
        .control
        .state
        .compare_exchange(
            STATE_QUEUED,
            STATE_RUNNING,
            Ordering::AcqRel,
            Ordering::Acquire,
        )
        .is_err()
    {
        context
            .finish(
                WREQ_EVENT_ERROR,
                b"request entered an invalid initial state".to_vec(),
            )
            .await;
        return;
    }

    let request_timeout = request.timeout;
    let total_timeout = async move {
        if let Some(timeout) = request_timeout {
            tokio::time::sleep(timeout).await;
        } else {
            future::pending::<()>().await;
        }
    };
    tokio::pin!(total_timeout);
    let mut headers = HeaderMap::with_capacity(request.headers.len());
    let mut original_headers = OrigHeaderMap::with_capacity(request.headers.len());
    for header in request.headers {
        original_headers.insert(header.original_name);
        headers.append(header.name, header.value);
    }

    let mut builder = client
        .request(request.method, request.uri)
        .headers(headers)
        .orig_headers(original_headers)
        .default_headers(false);
    if let Some(timeout) = request_timeout {
        builder = builder.timeout(timeout);
    }
    if request.follow_redirects {
        builder = builder.redirect(wreq::redirect::Policy::limited(10));
    }
    if !request.body.is_empty() {
        builder = builder.body(request.body);
    }

    let response_result = tokio::select! {
        biased;
        _ = context.control.cancel.cancelled() => {
            context.finish(WREQ_EVENT_CANCELLED, Vec::new()).await;
            return;
        }
        _ = &mut total_timeout => {
            context
                .finish(WREQ_EVENT_ERROR, b"request total timeout elapsed".to_vec())
                .await;
            return;
        }
        result = builder.send() => result,
    };

    let response = match response_result {
        Ok(response) => response,
        Err(error) => {
            context
                .finish(WREQ_EVENT_ERROR, error.to_string().into_bytes())
                .await;
            return;
        }
    };

    // Clone the shared pre-decompression counter before bytes_stream consumes
    // the Response. It reaches its final value exactly when the decoded stream
    // reaches EOF below.
    let encoded_body_tracker = response.encoded_body_size_tracker();

    let headers_event = InternalEvent {
        kind: WREQ_EVENT_HEADERS,
        http_version: response_version(response.version()),
        request_id: context.request_id,
        status_code: response.status().as_u16(),
        encoded_body_size: 0,
        decoded_body_size: 0,
        headers: response_headers_with_decoding_metadata(&response),
        data: Vec::new(),
    };

    let (ack_sender, ack_receiver) = oneshot::channel();
    *lock_unpoisoned(&context.control.headers_ack) = Some(ack_sender);
    context
        .control
        .state
        .store(STATE_AWAITING_HEADERS_ACK, Ordering::Release);

    if !context.emit(headers_event).await {
        context.retire_without_event();
        return;
    }

    let ack_result = tokio::select! {
        biased;
        _ = context.control.cancel.cancelled() => {
            context.finish(WREQ_EVENT_CANCELLED, Vec::new()).await;
            return;
        }
        _ = &mut total_timeout => {
            context
                .finish(WREQ_EVENT_ERROR, b"request total timeout elapsed".to_vec())
                .await;
            return;
        }
        result = ack_receiver => result,
    };
    if ack_result.is_err() {
        if context.control.cancel.is_cancelled() {
            context.finish(WREQ_EVENT_CANCELLED, Vec::new()).await;
        } else {
            context
                .finish(
                    WREQ_EVENT_ERROR,
                    b"response headers acknowledgement channel closed".to_vec(),
                )
                .await;
        }
        return;
    }
    context
        .control
        .state
        .compare_exchange(
            STATE_AWAITING_HEADERS_ACK,
            STATE_STREAMING,
            Ordering::AcqRel,
            Ordering::Acquire,
        )
        .ok();

    let mut body = response.bytes_stream();
    let mut decoded_body_size = 0_u64;
    loop {
        let item = tokio::select! {
            biased;
            _ = context.control.cancel.cancelled() => {
                context.finish(WREQ_EVENT_CANCELLED, Vec::new()).await;
                return;
            }
            _ = &mut total_timeout => {
                context
                    .finish(WREQ_EVENT_ERROR, b"request total timeout elapsed".to_vec())
                    .await;
                return;
            }
            item = body.next() => item,
        };

        match item {
            Some(Ok(bytes)) => {
                decoded_body_size = decoded_body_size.saturating_add(bytes.len() as u64);
                if !bytes.is_empty()
                    && !context
                        .emit(InternalEvent {
                            kind: WREQ_EVENT_DATA,
                            http_version: 0,
                            request_id: context.request_id,
                            status_code: 0,
                            encoded_body_size: 0,
                            decoded_body_size: 0,
                            headers: Vec::new(),
                            data: bytes.to_vec(),
                        })
                        .await
                {
                    context.retire_without_event();
                    return;
                }
            }
            Some(Err(error)) => {
                context
                    .finish(WREQ_EVENT_ERROR, error.to_string().into_bytes())
                    .await;
                return;
            }
            None => {
                context
                    .finish_event(InternalEvent::terminal_with_body_sizes(
                        WREQ_EVENT_DONE,
                        context.request_id,
                        encoded_body_tracker
                            .as_ref()
                            .map_or(decoded_body_size, |tracker| tracker.observed()),
                        decoded_body_size,
                    ))
                    .await;
                return;
            }
        }
    }
}

async fn run_websocket(context: TaskContext, client: wreq::Client, request: OwnedRequest) {
    if context
        .control
        .state
        .compare_exchange(
            STATE_QUEUED,
            STATE_RUNNING,
            Ordering::AcqRel,
            Ordering::Acquire,
        )
        .is_err()
    {
        context
            .finish(
                WREQ_EVENT_ERROR,
                b"websocket entered an invalid initial state".to_vec(),
            )
            .await;
        return;
    }

    let request_timeout = request.timeout;
    let handshake_timeout = async move {
        if let Some(timeout) = request_timeout {
            tokio::time::sleep(timeout).await;
        } else {
            future::pending::<()>().await;
        }
    };
    tokio::pin!(handshake_timeout);

    let mut headers = HeaderMap::with_capacity(request.headers.len());
    let mut original_headers = OrigHeaderMap::with_capacity(request.headers.len());
    let mut protocols = Vec::<String>::new();
    for header in request.headers {
        if header.name == wreq::header::SEC_WEBSOCKET_PROTOCOL {
            let Ok(value) = header.value.to_str() else {
                context
                    .finish(
                        WREQ_EVENT_ERROR,
                        b"websocket subprotocol header is not UTF-8".to_vec(),
                    )
                    .await;
                return;
            };
            // `WebSocketRequestBuilder::protocols` recreates this header after
            // the request builder has consumed the caller's value.  Retain
            // the browser-supplied spelling/order separately so the HTTP/1
            // encoder does not fall back to the lowercase HeaderName form.
            original_headers.insert(header.original_name);
            protocols.extend(
                value
                    .split(',')
                    .map(str::trim)
                    .filter(|value| !value.is_empty())
                    .map(str::to_owned),
            );
            continue;
        }

        // wreq owns the RFC 6455 handshake fields. Silently exclude any raw
        // copies so a caller cannot create duplicate keys or an accept-key
        // validation mismatch at the ABI boundary.
        if matches!(
            header.name,
            wreq::header::SEC_WEBSOCKET_KEY
                | wreq::header::SEC_WEBSOCKET_VERSION
                | wreq::header::UPGRADE
                | wreq::header::CONNECTION
        ) {
            continue;
        }
        original_headers.insert(header.original_name);
        headers.append(header.name, header.value);
    }

    // wreq owns these RFC 6455 fields and inserts them only inside
    // WebSocketRequestBuilder::send().  OrigHeaderMap is also the HTTP/1 case
    // map, so register their browser spelling now.  Besides matching Chromium
    // wire casing, this is required for interoperability with older but still
    // deployed HTTP/1 upgrade handlers which parse the conventional spelling.
    original_headers.insert("Sec-WebSocket-Version");
    original_headers.insert("Upgrade");
    original_headers.insert("Connection");
    original_headers.insert("Sec-WebSocket-Key");

    let mut builder = client
        .websocket(request.uri)
        .version(Version::HTTP_11)
        .headers(headers)
        .orig_headers(original_headers)
        .default_headers(false);
    if !protocols.is_empty() {
        builder = builder.protocols(protocols);
    }

    let response_result = tokio::select! {
        biased;
        _ = context.control.cancel.cancelled() => {
            context.finish(WREQ_EVENT_CANCELLED, Vec::new()).await;
            return;
        }
        _ = &mut handshake_timeout => {
            context
                .finish(WREQ_EVENT_ERROR, b"websocket handshake timeout elapsed".to_vec())
                .await;
            return;
        }
        result = builder.send() => result,
    };
    let response = match response_result {
        Ok(response) => response,
        Err(error) => {
            context
                .finish(WREQ_EVENT_ERROR, error.to_string().into_bytes())
                .await;
            return;
        }
    };

    let open_event = InternalEvent {
        kind: WREQ_EVENT_WEBSOCKET_OPEN,
        http_version: response_version(response.version()),
        request_id: context.request_id,
        status_code: response.status().as_u16(),
        encoded_body_size: 0,
        decoded_body_size: 0,
        headers: response_headers(response.headers()),
        data: Vec::new(),
    };
    let websocket_result = tokio::select! {
        biased;
        _ = context.control.cancel.cancelled() => {
            context.finish(WREQ_EVENT_CANCELLED, Vec::new()).await;
            return;
        }
        _ = &mut handshake_timeout => {
            context
                .finish(WREQ_EVENT_ERROR, b"websocket handshake timeout elapsed".to_vec())
                .await;
            return;
        }
        result = response.into_websocket() => result,
    };
    let mut websocket = match websocket_result {
        Ok(websocket) => websocket,
        Err(error) => {
            context
                .finish(WREQ_EVENT_ERROR, error.to_string().into_bytes())
                .await;
            return;
        }
    };

    let (command_tx, mut command_rx) = tokio_mpsc::channel(256);
    *lock_unpoisoned(&context.control.websocket_commands) = Some(command_tx);
    context
        .control
        .state
        .store(STATE_STREAMING, Ordering::Release);
    if !context.emit(open_event).await {
        context.retire_without_event();
        return;
    }

    loop {
        tokio::select! {
            biased;
            _ = context.control.cancel.cancelled() => {
                context.finish(WREQ_EVENT_CANCELLED, Vec::new()).await;
                return;
            }
            command = command_rx.recv() => {
                let Some(command) = command else {
                    context
                        .finish(WREQ_EVENT_ERROR, b"websocket command channel closed".to_vec())
                        .await;
                    return;
                };
                let message = match command {
                    WebSocketCommand::Text(text) => wreq::ws::message::Message::text(text),
                    WebSocketCommand::Binary(data) => wreq::ws::message::Message::binary(data),
                    WebSocketCommand::Close { code, reason } => {
                        wreq::ws::message::Message::close(wreq::ws::message::CloseFrame {
                            code: code.into(),
                            reason: reason.into(),
                        })
                    }
                };
                let send_result = tokio::select! {
                    biased;
                    _ = context.control.cancel.cancelled() => {
                        context.finish(WREQ_EVENT_CANCELLED, Vec::new()).await;
                        return;
                    }
                    result = websocket.send(message) => result,
                };
                if let Err(error) = send_result {
                    context
                        .finish(WREQ_EVENT_ERROR, error.to_string().into_bytes())
                        .await;
                    return;
                }
            }
            incoming = websocket.next() => {
                match incoming {
                    Some(Ok(wreq::ws::message::Message::Text(text))) => {
                        if !context.emit(InternalEvent {
                            kind: WREQ_EVENT_WEBSOCKET_TEXT,
                            http_version: 0,
                            request_id: context.request_id,
                            status_code: 0,
                            encoded_body_size: 0,
                            decoded_body_size: 0,
                            headers: Vec::new(),
                            data: text.as_bytes().to_vec(),
                        }).await {
                            context.retire_without_event();
                            return;
                        }
                    }
                    Some(Ok(wreq::ws::message::Message::Binary(data))) => {
                        if !context.emit(InternalEvent {
                            kind: WREQ_EVENT_WEBSOCKET_BINARY,
                            http_version: 0,
                            request_id: context.request_id,
                            status_code: 0,
                            encoded_body_size: 0,
                            decoded_body_size: 0,
                            headers: Vec::new(),
                            data: data.to_vec(),
                        }).await {
                            context.retire_without_event();
                            return;
                        }
                    }
                    Some(Ok(wreq::ws::message::Message::Close(frame))) => {
                        let (code, reason) = frame
                            .map(|frame| (u16::from(frame.code), frame.reason.as_bytes().to_vec()))
                            .unwrap_or((1005, Vec::new()));
                        context.finish_event(InternalEvent {
                            kind: WREQ_EVENT_WEBSOCKET_CLOSE,
                            http_version: 0,
                            request_id: context.request_id,
                            status_code: code,
                            encoded_body_size: 0,
                            decoded_body_size: 0,
                            headers: Vec::new(),
                            data: reason,
                        }).await;
                        return;
                    }
                    Some(Ok(wreq::ws::message::Message::Ping(_)
                        | wreq::ws::message::Message::Pong(_))) => {}
                    Some(Err(error)) => {
                        context
                            .finish(WREQ_EVENT_ERROR, error.to_string().into_bytes())
                            .await;
                        return;
                    }
                    None => {
                        context
                            .finish(WREQ_EVENT_ERROR, b"websocket stream ended without a close frame".to_vec())
                            .await;
                        return;
                    }
                }
            }
        }
    }
}

struct CreateConfig {
    default_client_key: ClientKey,
    event_capacity: usize,
    profile: Profile,
    dns_nameservers: Option<Vec<SocketAddr>>,
}

impl Default for CreateConfig {
    fn default() -> Self {
        Self {
            default_client_key: ClientKey {
                verify_tls: true,
                proxy_url: None,
            },
            event_capacity: WREQ_TRANSPORT_DEFAULT_EVENT_CAPACITY as usize,
            profile: Profile::Chrome149,
            dns_nameservers: None,
        }
    }
}

fn parse_dns_nameservers(input: &[u8]) -> Result<Vec<SocketAddr>, i32> {
    const MAX_NAMESERVERS: usize = 8;

    let text = str::from_utf8(input).map_err(|_| WREQ_TRANSPORT_INVALID_ARGUMENT)?;
    let bytes = text.as_bytes();
    for (index, byte) in bytes.iter().enumerate() {
        if *byte == b'\r' && bytes.get(index + 1) != Some(&b'\n') {
            return Err(WREQ_TRANSPORT_INVALID_ARGUMENT);
        }
    }
    let mut nameservers = Vec::new();
    let mut entry_count = 0_usize;
    for raw_entry in text.split(|character| matches!(character, ',' | '\n')) {
        entry_count += 1;
        if entry_count > MAX_NAMESERVERS {
            return Err(WREQ_TRANSPORT_INVALID_ARGUMENT);
        }
        let entry = raw_entry.strip_suffix('\r').unwrap_or(raw_entry).trim();
        if entry.is_empty() {
            return Err(WREQ_TRANSPORT_INVALID_ARGUMENT);
        }
        let address = if let Ok(ip) = entry.parse::<IpAddr>() {
            SocketAddr::new(ip, 53)
        } else {
            entry
                .parse::<SocketAddr>()
                .map_err(|_| WREQ_TRANSPORT_INVALID_ARGUMENT)?
        };
        if address.port() == 0 {
            return Err(WREQ_TRANSPORT_INVALID_ARGUMENT);
        }
        if !nameservers.contains(&address) {
            nameservers.push(address);
        }
    }
    if nameservers.is_empty() {
        return Err(WREQ_TRANSPORT_INVALID_ARGUMENT);
    }
    Ok(nameservers)
}

unsafe fn copy_create_options(input: WreqTransportOptions) -> Result<CreateConfig, i32> {
    const KNOWN_FLAGS: u64 =
        WREQ_TRANSPORT_OPTION_INSECURE_SKIP_TLS_VERIFY | WREQ_TRANSPORT_OPTION_CUSTOM_DNS;
    if input.struct_size < size_of::<WreqTransportOptions>() as u32
        || input.abi_version != WREQ_TRANSPORT_ABI_VERSION
        || input.flags & !KNOWN_FLAGS != 0
        || input.reserved32 != 0
        || input.event_capacity > WREQ_TRANSPORT_MAX_EVENT_CAPACITY
    {
        return Err(WREQ_TRANSPORT_INVALID_ARGUMENT);
    }

    let custom_dns_enabled = input.flags & WREQ_TRANSPORT_OPTION_CUSTOM_DNS != 0;
    if custom_dns_enabled != (input.dns_nameservers.len != 0) {
        return Err(WREQ_TRANSPORT_INVALID_ARGUMENT);
    }
    let dns_nameservers = if custom_dns_enabled {
        let bytes = unsafe { copy_bytes(input.dns_nameservers) }?;
        Some(parse_dns_nameservers(&bytes)?)
    } else {
        None
    };

    let proxy_bytes = unsafe { copy_bytes(input.proxy_url) }?;
    let proxy_url = if proxy_bytes.is_empty() {
        None
    } else {
        let proxy = String::from_utf8(proxy_bytes).map_err(|_| WREQ_TRANSPORT_INVALID_ARGUMENT)?;
        validate_proxy_url(&proxy)?;
        Some(proxy)
    };

    let profile = match input.profile_id {
        WREQ_TRANSPORT_PROFILE_DEFAULT | WREQ_TRANSPORT_PROFILE_CHROME_149 => Profile::Chrome149,
        WREQ_TRANSPORT_PROFILE_CHROME_124 => Profile::Chrome124,
        _ => return Err(WREQ_TRANSPORT_INVALID_ARGUMENT),
    };

    Ok(CreateConfig {
        default_client_key: ClientKey {
            verify_tls: input.flags & WREQ_TRANSPORT_OPTION_INSECURE_SKIP_TLS_VERIFY == 0,
            proxy_url,
        },
        event_capacity: if input.event_capacity == 0 {
            WREQ_TRANSPORT_DEFAULT_EVENT_CAPACITY as usize
        } else {
            input.event_capacity as usize
        },
        profile,
        dns_nameservers,
    })
}

#[cfg(windows)]
fn windows_native_cert_store() -> Result<wreq::tls::trust::CertStore, i32> {
    const PKIX_SERVER_AUTH: &str = "1.3.6.1.5.5.7.3.1";
    let mut certificates = BTreeSet::<Vec<u8>>::new();
    let mut opened_store = false;

    let stores = [
        WindowsCertStore::open_current_user("ROOT"),
        WindowsCertStore::open_local_machine("ROOT"),
    ];
    for store in stores.into_iter().flatten() {
        opened_store = true;
        for certificate in store.certs() {
            let is_time_valid = certificate.is_time_valid().unwrap_or(false);
            let is_server_root = match certificate.valid_uses() {
                Ok(ValidUses::All) => true,
                Ok(ValidUses::Oids(oids)) => oids.iter().any(|oid| oid == PKIX_SERVER_AUTH),
                Err(_) => false,
            };
            if is_time_valid && is_server_root {
                certificates.insert(certificate.to_der().to_vec());
            }
        }
    }

    if !opened_store || certificates.is_empty() {
        return Err(WREQ_TRANSPORT_INTERNAL_ERROR);
    }
    wreq::tls::trust::CertStore::from_der_certs(
        certificates
            .iter()
            .map(|certificate| certificate.as_slice()),
    )
    .map_err(|_| WREQ_TRANSPORT_INTERNAL_ERROR)
}

fn create_impl(config: CreateConfig, out_transport: *mut *mut WreqTransport) -> i32 {
    if out_transport.is_null() {
        return WREQ_TRANSPORT_INVALID_ARGUMENT;
    }
    // SAFETY: a non-NULL output pointer is required to identify writable
    // storage for one pointer value.
    unsafe { ptr::write(out_transport, ptr::null_mut()) };

    let runtime = match tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .thread_name("wreq-transport")
        .build()
    {
        Ok(runtime) => runtime,
        Err(_) => return WREQ_TRANSPORT_INTERNAL_ERROR,
    };

    let base_resolver: Arc<dyn Resolve> = {
        // Hickory's Tokio provider is initialized while this transport's
        // runtime is current. Its cloned resolver/cache is then used from the
        // runtime workers that execute requests.
        let _runtime_guard = runtime.enter();
        match config.dns_nameservers.as_deref() {
            Some(nameservers) => match CustomDnsResolver::new(nameservers) {
                Ok(resolver) => Arc::new(resolver),
                Err(status) => return status,
            },
            None => Arc::new(GaiResolver::new()),
        }
    };

    let client_factory = ClientFactory {
        profile: config.profile,
        base_resolver,
        #[cfg(windows)]
        cert_store: Mutex::new(None),
    };
    let default_client = match client_factory.build(&config.default_client_key) {
        Ok(client) => client,
        Err(status) => return status,
    };
    let mut clients = HashMap::new();
    clients.insert(config.default_client_key.clone(), default_client);

    let (events_tx, events_rx) = mpsc::channel();
    let event_slots = Arc::new(Semaphore::new(config.event_capacity));
    let transport = Box::new(WreqTransport {
        runtime: Mutex::new(Some(runtime)),
        client_factory,
        default_client_key: config.default_client_key,
        clients: Mutex::new(clients),
        events_tx,
        events_rx: Mutex::new(events_rx),
        event_slots,
        wake_pending: AtomicBool::new(false),
        controls: Arc::new(Mutex::new(HashMap::new())),
        next_request_id: AtomicU64::new(1),
        shutting_down: AtomicBool::new(false),
    });
    // SAFETY: out_transport was checked above and remains valid for this call.
    unsafe { ptr::write(out_transport, Box::into_raw(transport)) };
    WREQ_TRANSPORT_OK
}

fn submit_impl(
    transport: *mut WreqTransport,
    request: *const WreqRequest,
    out_request_id: *mut u64,
) -> i32 {
    if transport.is_null() || request.is_null() || out_request_id.is_null() {
        return WREQ_TRANSPORT_INVALID_ARGUMENT;
    }
    if (request as usize) % align_of::<WreqRequest>() != 0 {
        return WREQ_TRANSPORT_INVALID_ARGUMENT;
    }

    // Copy all caller-owned input before touching the output slot. This also
    // prevents an aliased output from changing bytes while they are copied.
    // SAFETY: the caller promises a readable, aligned WreqRequest.
    let raw_request = unsafe { ptr::read(request) };
    // SAFETY: copy_request validates every nested view before reading it.
    let request = match unsafe { copy_request(raw_request) } {
        Ok(request) => request,
        Err(status) => return status,
    };
    if !matches!(request.uri.scheme_str(), Some("http" | "https")) {
        return WREQ_TRANSPORT_INVALID_ARGUMENT;
    }
    // SAFETY: the caller promises writable storage for one u64.
    unsafe { ptr::write(out_request_id, 0) };

    // SAFETY: transport was checked for NULL. Its lifetime and exclusion from
    // concurrent free are part of the C ABI contract.
    let transport = unsafe { &*transport };
    if transport.shutting_down.load(Ordering::Acquire) {
        return WREQ_TRANSPORT_SHUTTING_DOWN;
    }

    let client_key = request
        .client_override
        .clone()
        .unwrap_or_else(|| transport.default_client_key.clone());
    let client = match transport.client_for(&client_key) {
        Ok(client) => client,
        Err(status) => return status,
    };
    let request_id = match transport.next_request_id.fetch_update(
        Ordering::AcqRel,
        Ordering::Acquire,
        |current| {
            if current == 0 || current == u64::MAX {
                None
            } else {
                Some(current + 1)
            }
        },
    ) {
        Ok(request_id) => request_id,
        Err(_) => return WREQ_TRANSPORT_OVERFLOW,
    };

    let control = Arc::new(RequestControl::new());
    lock_unpoisoned(&transport.controls).insert(request_id, Arc::clone(&control));
    let context = TaskContext {
        request_id,
        control,
        controls: Arc::clone(&transport.controls),
        events: transport.events_tx.clone(),
        event_slots: Arc::clone(&transport.event_slots),
    };

    let runtime = lock_unpoisoned(&transport.runtime)
        .as_ref()
        .map(|runtime| runtime.handle().clone());
    let Some(runtime) = runtime else {
        context.retire_without_event();
        return WREQ_TRANSPORT_SHUTTING_DOWN;
    };

    let panic_context = context.clone();
    runtime.spawn(async move {
        let result = AssertUnwindSafe(run_request(context, client, request))
            .catch_unwind()
            .await;
        if let Err(payload) = result {
            panic_context
                .finish(WREQ_EVENT_ERROR, panic_payload(payload))
                .await;
        }
    });

    // SAFETY: the output pointer was validated above and input copying is done.
    unsafe { ptr::write(out_request_id, request_id) };
    WREQ_TRANSPORT_OK
}

fn websocket_submit_impl(
    transport: *mut WreqTransport,
    request: *const WreqRequest,
    out_request_id: *mut u64,
) -> i32 {
    if transport.is_null() || request.is_null() || out_request_id.is_null() {
        return WREQ_TRANSPORT_INVALID_ARGUMENT;
    }
    if (request as usize) % align_of::<WreqRequest>() != 0 {
        return WREQ_TRANSPORT_INVALID_ARGUMENT;
    }

    // SAFETY: the caller promises a readable, aligned request for this call;
    // copy_request validates and owns every nested view before returning.
    let raw_request = unsafe { ptr::read(request) };
    let request = match unsafe { copy_request(raw_request) } {
        Ok(request) => request,
        Err(status) => return status,
    };
    if request.method != Method::GET
        || !request.body.is_empty()
        || request.follow_redirects
        || !matches!(request.uri.scheme_str(), Some("ws" | "wss"))
    {
        return WREQ_TRANSPORT_INVALID_ARGUMENT;
    }
    // SAFETY: the caller promises writable storage for one u64.
    unsafe { ptr::write(out_request_id, 0) };

    // SAFETY: the handle lifetime/exclusion contract is documented in the C
    // header and matches every other operation on WreqTransport.
    let transport = unsafe { &*transport };
    if transport.shutting_down.load(Ordering::Acquire) {
        return WREQ_TRANSPORT_SHUTTING_DOWN;
    }

    let client_key = request
        .client_override
        .clone()
        .unwrap_or_else(|| transport.default_client_key.clone());
    let client = match transport.client_for(&client_key) {
        Ok(client) => client,
        Err(status) => return status,
    };
    let request_id = match transport.next_request_id.fetch_update(
        Ordering::AcqRel,
        Ordering::Acquire,
        |current| {
            if current == 0 || current == u64::MAX {
                None
            } else {
                Some(current + 1)
            }
        },
    ) {
        Ok(request_id) => request_id,
        Err(_) => return WREQ_TRANSPORT_OVERFLOW,
    };

    let control = Arc::new(RequestControl::new());
    lock_unpoisoned(&transport.controls).insert(request_id, Arc::clone(&control));
    let context = TaskContext {
        request_id,
        control,
        controls: Arc::clone(&transport.controls),
        events: transport.events_tx.clone(),
        event_slots: Arc::clone(&transport.event_slots),
    };
    let runtime = lock_unpoisoned(&transport.runtime)
        .as_ref()
        .map(|runtime| runtime.handle().clone());
    let Some(runtime) = runtime else {
        context.retire_without_event();
        return WREQ_TRANSPORT_SHUTTING_DOWN;
    };

    let panic_context = context.clone();
    runtime.spawn(async move {
        let result = AssertUnwindSafe(run_websocket(context, client, request))
            .catch_unwind()
            .await;
        if let Err(payload) = result {
            panic_context
                .finish(WREQ_EVENT_ERROR, panic_payload(payload))
                .await;
        }
    });

    // SAFETY: the output pointer was validated above.
    unsafe { ptr::write(out_request_id, request_id) };
    WREQ_TRANSPORT_OK
}

fn websocket_send_impl(
    transport: *mut WreqTransport,
    request_id: u64,
    message_type: u32,
    data: WreqSlice,
    close_code: u16,
) -> i32 {
    if transport.is_null() || request_id == 0 {
        return WREQ_TRANSPORT_INVALID_ARGUMENT;
    }
    // SAFETY: copy_bytes validates the view and completes before retaining any
    // command, so caller-owned memory may be released as soon as this returns.
    let bytes = match unsafe { copy_bytes(data) } {
        Ok(bytes) => bytes,
        Err(status) => return status,
    };
    let command = match message_type {
        WREQ_WEBSOCKET_SEND_TEXT => match String::from_utf8(bytes) {
            Ok(text) => WebSocketCommand::Text(text),
            Err(_) => return WREQ_TRANSPORT_INVALID_ARGUMENT,
        },
        WREQ_WEBSOCKET_SEND_BINARY => WebSocketCommand::Binary(bytes),
        WREQ_WEBSOCKET_SEND_CLOSE => {
            if (close_code != 1000 && !(3000..=4999).contains(&close_code)) || bytes.len() > 123 {
                return WREQ_TRANSPORT_INVALID_ARGUMENT;
            }
            let reason = match String::from_utf8(bytes) {
                Ok(reason) => reason,
                Err(_) => return WREQ_TRANSPORT_INVALID_ARGUMENT,
            };
            WebSocketCommand::Close {
                code: close_code,
                reason,
            }
        }
        _ => return WREQ_TRANSPORT_INVALID_ARGUMENT,
    };

    // SAFETY: see the shared handle lifetime contract in the C header.
    let transport = unsafe { &*transport };
    if transport.shutting_down.load(Ordering::Acquire) {
        return WREQ_TRANSPORT_SHUTTING_DOWN;
    }
    let control = lock_unpoisoned(&transport.controls)
        .get(&request_id)
        .cloned();
    let Some(control) = control else {
        return WREQ_TRANSPORT_NOT_FOUND;
    };
    if control.state.load(Ordering::Acquire) != STATE_STREAMING {
        return WREQ_TRANSPORT_INVALID_STATE;
    }
    let sender = lock_unpoisoned(&control.websocket_commands).clone();
    let Some(sender) = sender else {
        return WREQ_TRANSPORT_INVALID_STATE;
    };
    match sender.try_send(command) {
        Ok(()) => WREQ_TRANSPORT_OK,
        Err(tokio_mpsc::error::TrySendError::Full(_)) => WREQ_TRANSPORT_OVERFLOW,
        Err(tokio_mpsc::error::TrySendError::Closed(_)) => WREQ_TRANSPORT_NOT_FOUND,
    }
}

fn cancel_impl(transport: *mut WreqTransport, request_id: u64) -> i32 {
    if transport.is_null() || request_id == 0 {
        return WREQ_TRANSPORT_INVALID_ARGUMENT;
    }
    // SAFETY: see the handle lifetime contract documented in the C header.
    let transport = unsafe { &*transport };
    let control = lock_unpoisoned(&transport.controls)
        .get(&request_id)
        .cloned();
    let Some(control) = control else {
        return WREQ_TRANSPORT_NOT_FOUND;
    };
    if control.state.load(Ordering::Acquire) == STATE_TERMINAL {
        return WREQ_TRANSPORT_NOT_FOUND;
    }
    control.cancel.cancel();
    WREQ_TRANSPORT_OK
}

fn poll_event_impl(
    transport: *mut WreqTransport,
    timeout_ms: u32,
    out_event: *mut *mut WreqEvent,
) -> i32 {
    if transport.is_null() || out_event.is_null() {
        return WREQ_TRANSPORT_INVALID_ARGUMENT;
    }
    // SAFETY: the caller promises writable storage for one pointer.
    unsafe { ptr::write(out_event, ptr::null_mut()) };
    // SAFETY: see the handle lifetime contract documented in the C header.
    let transport = unsafe { &*transport };
    let receiver = lock_unpoisoned(&transport.events_rx);
    let message = if timeout_ms == 0 {
        match receiver.try_recv() {
            Ok(event) => event,
            Err(TryRecvError::Empty) => return WREQ_TRANSPORT_EMPTY,
            Err(TryRecvError::Disconnected) => return WREQ_TRANSPORT_SHUTTING_DOWN,
        }
    } else if timeout_ms == u32::MAX {
        match receiver.recv() {
            Ok(event) => event,
            Err(_) => return WREQ_TRANSPORT_SHUTTING_DOWN,
        }
    } else {
        match receiver.recv_timeout(Duration::from_millis(u64::from(timeout_ms))) {
            Ok(event) => event,
            Err(RecvTimeoutError::Timeout) => return WREQ_TRANSPORT_EMPTY,
            Err(RecvTimeoutError::Disconnected) => return WREQ_TRANSPORT_SHUTTING_DOWN,
        }
    };
    drop(receiver);

    let queued = match message {
        QueueMessage::Wake => {
            transport.wake_pending.store(false, Ordering::Release);
            return WREQ_TRANSPORT_EMPTY;
        }
        QueueMessage::Event(event) => event,
    };
    let allocation = Box::new(EventAllocation::new(queued.event, Some(queued.permit)));
    let raw = Box::into_raw(allocation);
    // EventAllocation is repr(C) and public is its first field, so both pointers
    // have the same address. event_free performs the inverse cast.
    // SAFETY: raw is a valid Box allocation and out_event is writable.
    unsafe { ptr::write(out_event, raw.cast::<WreqEvent>()) };
    WREQ_TRANSPORT_OK
}

fn wakeup_impl(transport: *mut WreqTransport) -> i32 {
    if transport.is_null() {
        return WREQ_TRANSPORT_INVALID_ARGUMENT;
    }
    // SAFETY: see the handle lifetime contract documented in the C header.
    let transport = unsafe { &*transport };
    if transport.shutting_down.load(Ordering::Acquire) {
        return WREQ_TRANSPORT_SHUTTING_DOWN;
    }

    if !transport.wake_pending.swap(true, Ordering::AcqRel)
        && transport.events_tx.send(QueueMessage::Wake).is_err()
    {
        transport.wake_pending.store(false, Ordering::Release);
        return WREQ_TRANSPORT_SHUTTING_DOWN;
    }
    WREQ_TRANSPORT_OK
}

fn headers_ack_impl(transport: *mut WreqTransport, request_id: u64) -> i32 {
    if transport.is_null() || request_id == 0 {
        return WREQ_TRANSPORT_INVALID_ARGUMENT;
    }
    // SAFETY: see the handle lifetime contract documented in the C header.
    let transport = unsafe { &*transport };
    let control = lock_unpoisoned(&transport.controls)
        .get(&request_id)
        .cloned();
    let Some(control) = control else {
        return WREQ_TRANSPORT_NOT_FOUND;
    };

    if control
        .state
        .compare_exchange(
            STATE_AWAITING_HEADERS_ACK,
            STATE_STREAMING,
            Ordering::AcqRel,
            Ordering::Acquire,
        )
        .is_err()
    {
        return WREQ_TRANSPORT_INVALID_STATE;
    }

    let sender = lock_unpoisoned(&control.headers_ack).take();
    let Some(sender) = sender else {
        return WREQ_TRANSPORT_INVALID_STATE;
    };
    if sender.send(()).is_err() {
        return WREQ_TRANSPORT_INVALID_STATE;
    }
    WREQ_TRANSPORT_OK
}

#[no_mangle]
pub extern "C" fn wreq_transport_create(out_transport: *mut *mut WreqTransport) -> i32 {
    ffi_status(|| create_impl(CreateConfig::default(), out_transport))
}

#[no_mangle]
// The C ABI cannot express Rust's `unsafe fn` contract to callers. This entry
// point validates alignment/nullability before touching caller-owned memory.
#[allow(clippy::not_unsafe_ptr_arg_deref)]
pub extern "C" fn wreq_transport_create_with_options(
    options: *const WreqTransportOptions,
    out_transport: *mut *mut WreqTransport,
) -> i32 {
    ffi_status(|| {
        if options.is_null()
            || out_transport.is_null()
            || (options as usize) % align_of::<WreqTransportOptions>() != 0
        {
            return WREQ_TRANSPORT_INVALID_ARGUMENT;
        }
        // SAFETY: the caller promises writable storage for one pointer.
        unsafe { ptr::write(out_transport, ptr::null_mut()) };
        // Read only the fixed header before trusting struct_size. ABI v5
        // requires the complete 64-byte options structure and rejects legacy
        // v4 callers before reading beyond their declared extent.
        let raw_header = unsafe { ptr::read(options.cast::<WreqTransportOptionsHeader>()) };
        if raw_header.struct_size < size_of::<WreqTransportOptions>() as u32
            || raw_header.abi_version != WREQ_TRANSPORT_ABI_VERSION
        {
            return WREQ_TRANSPORT_INVALID_ARGUMENT;
        }
        // SAFETY: struct_size declares the full v5 structure readable and the
        // caller contract requires the declared extent to remain valid here.
        let raw_options = unsafe { ptr::read(options) };
        // SAFETY: all nested byte views are validated and copied before this
        // call returns.
        let config = match unsafe { copy_create_options(raw_options) } {
            Ok(config) => config,
            Err(status) => return status,
        };
        create_impl(config, out_transport)
    })
}

#[no_mangle]
// Ownership transfer is documented by the C ABI; NULL remains a no-op.
#[allow(clippy::not_unsafe_ptr_arg_deref)]
pub extern "C" fn wreq_transport_free(transport: *mut WreqTransport) {
    ffi_void(|| {
        if !transport.is_null() {
            // SAFETY: the caller transfers its unique allocation back exactly
            // once and does not race this call with other handle operations.
            unsafe { drop(Box::from_raw(transport)) };
        }
    });
}

#[no_mangle]
pub extern "C" fn wreq_transport_submit(
    transport: *mut WreqTransport,
    request: *const WreqRequest,
    out_request_id: *mut u64,
) -> i32 {
    ffi_status(|| submit_impl(transport, request, out_request_id))
}

#[no_mangle]
pub extern "C" fn wreq_transport_websocket_submit(
    transport: *mut WreqTransport,
    request: *const WreqRequest,
    out_request_id: *mut u64,
) -> i32 {
    ffi_status(|| websocket_submit_impl(transport, request, out_request_id))
}

#[no_mangle]
pub extern "C" fn wreq_transport_websocket_send(
    transport: *mut WreqTransport,
    request_id: u64,
    message_type: u32,
    data: WreqSlice,
    close_code: u16,
) -> i32 {
    ffi_status(|| websocket_send_impl(transport, request_id, message_type, data, close_code))
}

#[no_mangle]
pub extern "C" fn wreq_transport_websocket_cancel(
    transport: *mut WreqTransport,
    request_id: u64,
) -> i32 {
    ffi_status(|| cancel_impl(transport, request_id))
}

#[no_mangle]
pub extern "C" fn wreq_transport_cancel(transport: *mut WreqTransport, request_id: u64) -> i32 {
    ffi_status(|| cancel_impl(transport, request_id))
}

#[no_mangle]
pub extern "C" fn wreq_transport_poll_event(
    transport: *mut WreqTransport,
    timeout_ms: u32,
    out_event: *mut *mut WreqEvent,
) -> i32 {
    ffi_status(|| poll_event_impl(transport, timeout_ms, out_event))
}

#[no_mangle]
pub extern "C" fn wreq_transport_wakeup(transport: *mut WreqTransport) -> i32 {
    ffi_status(|| wakeup_impl(transport))
}

#[no_mangle]
pub extern "C" fn wreq_transport_headers_ack(
    transport: *mut WreqTransport,
    request_id: u64,
) -> i32 {
    ffi_status(|| headers_ack_impl(transport, request_id))
}

#[no_mangle]
pub extern "C" fn wreq_transport_event_free(event: *mut WreqEvent) {
    ffi_void(|| {
        if !event.is_null() {
            // SAFETY: EventAllocation is repr(C), WreqEvent is its first field,
            // and poll_event returns this exact allocation address.
            unsafe { drop(Box::from_raw(event.cast::<EventAllocation>())) };
        }
    });
}

#[no_mangle]
pub extern "C" fn wreq_transport_version() -> *const c_char {
    catch_unwind(AssertUnwindSafe(|| {
        VERSION_STRING.as_ptr().cast::<c_char>()
    }))
    .unwrap_or(ptr::null())
}

#[no_mangle]
pub extern "C" fn wreq_transport_abi_version() -> u32 {
    catch_unwind(AssertUnwindSafe(|| WREQ_TRANSPORT_ABI_VERSION)).unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::{Ipv4Addr, Ipv6Addr, TcpListener};
    use std::sync::atomic::AtomicUsize;
    use std::thread;
    use std::time::Instant;

    #[test]
    fn trust_anchor_ids_are_scoped_to_chrome149() {
        let chrome149 = emulation_for_profile(Profile::Chrome149).expect("Chrome149 emulation");
        let chrome149_tls = chrome149.tls_options.expect("Chrome149 TLS options");
        assert_eq!(
            chrome149_tls.requested_trust_anchors.as_deref(),
            Some([].as_slice())
        );

        let chrome124 = emulation_for_profile(Profile::Chrome124).expect("Chrome124 emulation");
        let chrome124_tls = chrome124.tls_options.expect("Chrome124 TLS options");
        assert!(chrome124_tls.requested_trust_anchors.is_none());
    }

    #[derive(Clone)]
    struct CountingResolver {
        calls: Arc<AtomicUsize>,
        addresses: Vec<SocketAddr>,
    }

    impl Resolve for CountingResolver {
        fn resolve(&self, _: Name) -> Resolving {
            self.calls.fetch_add(1, Ordering::Relaxed);
            let addresses = self.addresses.clone();
            Box::pin(async move { Ok(Box::new(addresses.into_iter()) as Addrs) })
        }
    }

    #[derive(Clone)]
    struct RejectingResolver;

    impl Resolve for RejectingResolver {
        fn resolve(&self, name: Name) -> Resolving {
            panic!("localhost resolution unexpectedly delegated for {name}")
        }
    }

    fn view(bytes: &[u8]) -> WreqSlice {
        WreqSlice {
            ptr: bytes.as_ptr(),
            len: bytes.len(),
        }
    }

    #[test]
    #[cfg(target_pointer_width = "64")]
    fn windows_x64_abi_layout_is_stable() {
        assert_eq!(size_of::<WreqSlice>(), 16);
        assert_eq!(size_of::<WreqHeader>(), 32);
        assert_eq!(size_of::<WreqTransportOptionsHeader>(), 8);
        assert_eq!(size_of::<WreqTransportOptions>(), 64);
        assert_eq!(std::mem::offset_of!(WreqTransportOptions, proxy_url), 16);
        assert_eq!(std::mem::offset_of!(WreqTransportOptions, profile_id), 36);
        assert_eq!(
            std::mem::offset_of!(WreqTransportOptions, dns_nameservers),
            48
        );
        assert_eq!(size_of::<WreqRequest>(), 104);
        assert_eq!(std::mem::offset_of!(WreqRequest, method), 8);
        assert_eq!(std::mem::offset_of!(WreqRequest, body), 56);
        assert_eq!(std::mem::offset_of!(WreqRequest, timeout_ms), 72);
        assert_eq!(std::mem::offset_of!(WreqRequest, proxy_url), 88);
        assert_eq!(size_of::<WreqEvent>(), 72);
        assert_eq!(std::mem::offset_of!(WreqEvent, encoded_body_size), 24);
        assert_eq!(std::mem::offset_of!(WreqEvent, decoded_body_size), 32);
        assert_eq!(std::mem::offset_of!(WreqEvent, headers), 40);
        assert_eq!(std::mem::offset_of!(WreqEvent, data), 56);
    }

    #[test]
    fn pre_v5_inputs_fail_closed() {
        let options = WreqTransportOptions {
            struct_size: size_of::<WreqTransportOptions>() as u32,
            abi_version: 4,
            flags: 0,
            proxy_url: WreqSlice::empty(),
            event_capacity: 1,
            profile_id: WREQ_TRANSPORT_PROFILE_CHROME_149,
            reserved32: 0,
            dns_nameservers: WreqSlice::empty(),
        };
        let mut transport = ptr::null_mut();
        assert_eq!(
            wreq_transport_create_with_options(&options, &mut transport),
            WREQ_TRANSPORT_INVALID_ARGUMENT
        );
        assert!(transport.is_null());

        let request = WreqRequest {
            struct_size: size_of::<WreqRequest>() as u32,
            abi_version: 4,
            method: view(b"GET"),
            url: view(b"https://example.test/"),
            headers: ptr::null(),
            header_count: 0,
            body: WreqSlice::empty(),
            timeout_ms: 0,
            flags: 0,
            proxy_url: WreqSlice::empty(),
        };
        // SAFETY: all views are valid for this synchronous rejection path.
        assert_eq!(
            unsafe { copy_request(request) }.err(),
            Some(WREQ_TRANSPORT_INVALID_ARGUMENT)
        );
    }

    #[test]
    fn custom_dns_parser_defaults_ports_and_deduplicates_stably() {
        let parsed = parse_dns_nameservers(b"1.1.1.1\n[2606:4700:4700::1111]:5353\n1.1.1.1\n::1")
            .expect("valid nameserver list");
        assert_eq!(
            parsed,
            vec![
                "1.1.1.1:53".parse().unwrap(),
                "[2606:4700:4700::1111]:5353".parse().unwrap(),
                "[::1]:53".parse().unwrap(),
            ]
        );
        assert_eq!(
            parse_dns_nameservers(b"1.1.1.1,[::1]:5353").unwrap(),
            vec!["1.1.1.1:53".parse().unwrap(), "[::1]:5353".parse().unwrap(),],
            "comma remains a compatibility separator"
        );
        assert_eq!(
            parse_dns_nameservers(b"1.1.1.1\r\n[::1]:5353").unwrap(),
            vec!["1.1.1.1:53".parse().unwrap(), "[::1]:5353".parse().unwrap(),],
            "CR is accepted only as part of CRLF"
        );

        for invalid in [
            "",
            "1.1.1.1,",
            "1.1.1.1\r[::1]",
            "resolver.example",
            "127.0.0.1:0",
            "[::1]:0",
            "1.1.1.1,2.2.2.2,3.3.3.3,4.4.4.4,5.5.5.5,6.6.6.6,7.7.7.7,8.8.8.8,9.9.9.9",
        ] {
            assert_eq!(
                parse_dns_nameservers(invalid.as_bytes()).err(),
                Some(WREQ_TRANSPORT_INVALID_ARGUMENT),
                "input={invalid:?}"
            );
        }
    }

    #[test]
    fn truncated_v5_options_fail_without_reading_a_tail() {
        let header = WreqTransportOptionsHeader {
            struct_size: 48,
            abi_version: WREQ_TRANSPORT_ABI_VERSION,
        };
        let mut transport = ptr::null_mut();
        assert_eq!(
            wreq_transport_create_with_options(
                (&header as *const WreqTransportOptionsHeader).cast(),
                &mut transport,
            ),
            WREQ_TRANSPORT_INVALID_ARGUMENT
        );
        assert!(transport.is_null());
    }

    #[test]
    fn custom_dns_flag_and_nonempty_view_must_match() {
        let nameservers = b"1.1.1.1";
        let base = WreqTransportOptions {
            struct_size: size_of::<WreqTransportOptions>() as u32,
            abi_version: WREQ_TRANSPORT_ABI_VERSION,
            flags: 0,
            proxy_url: WreqSlice::empty(),
            event_capacity: 1,
            profile_id: WREQ_TRANSPORT_PROFILE_CHROME_149,
            reserved32: 0,
            dns_nameservers: view(nameservers),
        };
        assert_eq!(
            unsafe { copy_create_options(base) }.err(),
            Some(WREQ_TRANSPORT_INVALID_ARGUMENT)
        );
        assert_eq!(
            unsafe {
                copy_create_options(WreqTransportOptions {
                    flags: WREQ_TRANSPORT_OPTION_CUSTOM_DNS,
                    dns_nameservers: WreqSlice::empty(),
                    ..base
                })
            }
            .err(),
            Some(WREQ_TRANSPORT_INVALID_ARGUMENT)
        );
        let config = unsafe {
            copy_create_options(WreqTransportOptions {
                flags: WREQ_TRANSPORT_OPTION_CUSTOM_DNS,
                ..base
            })
        }
        .expect("matching flag and view");
        assert_eq!(
            config.dns_nameservers,
            Some(vec!["1.1.1.1:53".parse().unwrap()])
        );
    }

    #[test]
    fn custom_dns_extended_options_build_a_transport_without_a_lookup() {
        let nameservers = b"127.0.0.1:5353\n[::1]:5353";
        let options = WreqTransportOptions {
            struct_size: size_of::<WreqTransportOptions>() as u32,
            abi_version: WREQ_TRANSPORT_ABI_VERSION,
            flags: WREQ_TRANSPORT_OPTION_CUSTOM_DNS,
            proxy_url: WreqSlice::empty(),
            event_capacity: 1,
            profile_id: WREQ_TRANSPORT_PROFILE_CHROME_149,
            reserved32: 0,
            dns_nameservers: view(nameservers),
        };
        let mut transport = ptr::null_mut();
        assert_eq!(
            wreq_transport_create_with_options(&options, &mut transport),
            WREQ_TRANSPORT_OK
        );
        assert!(!transport.is_null());
        wreq_transport_free(transport);
    }

    #[test]
    fn localhost_resolver_maps_bare_subdomain_case_and_trailing_dot() {
        let resolver = LocalhostResolver {
            inner: Arc::new(RejectingResolver),
        };
        let runtime = Runtime::new().expect("test runtime");
        let expected = vec![
            SocketAddr::from((Ipv6Addr::LOCALHOST, 0)),
            SocketAddr::from((Ipv4Addr::LOCALHOST, 0)),
        ];

        for name in [
            "localhost",
            "a.localhost",
            "A.DP.LOCALHOST",
            "localhost.",
            "b.cross.localhost.",
        ] {
            let addresses = runtime
                .block_on(resolver.resolve(Name::from(name)))
                .expect("localhost maps without external DNS")
                .collect::<Vec<_>>();
            assert_eq!(addresses, expected, "name={name}");
        }
    }

    #[test]
    fn localhost_resolver_delegates_non_localhost_names() {
        let calls = Arc::new(AtomicUsize::new(0));
        let public = SocketAddr::from((Ipv4Addr::new(8, 8, 8, 8), 0));
        let resolver = LocalhostResolver {
            inner: Arc::new(CountingResolver {
                calls: Arc::clone(&calls),
                addresses: vec![public],
            }),
        };
        let runtime = Runtime::new().expect("test runtime");

        for name in ["example.test", "localhost.example", "evil-localhost"] {
            let addresses = runtime
                .block_on(resolver.resolve(Name::from(name)))
                .expect("non-localhost delegated")
                .collect::<Vec<_>>();
            assert_eq!(addresses, vec![public]);
        }
        assert_eq!(calls.load(Ordering::Relaxed), 3);
    }

    #[test]
    fn request_options_copy_proxy_tls_and_redirect_state() {
        let proxy = b"http://127.0.0.1:8080";
        let input = WreqRequest {
            struct_size: size_of::<WreqRequest>() as u32,
            abi_version: WREQ_TRANSPORT_ABI_VERSION,
            method: view(b"GET"),
            url: view(b"https://example.test/"),
            headers: ptr::null(),
            header_count: 0,
            body: WreqSlice::empty(),
            timeout_ms: 0,
            flags: WREQ_REQUEST_OPTION_CONFIG_OVERRIDE
                | WREQ_REQUEST_OPTION_INSECURE_SKIP_TLS_VERIFY
                | WREQ_REQUEST_OPTION_FOLLOW_REDIRECTS,
            proxy_url: view(proxy),
        };
        // SAFETY: all byte views above remain live for the synchronous copy.
        let copied = unsafe { copy_request(input) }.expect("valid override request");
        assert_eq!(
            copied.client_override,
            Some(ClientKey {
                verify_tls: false,
                proxy_url: Some("http://127.0.0.1:8080".to_owned()),
            })
        );
        assert!(copied.follow_redirects);
    }

    #[test]
    fn submit_copy_preserves_flat_duplicate_order_and_ownership() {
        let method = b"POST".to_vec();
        let url = b"https://example.test/path".to_vec();
        let mut first_name = b"X-First".to_vec();
        let mut middle_name = b"X-Middle".to_vec();
        let mut first_value = b"one".to_vec();
        let middle_value = b"middle".to_vec();
        let last_value = b"two".to_vec();
        let mut body = b"payload".to_vec();
        let headers = [
            WreqHeader {
                name: view(&first_name),
                value: view(&first_value),
            },
            WreqHeader {
                name: view(&middle_name),
                value: view(&middle_value),
            },
            WreqHeader {
                name: view(&first_name),
                value: view(&last_value),
            },
        ];
        let input = WreqRequest {
            struct_size: size_of::<WreqRequest>() as u32,
            abi_version: WREQ_TRANSPORT_ABI_VERSION,
            method: view(&method),
            url: view(&url),
            headers: headers.as_ptr(),
            header_count: headers.len(),
            body: view(&body),
            timeout_ms: 0,
            flags: 0,
            proxy_url: WreqSlice::empty(),
        };

        // SAFETY: every view above is valid for this synchronous copy.
        let copied = unsafe { copy_request(input) }.expect("valid request");
        first_name.fill(b'z');
        middle_name.fill(b'z');
        first_value.fill(b'z');
        body.fill(b'z');

        assert_eq!(copied.method, Method::POST);
        assert_eq!(copied.uri.to_string(), "https://example.test/path");
        assert_eq!(
            copied
                .headers
                .iter()
                .map(|header| (header.original_name.as_str(), header.value.as_bytes()))
                .collect::<Vec<_>>(),
            vec![
                ("X-First", b"one".as_slice()),
                ("X-Middle", b"middle".as_slice()),
                ("X-First", b"two".as_slice()),
            ]
        );
        assert_eq!(copied.body, b"payload");
    }

    #[test]
    fn null_and_non_empty_views_are_rejected() {
        let input = WreqRequest {
            struct_size: size_of::<WreqRequest>() as u32,
            abi_version: WREQ_TRANSPORT_ABI_VERSION,
            method: WreqSlice {
                ptr: ptr::null(),
                len: 3,
            },
            url: WreqSlice::empty(),
            headers: ptr::null(),
            header_count: 0,
            body: WreqSlice::empty(),
            timeout_ms: 0,
            flags: 0,
            proxy_url: WreqSlice::empty(),
        };
        // SAFETY: copy_request validates the invalid raw views without reading.
        assert_eq!(
            unsafe { copy_request(input) }.err(),
            Some(WREQ_TRANSPORT_INVALID_ARGUMENT)
        );
        assert_eq!(
            wreq_transport_create(ptr::null_mut()),
            WREQ_TRANSPORT_INVALID_ARGUMENT
        );
    }

    #[test]
    fn event_allocation_owns_all_views() {
        let event = InternalEvent {
            kind: WREQ_EVENT_HEADERS,
            http_version: 11,
            request_id: 7,
            status_code: 204,
            encoded_body_size: 123,
            decoded_body_size: 456,
            headers: vec![OwnedHeaderBytes {
                name: Box::from(&b"x-test"[..]),
                value: Box::from(&b"yes"[..]),
            }],
            data: b"owned".to_vec(),
        };
        let raw = Box::into_raw(Box::new(EventAllocation::new(event, None))).cast::<WreqEvent>();
        // SAFETY: raw points to the first field of a live EventAllocation.
        unsafe {
            assert_eq!((*raw).request_id, 7);
            assert_eq!((*raw).encoded_body_size, 123);
            assert_eq!((*raw).decoded_body_size, 456);
            let header = &*(*raw).headers;
            assert_eq!(
                slice::from_raw_parts(header.name.ptr, header.name.len),
                b"x-test"
            );
            assert_eq!(
                slice::from_raw_parts(header.value.ptr, header.value.len),
                b"yes"
            );
            assert_eq!(
                slice::from_raw_parts((*raw).data.ptr, (*raw).data.len),
                b"owned"
            );
        }
        wreq_transport_event_free(raw);
        wreq_transport_event_free(ptr::null_mut());
    }

    #[test]
    fn wakeup_interrupts_a_blocking_poll_without_an_event() {
        let mut transport = ptr::null_mut();
        assert_eq!(wreq_transport_create(&mut transport), WREQ_TRANSPORT_OK);
        let handle = transport as usize;
        let waking_thread = thread::spawn(move || {
            thread::sleep(Duration::from_millis(50));
            assert_eq!(
                wreq_transport_wakeup(handle as *mut WreqTransport),
                WREQ_TRANSPORT_OK
            );
        });

        let started = Instant::now();
        let mut event = ptr::null_mut();
        assert_eq!(
            wreq_transport_poll_event(transport, 5_000, &mut event),
            WREQ_TRANSPORT_EMPTY
        );
        assert!(event.is_null());
        assert!(started.elapsed() < Duration::from_secs(2));

        waking_thread.join().expect("waking thread");
        wreq_transport_free(transport);
    }

    #[test]
    fn headers_ack_gates_data_events() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind test server");
        let address = listener.local_addr().expect("test server address");
        let server = thread::spawn(move || {
            let (mut socket, _) = listener.accept().expect("accept request");
            socket
                .set_read_timeout(Some(Duration::from_secs(5)))
                .expect("set timeout");
            let mut request = Vec::new();
            let mut buffer = [0_u8; 1024];
            while !request.windows(4).any(|window| window == b"\r\n\r\n") {
                let read = socket.read(&mut buffer).expect("read request");
                if read == 0 {
                    break;
                }
                request.extend_from_slice(&buffer[..read]);
            }
            socket
                .write_all(
                    b"HTTP/1.1 200 OK\r\nContent-Length: 11\r\nX-Test: yes\r\nConnection: close\r\n\r\nhello world",
                )
                .expect("write response");
        });

        let options = WreqTransportOptions {
            struct_size: size_of::<WreqTransportOptions>() as u32,
            abi_version: WREQ_TRANSPORT_ABI_VERSION,
            flags: 0,
            proxy_url: WreqSlice::empty(),
            event_capacity: 1,
            profile_id: WREQ_TRANSPORT_PROFILE_CHROME_149,
            reserved32: 0,
            dns_nameservers: WreqSlice::empty(),
        };
        let mut transport = ptr::null_mut();
        assert_eq!(
            wreq_transport_create_with_options(&options, &mut transport),
            WREQ_TRANSPORT_OK
        );
        assert!(!transport.is_null());

        let method = b"GET";
        let url = format!("http://{address}/gated").into_bytes();
        let request = WreqRequest {
            struct_size: size_of::<WreqRequest>() as u32,
            abi_version: WREQ_TRANSPORT_ABI_VERSION,
            method: view(method),
            url: view(&url),
            headers: ptr::null(),
            header_count: 0,
            body: WreqSlice::empty(),
            timeout_ms: 5_000,
            flags: 0,
            proxy_url: WreqSlice::empty(),
        };
        let mut request_id = 0;
        assert_eq!(
            wreq_transport_submit(transport, &request, &mut request_id),
            WREQ_TRANSPORT_OK
        );
        assert_ne!(request_id, 0);
        assert_eq!(wreq_transport_wakeup(transport), WREQ_TRANSPORT_OK);

        let mut event = ptr::null_mut();
        loop {
            let status = wreq_transport_poll_event(transport, 5_000, &mut event);
            if status == WREQ_TRANSPORT_EMPTY {
                continue;
            }
            assert_eq!(status, WREQ_TRANSPORT_OK);
            break;
        }
        assert!(!event.is_null());
        // SAFETY: event remains live until event_free below.
        unsafe {
            assert_eq!((*event).kind, WREQ_EVENT_HEADERS);
            assert_eq!((*event).request_id, request_id);
            assert_eq!((*event).status_code, 200);
        }
        let headers_event = event;

        event = ptr::null_mut();
        assert_eq!(
            wreq_transport_poll_event(transport, 100, &mut event),
            WREQ_TRANSPORT_EMPTY
        );
        assert!(event.is_null());
        assert_eq!(
            wreq_transport_headers_ack(transport, request_id),
            WREQ_TRANSPORT_OK
        );

        // Capacity is one and the HEADERS event still owns that permit. Even
        // after ACK, DATA cannot enter the queue until event_free releases it.
        assert_eq!(
            wreq_transport_poll_event(transport, 100, &mut event),
            WREQ_TRANSPORT_EMPTY
        );
        assert!(event.is_null());
        wreq_transport_event_free(headers_event);

        let mut body = Vec::new();
        let mut encoded_body_size = 0;
        let mut decoded_body_size = 0;
        loop {
            event = ptr::null_mut();
            assert_eq!(
                wreq_transport_poll_event(transport, 5_000, &mut event),
                WREQ_TRANSPORT_OK
            );
            // SAFETY: event remains live until event_free below.
            let kind = unsafe { (*event).kind };
            if kind == WREQ_EVENT_DATA {
                // SAFETY: DATA's byte view is owned by the live event.
                unsafe {
                    body.extend_from_slice(slice::from_raw_parts(
                        (*event).data.ptr,
                        (*event).data.len,
                    ));
                }
            }
            if kind == WREQ_EVENT_DONE {
                // SAFETY: the event remains live until event_free below.
                unsafe {
                    encoded_body_size = (*event).encoded_body_size;
                    decoded_body_size = (*event).decoded_body_size;
                }
            }
            wreq_transport_event_free(event);
            if kind == WREQ_EVENT_DONE {
                break;
            }
            assert_ne!(kind, WREQ_EVENT_ERROR);
            assert_ne!(kind, WREQ_EVENT_CANCELLED);
        }
        assert_eq!(body, b"hello world");
        assert_eq!(encoded_body_size, 11);
        assert_eq!(decoded_body_size, 11);

        wreq_transport_free(transport);
        server.join().expect("server thread");
    }

    #[test]
    fn resource_timing_counts_chunked_gzip_before_and_after_decoding() {
        const GZIP_BODY: &[u8] = &[
            0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0xff, 0xed, 0xc3, 0x01, 0x0d,
            0x00, 0x00, 0x08, 0x03, 0xa0, 0xac, 0xd7, 0xf7, 0xcf, 0x60, 0x0f, 0x07, 0x1b, 0x99,
            0x6d, 0x54, 0x55, 0x55, 0xd5, 0xd7, 0x0f, 0xaf, 0x7e, 0x59, 0xcb, 0x00, 0x10, 0x00,
            0x00,
        ];

        let listener = TcpListener::bind("127.0.0.1:0").expect("bind test server");
        let address = listener.local_addr().expect("test server address");
        let server = thread::spawn(move || {
            let (mut socket, _) = listener.accept().expect("accept request");
            socket
                .set_read_timeout(Some(Duration::from_secs(5)))
                .expect("set timeout");
            let mut request = Vec::new();
            let mut buffer = [0_u8; 1024];
            while !request.windows(4).any(|window| window == b"\r\n\r\n") {
                let read = socket.read(&mut buffer).expect("read request");
                if read == 0 {
                    break;
                }
                request.extend_from_slice(&buffer[..read]);
            }

            socket
                .write_all(
                    b"HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n2b\r\n",
                )
                .expect("write response headers");
            socket.write_all(GZIP_BODY).expect("write gzip body");
            socket
                .write_all(b"\r\n0\r\n\r\n")
                .expect("finish chunked response");
        });

        let options = WreqTransportOptions {
            struct_size: size_of::<WreqTransportOptions>() as u32,
            abi_version: WREQ_TRANSPORT_ABI_VERSION,
            flags: 0,
            proxy_url: WreqSlice::empty(),
            event_capacity: 16,
            profile_id: WREQ_TRANSPORT_PROFILE_CHROME_149,
            reserved32: 0,
            dns_nameservers: WreqSlice::empty(),
        };
        let mut transport = ptr::null_mut();
        assert_eq!(
            wreq_transport_create_with_options(&options, &mut transport),
            WREQ_TRANSPORT_OK
        );

        let method = b"GET";
        let url = format!("http://{address}/chunked-gzip").into_bytes();
        let request = WreqRequest {
            struct_size: size_of::<WreqRequest>() as u32,
            abi_version: WREQ_TRANSPORT_ABI_VERSION,
            method: view(method),
            url: view(&url),
            headers: ptr::null(),
            header_count: 0,
            body: WreqSlice::empty(),
            timeout_ms: 5_000,
            flags: 0,
            proxy_url: WreqSlice::empty(),
        };
        let mut request_id = 0;
        assert_eq!(
            wreq_transport_submit(transport, &request, &mut request_id),
            WREQ_TRANSPORT_OK
        );

        let mut decoded = Vec::new();
        let mut encoded_body_size = None;
        let mut decoded_body_size = None;
        loop {
            let mut event = ptr::null_mut();
            let status = wreq_transport_poll_event(transport, 5_000, &mut event);
            if status == WREQ_TRANSPORT_EMPTY {
                continue;
            }
            assert_eq!(status, WREQ_TRANSPORT_OK);
            assert!(!event.is_null());
            // SAFETY: the event and all of its views remain live until the
            // event_free call at the end of this iteration.
            let kind = unsafe { (*event).kind };
            if kind == WREQ_EVENT_HEADERS {
                let headers =
                    unsafe { slice::from_raw_parts((*event).headers, (*event).header_count) };
                assert!(headers.iter().any(|header| {
                    unsafe { slice::from_raw_parts(header.name.ptr, header.name.len) }
                        .eq_ignore_ascii_case(b"content-encoding")
                        && unsafe { slice::from_raw_parts(header.value.ptr, header.value.len) }
                            == b"gzip"
                }));
                assert_eq!(
                    wreq_transport_headers_ack(transport, request_id),
                    WREQ_TRANSPORT_OK
                );
            } else if kind == WREQ_EVENT_DATA {
                unsafe {
                    decoded.extend_from_slice(slice::from_raw_parts(
                        (*event).data.ptr,
                        (*event).data.len,
                    ));
                }
            } else if kind == WREQ_EVENT_DONE {
                unsafe {
                    encoded_body_size = Some((*event).encoded_body_size);
                    decoded_body_size = Some((*event).decoded_body_size);
                }
            }
            wreq_transport_event_free(event);
            if kind == WREQ_EVENT_DONE {
                break;
            }
            assert_ne!(kind, WREQ_EVENT_ERROR);
            assert_ne!(kind, WREQ_EVENT_CANCELLED);
        }

        assert_eq!(decoded, b"abcd".repeat(1024));
        assert_eq!(encoded_body_size, Some(GZIP_BODY.len() as u64));
        assert_eq!(decoded_body_size, Some(decoded.len() as u64));

        wreq_transport_free(transport);
        server.join().expect("server thread");
    }

    #[test]
    fn websocket_c_abi_loopback_open_text_and_clean_close() {
        use futures_util::{SinkExt, StreamExt};
        use tokio_tungstenite::tungstenite::{
            handshake::server::{Request as ServerRequest, Response as ServerResponse},
            Message as ServerMessage,
        };

        let listener = TcpListener::bind("127.0.0.1:0").expect("bind websocket server");
        listener
            .set_nonblocking(true)
            .expect("nonblocking websocket listener");
        let address = listener.local_addr().expect("websocket server address");
        let server = thread::spawn(move || {
            let runtime = Runtime::new().expect("websocket server runtime");
            runtime.block_on(async move {
                let listener =
                    tokio::net::TcpListener::from_std(listener).expect("tokio websocket listener");
                let (stream, _) = listener.accept().await.expect("accept websocket");
                let mut websocket = tokio_tungstenite::accept_hdr_async(
                    stream,
                    |request: &ServerRequest, mut response: ServerResponse| {
                        assert_eq!(
                            request
                                .headers()
                                .get("origin")
                                .and_then(|v| v.to_str().ok()),
                            Some("null")
                        );
                        assert_eq!(
                            request
                                .headers()
                                .get("cookie")
                                .and_then(|v| v.to_str().ok()),
                            Some("ws_token=loopback")
                        );
                        assert_eq!(
                            request
                                .headers()
                                .get("sec-websocket-protocol")
                                .and_then(|v| v.to_str().ok()),
                            Some("chat, superchat")
                        );
                        response.headers_mut().insert(
                            "sec-websocket-protocol",
                            "chat".parse().expect("protocol header"),
                        );
                        Ok(response)
                    },
                )
                .await
                .expect("websocket handshake");

                assert_eq!(
                    websocket
                        .next()
                        .await
                        .expect("client text")
                        .expect("valid text"),
                    ServerMessage::Text("hello".into())
                );
                websocket
                    .send(ServerMessage::Text("echo-hello".into()))
                    .await
                    .expect("send echo");
                let close = websocket
                    .next()
                    .await
                    .expect("client close")
                    .expect("valid close");
                let ServerMessage::Close(frame) = close else {
                    panic!("expected close frame, got {close:?}");
                };
                let frame = frame.expect("close payload");
                assert_eq!(u16::from(frame.code), 1000);
                assert_eq!(frame.reason, "bye");
                // tungstenite automatically queues the reciprocal close frame
                // when recv observes the peer close; flush it without trying
                // to enqueue a second close after the state became Closing.
                websocket.flush().await.expect("flush reciprocal close");
            });
        });

        let options = WreqTransportOptions {
            struct_size: size_of::<WreqTransportOptions>() as u32,
            abi_version: WREQ_TRANSPORT_ABI_VERSION,
            flags: WREQ_TRANSPORT_OPTION_INSECURE_SKIP_TLS_VERIFY,
            proxy_url: WreqSlice::empty(),
            event_capacity: 16,
            profile_id: WREQ_TRANSPORT_PROFILE_CHROME_149,
            reserved32: 0,
            dns_nameservers: WreqSlice::empty(),
        };
        let mut transport = ptr::null_mut();
        assert_eq!(
            wreq_transport_create_with_options(&options, &mut transport),
            WREQ_TRANSPORT_OK
        );

        let method = b"GET";
        let url = format!("ws://{address}/socket").into_bytes();
        let header_names = [b"Origin".as_slice(), b"Cookie", b"Sec-WebSocket-Protocol"];
        let header_values = [b"null".as_slice(), b"ws_token=loopback", b"chat, superchat"];
        let headers = [
            WreqHeader {
                name: view(header_names[0]),
                value: view(header_values[0]),
            },
            WreqHeader {
                name: view(header_names[1]),
                value: view(header_values[1]),
            },
            WreqHeader {
                name: view(header_names[2]),
                value: view(header_values[2]),
            },
        ];
        let request = WreqRequest {
            struct_size: size_of::<WreqRequest>() as u32,
            abi_version: WREQ_TRANSPORT_ABI_VERSION,
            method: view(method),
            url: view(&url),
            headers: headers.as_ptr(),
            header_count: headers.len(),
            body: WreqSlice::empty(),
            timeout_ms: 5_000,
            flags: WREQ_REQUEST_OPTION_CONFIG_OVERRIDE
                | WREQ_REQUEST_OPTION_INSECURE_SKIP_TLS_VERIFY,
            proxy_url: WreqSlice::empty(),
        };
        let mut request_id = 0;
        assert_eq!(
            wreq_transport_websocket_submit(transport, &request, &mut request_id),
            WREQ_TRANSPORT_OK
        );
        assert_ne!(request_id, 0);

        let poll = |expected_kind: u32| -> *mut WreqEvent {
            loop {
                let mut event = ptr::null_mut();
                let status = wreq_transport_poll_event(transport, 5_000, &mut event);
                if status == WREQ_TRANSPORT_EMPTY {
                    continue;
                }
                assert_eq!(status, WREQ_TRANSPORT_OK);
                assert!(!event.is_null());
                // SAFETY: the returned event remains owned until event_free.
                unsafe {
                    assert_eq!((*event).request_id, request_id);
                    assert_eq!((*event).kind, expected_kind);
                }
                return event;
            }
        };

        let open = poll(WREQ_EVENT_WEBSOCKET_OPEN);
        // SAFETY: OPEN remains live until the matching event_free below.
        unsafe {
            assert_eq!((*open).status_code, 101);
            let response_headers = slice::from_raw_parts((*open).headers, (*open).header_count);
            assert!(response_headers.iter().any(|header| {
                slice::from_raw_parts(header.name.ptr, header.name.len)
                    .eq_ignore_ascii_case(b"sec-websocket-protocol")
                    && slice::from_raw_parts(header.value.ptr, header.value.len) == b"chat"
            }));
        }
        wreq_transport_event_free(open);

        assert_eq!(
            wreq_transport_websocket_send(
                transport,
                request_id,
                WREQ_WEBSOCKET_SEND_TEXT,
                view(b"hello"),
                0,
            ),
            WREQ_TRANSPORT_OK
        );
        let text = poll(WREQ_EVENT_WEBSOCKET_TEXT);
        // SAFETY: TEXT remains live until event_free.
        unsafe {
            assert_eq!(
                slice::from_raw_parts((*text).data.ptr, (*text).data.len),
                b"echo-hello"
            );
        }
        wreq_transport_event_free(text);

        assert_eq!(
            wreq_transport_websocket_send(
                transport,
                request_id,
                WREQ_WEBSOCKET_SEND_CLOSE,
                view(b"bye"),
                1000,
            ),
            WREQ_TRANSPORT_OK
        );
        let close = poll(WREQ_EVENT_WEBSOCKET_CLOSE);
        // SAFETY: CLOSE remains live until event_free.
        unsafe {
            assert_eq!((*close).status_code, 1000);
            assert_eq!(
                slice::from_raw_parts((*close).data.ptr, (*close).data.len),
                b"bye"
            );
        }
        wreq_transport_event_free(close);
        assert_eq!(
            wreq_transport_websocket_cancel(transport, request_id),
            WREQ_TRANSPORT_NOT_FOUND
        );

        wreq_transport_free(transport);
        server.join().expect("websocket server thread");
    }
}
