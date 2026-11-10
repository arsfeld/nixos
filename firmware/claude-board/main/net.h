// net: Wi-Fi, the clock, and the WebSocket to the bridge.
//
// Fails closed: the connection is only attempted once the clock is valid (TLS certificate dates)
// and the server certificate is always validated; there is no insecure mode.
#pragma once

#include <stdbool.h>
#include <stddef.h>

// Called from the networking task with one complete text frame (NUL-terminated).
typedef void (*net_message_cb)(const char *json, size_t len);
// Called when the bridge connection comes up or goes down.
typedef void (*net_status_cb)(bool connected);

void net_start(net_message_cb on_message, net_status_cb on_status);

// Send a text frame. False when not connected.
bool net_send(const char *json);
