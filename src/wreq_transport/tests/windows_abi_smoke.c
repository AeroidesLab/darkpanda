#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <windows.h>

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "wreq_transport.h"

#pragma comment(lib, "ws2_32.lib")

typedef struct SmokeServer {
    SOCKET listener;
    volatile LONG stop;
} SmokeServer;

static WreqSlice byte_string(const char *text) {
    WreqSlice result;
    result.ptr = (const uint8_t *)text;
    result.len = strlen(text);
    return result;
}

static WreqSlice empty_bytes(void) {
    WreqSlice result;
    result.ptr = NULL;
    result.len = 0;
    return result;
}

static DWORD WINAPI smoke_server_main(LPVOID parameter) {
    SmokeServer *server = (SmokeServer *)parameter;
    while (InterlockedCompareExchange(&server->stop, 0, 0) == 0) {
        fd_set readable;
        struct timeval timeout;
        int selected;

        FD_ZERO(&readable);
        FD_SET(server->listener, &readable);
        timeout.tv_sec = 0;
        timeout.tv_usec = 100000;
        selected = select(0, &readable, NULL, NULL, &timeout);
        if (selected <= 0) {
            continue;
        }

        {
            SOCKET client = accept(server->listener, NULL, NULL);
            char request[4096];
            int received = 0;
            DWORD receive_timeout_ms = 2000;
            if (client == INVALID_SOCKET) {
                continue;
            }
            (void)setsockopt(client,
                             SOL_SOCKET,
                             SO_RCVTIMEO,
                             (const char *)&receive_timeout_ms,
                             (int)sizeof(receive_timeout_ms));
            while (received < (int)sizeof(request) - 1) {
                int chunk = recv(client,
                                 request + received,
                                 (int)sizeof(request) - 1 - received,
                                 0);
                if (chunk <= 0) {
                    break;
                }
                received += chunk;
                request[received] = '\0';
                if (strstr(request, "\r\n\r\n") != NULL) {
                    break;
                }
            }
            request[received] = '\0';

            if (strstr(request, "/redirect") != NULL) {
                static const char response[] =
                    "HTTP/1.1 302 Found\r\n"
                    "Location: /body\r\n"
                    "Content-Length: 0\r\n"
                    "Connection: close\r\n"
                    "\r\n";
                (void)send(client, response, (int)sizeof(response) - 1, 0);
            } else if (strstr(request, "/body") != NULL) {
                static const char response[] =
                    "HTTP/1.1 200 OK\r\n"
                    "Content-Length: 11\r\n"
                    "X-Smoke: yes\r\n"
                    "Connection: close\r\n"
                    "\r\n"
                    "hello world";
                (void)send(client, response, (int)sizeof(response) - 1, 0);
            } else {
                Sleep(500);
            }
            closesocket(client);
        }
    }
    return 0;
}

static int next_request_event(WreqTransport *transport,
                              uint64_t request_id,
                              WreqEvent **out_event) {
    unsigned attempt;
    *out_event = NULL;
    for (attempt = 0; attempt < 50; ++attempt) {
        WreqEvent *event = NULL;
        int32_t status = wreq_transport_poll_event(transport, 200, &event);
        if (status == WREQ_TRANSPORT_EMPTY) {
            continue;
        }
        if (status != WREQ_TRANSPORT_OK || event == NULL) {
            return 0;
        }
        if (event->request_id != request_id) {
            wreq_transport_event_free(event);
            continue;
        }
        *out_event = event;
        return 1;
    }
    return 0;
}

#define REQUIRE(condition, message)                                               \
    do {                                                                          \
        if (!(condition)) {                                                       \
            fprintf(stderr, "windows_abi_smoke: %s (line %d)\n", message, __LINE__); \
            goto cleanup;                                                         \
        }                                                                         \
    } while (0)

int main(void) {
    WSADATA winsock_data;
    SmokeServer server;
    HANDLE server_thread = NULL;
    struct sockaddr_in address;
    int address_length;
    WreqTransport *transport = NULL;
    WreqEvent *event = NULL;
    int success = 0;
    char url[256];
    char proxy_url[256];
    uint64_t request_id = 0;

    memset(&server, 0, sizeof(server));
    server.listener = INVALID_SOCKET;
    REQUIRE(WSAStartup(MAKEWORD(2, 2), &winsock_data) == 0, "WSAStartup failed");

    server.listener = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    REQUIRE(server.listener != INVALID_SOCKET, "listener socket failed");
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = 0;
    REQUIRE(bind(server.listener, (const struct sockaddr *)&address, sizeof(address)) == 0,
            "listener bind failed");
    REQUIRE(listen(server.listener, SOMAXCONN) == 0, "listener listen failed");
    address_length = (int)sizeof(address);
    REQUIRE(getsockname(server.listener, (struct sockaddr *)&address, &address_length) == 0,
            "listener getsockname failed");
    server_thread = CreateThread(NULL, 0, smoke_server_main, &server, 0, NULL);
    REQUIRE(server_thread != NULL, "server thread creation failed");

    /* Exercise the default Chrome149 constructor and coalesced wake path. */
    REQUIRE(wreq_transport_create(&transport) == WREQ_TRANSPORT_OK,
            "default create failed");
    REQUIRE(wreq_transport_abi_version() == WREQ_TRANSPORT_ABI_VERSION,
            "ABI version mismatch");
    REQUIRE(strstr(wreq_transport_version(), "wreq/6.0.0-rc.29") != NULL,
            "implementation version mismatch");
    REQUIRE(wreq_transport_wakeup(transport) == WREQ_TRANSPORT_OK, "wakeup failed");
    REQUIRE(wreq_transport_poll_event(transport, 2000, &event) == WREQ_TRANSPORT_EMPTY,
            "wakeup did not interrupt poll with EMPTY");
    REQUIRE(event == NULL, "wakeup fabricated a request event");
    wreq_transport_free(transport);
    transport = NULL;

    {
        WreqTransportOptions options;
        memset(&options, 0, sizeof(options));
        options.struct_size = (uint32_t)sizeof(options);
        options.abi_version = WREQ_TRANSPORT_ABI_VERSION;
        options.event_capacity = 4;
        options.profile_id = WREQ_TRANSPORT_PROFILE_CHROME_149;
        REQUIRE(wreq_transport_create_with_options(&options, &transport) == WREQ_TRANSPORT_OK,
                "Chrome149 options create failed");
    }

    /* HEADERS must be visible before DATA, and DATA must wait for ACK. */
    _snprintf_s(proxy_url,
                sizeof(proxy_url),
                _TRUNCATE,
                "http://127.0.0.1:%u",
                (unsigned)ntohs(address.sin_port));
    strcpy_s(url, sizeof(url), "http://wreq-override.invalid/body");
    {
        WreqRequest request;
        memset(&request, 0, sizeof(request));
        request.struct_size = (uint32_t)sizeof(request);
        request.abi_version = WREQ_TRANSPORT_ABI_VERSION;
        request.method = byte_string("GET");
        request.url = byte_string(url);
        request.body = empty_bytes();
        request.timeout_ms = 2000;
        request.flags = WREQ_REQUEST_OPTION_CONFIG_OVERRIDE;
        request.proxy_url = byte_string(proxy_url);
        REQUIRE(wreq_transport_submit(transport, &request, &request_id) == WREQ_TRANSPORT_OK,
                "request-level proxy submit failed");
    }
    memset(url, 'x', strlen(url));
    memset(proxy_url, 'x', strlen(proxy_url));
    REQUIRE(next_request_event(transport, request_id, &event), "HEADERS event timed out");
    REQUIRE(event->kind == WREQ_EVENT_HEADERS, "first body event was not HEADERS");
    REQUIRE(event->status_code == 200, "unexpected HTTP status");
    {
        WreqEvent *unexpected = NULL;
        REQUIRE(wreq_transport_poll_event(transport, 50, &unexpected) == WREQ_TRANSPORT_EMPTY,
                "DATA arrived before HEADERS ACK");
        REQUIRE(unexpected == NULL, "pre-ACK poll returned an event");
    }
    REQUIRE(wreq_transport_headers_ack(transport, request_id) == WREQ_TRANSPORT_OK,
            "HEADERS ACK failed");
    wreq_transport_event_free(event);
    event = NULL;
    {
        char body[32];
        size_t body_length = 0;
        int done = 0;
        while (!done) {
            REQUIRE(next_request_event(transport, request_id, &event), "body event timed out");
            if (event->kind == WREQ_EVENT_DATA) {
                REQUIRE(body_length + event->data.len <= sizeof(body), "body overflow");
                memcpy(body + body_length, event->data.ptr, event->data.len);
                body_length += event->data.len;
            } else if (event->kind == WREQ_EVENT_DONE) {
                done = 1;
            } else {
                REQUIRE(0, "body request ended with ERROR/CANCELLED");
            }
            wreq_transport_event_free(event);
            event = NULL;
        }
        REQUIRE(body_length == 11 && memcmp(body, "hello world", 11) == 0,
                "body bytes mismatch");
    }

    /* Utility clients can opt into a bounded per-request redirect policy;
     * browser requests leave this flag clear and preserve browser-owned
     * redirect handling. */
    _snprintf_s(url,
                sizeof(url),
                _TRUNCATE,
                "http://127.0.0.1:%u/redirect",
                (unsigned)ntohs(address.sin_port));
    {
        WreqRequest request;
        memset(&request, 0, sizeof(request));
        request.struct_size = (uint32_t)sizeof(request);
        request.abi_version = WREQ_TRANSPORT_ABI_VERSION;
        request.method = byte_string("GET");
        request.url = byte_string(url);
        request.timeout_ms = 2000;
        request.flags = WREQ_REQUEST_OPTION_FOLLOW_REDIRECTS;
        REQUIRE(wreq_transport_submit(transport, &request, &request_id) == WREQ_TRANSPORT_OK,
                "redirect submit failed");
    }
    REQUIRE(next_request_event(transport, request_id, &event), "redirect HEADERS timed out");
    REQUIRE(event->kind == WREQ_EVENT_HEADERS, "redirect did not yield HEADERS");
    REQUIRE(event->status_code == 200, "redirect policy did not reach final response");
    REQUIRE(wreq_transport_headers_ack(transport, request_id) == WREQ_TRANSPORT_OK,
            "redirect HEADERS ACK failed");
    wreq_transport_event_free(event);
    event = NULL;
    {
        int done = 0;
        while (!done) {
            REQUIRE(next_request_event(transport, request_id, &event),
                    "redirect terminal event timed out");
            if (event->kind == WREQ_EVENT_DONE) {
                done = 1;
            } else {
                REQUIRE(event->kind == WREQ_EVENT_DATA,
                        "redirect request ended with ERROR/CANCELLED");
            }
            wreq_transport_event_free(event);
            event = NULL;
        }
    }

    /* The request timeout is total: it continues while the consumer holds a
     * HEADERS event without acknowledging it. */
    _snprintf_s(url,
                sizeof(url),
                _TRUNCATE,
                "http://127.0.0.1:%u/body",
                (unsigned)ntohs(address.sin_port));
    {
        WreqRequest request;
        memset(&request, 0, sizeof(request));
        request.struct_size = (uint32_t)sizeof(request);
        request.abi_version = WREQ_TRANSPORT_ABI_VERSION;
        request.method = byte_string("GET");
        request.url = byte_string(url);
        request.timeout_ms = 500;
        REQUIRE(wreq_transport_submit(transport, &request, &request_id) == WREQ_TRANSPORT_OK,
                "unacknowledged timeout submit failed");
    }
    REQUIRE(next_request_event(transport, request_id, &event),
            "unacknowledged timeout HEADERS missing");
    REQUIRE(event->kind == WREQ_EVENT_HEADERS,
            "unacknowledged timeout first event was not HEADERS");
    wreq_transport_event_free(event);
    event = NULL;
    REQUIRE(next_request_event(transport, request_id, &event),
            "unacknowledged HEADERS did not time out");
    REQUIRE(event->kind == WREQ_EVENT_ERROR,
            "unacknowledged HEADERS timeout did not emit ERROR");
    REQUIRE(event->data.len != 0,
            "unacknowledged HEADERS timeout had no diagnostic");
    wreq_transport_event_free(event);
    event = NULL;

    /* A stalled response must terminate through the per-request timeout. */
    _snprintf_s(url,
                sizeof(url),
                _TRUNCATE,
                "http://127.0.0.1:%u/timeout",
                (unsigned)ntohs(address.sin_port));
    {
        WreqRequest request;
        memset(&request, 0, sizeof(request));
        request.struct_size = (uint32_t)sizeof(request);
        request.abi_version = WREQ_TRANSPORT_ABI_VERSION;
        request.method = byte_string("GET");
        request.url = byte_string(url);
        request.timeout_ms = 100;
        REQUIRE(wreq_transport_submit(transport, &request, &request_id) == WREQ_TRANSPORT_OK,
                "timeout submit failed");
    }
    REQUIRE(next_request_event(transport, request_id, &event), "timeout event missing");
    REQUIRE(event->kind == WREQ_EVENT_ERROR, "request timeout did not emit ERROR");
    REQUIRE(event->data.len != 0, "timeout ERROR had no diagnostic");
    wreq_transport_event_free(event);
    event = NULL;

    /* Cancellation is direct and must produce the sole terminal event. */
    _snprintf_s(url,
                sizeof(url),
                _TRUNCATE,
                "http://127.0.0.1:%u/cancel",
                (unsigned)ntohs(address.sin_port));
    {
        WreqRequest request;
        memset(&request, 0, sizeof(request));
        request.struct_size = (uint32_t)sizeof(request);
        request.abi_version = WREQ_TRANSPORT_ABI_VERSION;
        request.method = byte_string("GET");
        request.url = byte_string(url);
        REQUIRE(wreq_transport_submit(transport, &request, &request_id) == WREQ_TRANSPORT_OK,
                "cancel submit failed");
    }
    REQUIRE(wreq_transport_cancel(transport, request_id) == WREQ_TRANSPORT_OK,
            "cancel call failed");
    REQUIRE(next_request_event(transport, request_id, &event), "CANCELLED event missing");
    REQUIRE(event->kind == WREQ_EVENT_CANCELLED, "cancel did not emit CANCELLED");
    wreq_transport_event_free(event);
    event = NULL;

    success = 1;

cleanup:
    if (event != NULL) {
        wreq_transport_event_free(event);
    }
    if (transport != NULL) {
        wreq_transport_free(transport);
    }
    InterlockedExchange(&server.stop, 1);
    if (server.listener != INVALID_SOCKET) {
        shutdown(server.listener, SD_BOTH);
        closesocket(server.listener);
    }
    if (server_thread != NULL) {
        (void)WaitForSingleObject(server_thread, 3000);
        CloseHandle(server_thread);
    }
    WSACleanup();

    if (success) {
        puts("windows_abi_smoke: PASS");
        return 0;
    }
    return 1;
}
