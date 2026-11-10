#include "net.h"

#include <string.h>
#include <time.h>

#include "esp_crt_bundle.h"
#include "esp_event.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_netif_sntp.h"
#include "esp_timer.h"
#include "esp_websocket_client.h"
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "freertos/event_groups.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "nvs_flash.h"

static const char *TAG = "net";

#define GOT_IP BIT0
#define WS_CLOSED BIT1

#define MAX_FRAME (64 * 1024)
#define MIN_VALID_TIME 1735689600 // 2025-01-01: anything earlier means the clock is not set

static EventGroupHandle_t s_events;
static SemaphoreHandle_t s_client_lock;
static esp_websocket_client_handle_t s_client;
static esp_netif_t *s_netif;
static esp_timer_handle_t s_wifi_retry;
static uint32_t s_wifi_backoff_ms = 1000;
static net_message_cb s_on_message;
static net_status_cb s_on_status;
static char s_headers[160];

// A frame can arrive in several chunks.
static char *s_frame;

static bool clock_valid(void) { return time(NULL) > MIN_VALID_TIME; }

static void wifi_retry_cb(void *arg)
{
    (void)arg;
    esp_wifi_connect();
}

static void on_wifi_event(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    (void)arg;
    (void)base;
    if (id == WIFI_EVENT_STA_START) {
        esp_wifi_connect();
    } else if (id == WIFI_EVENT_STA_DISCONNECTED) {
        wifi_event_sta_disconnected_t *d = data;
        xEventGroupClearBits(s_events, GOT_IP);
        ESP_LOGW(TAG, "wifi disconnected (reason %d); retrying in %u ms", d->reason, (unsigned)s_wifi_backoff_ms);
        esp_timer_start_once(s_wifi_retry, (uint64_t)s_wifi_backoff_ms * 1000);
        if (s_wifi_backoff_ms < 30000) s_wifi_backoff_ms *= 2;
    }
}

static void on_ip_event(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    (void)arg;
    (void)base;
    (void)id;
    ip_event_got_ip_t *e = data;
    ESP_LOGI(TAG, "got ip " IPSTR, IP2STR(&e->ip_info.ip));
    s_wifi_backoff_ms = 1000;
    if (CONFIG_CLAUDE_BOARD_DNS[0]) {
        esp_netif_dns_info_t dns = {0};
        if (esp_netif_str_to_ip4(CONFIG_CLAUDE_BOARD_DNS, &dns.ip.u_addr.ip4) == ESP_OK) {
            dns.ip.type = ESP_IPADDR_TYPE_V4;
            esp_netif_set_dns_info(s_netif, ESP_NETIF_DNS_MAIN, &dns);
            ESP_LOGI(TAG, "dns override: %s", CONFIG_CLAUDE_BOARD_DNS);
        }
    }
    xEventGroupSetBits(s_events, GOT_IP);
}

static void handle_data(const esp_websocket_event_data_t *e)
{
    if (e->op_code != 0x1 && e->op_code != 0x0) return; // text, or a continuation of one
    if (e->payload_offset == 0) {
        free(s_frame);
        s_frame = NULL;
        if (e->payload_len > MAX_FRAME) {
            ESP_LOGW(TAG, "dropping a %d byte frame (limit %d)", (int)e->payload_len, MAX_FRAME);
            return;
        }
        s_frame = heap_caps_malloc((size_t)e->payload_len + 1, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
        if (!s_frame) s_frame = malloc((size_t)e->payload_len + 1);
    }
    if (!s_frame) return;
    memcpy(s_frame + e->payload_offset, e->data_ptr, (size_t)e->data_len);
    if (e->payload_offset + e->data_len >= e->payload_len) {
        s_frame[e->payload_len] = 0;
        if (s_on_message) s_on_message(s_frame, (size_t)e->payload_len);
        free(s_frame);
        s_frame = NULL;
    }
}

static void on_ws_event(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    (void)arg;
    (void)base;
    esp_websocket_event_data_t *e = data;
    switch (id) {
    case WEBSOCKET_EVENT_CONNECTED:
        ESP_LOGI(TAG, "bridge connected");
        if (s_on_status) s_on_status(true);
        break;
    case WEBSOCKET_EVENT_DATA:
        handle_data(e);
        break;
    case WEBSOCKET_EVENT_ERROR:
        if (e->error_handle.error_type == WEBSOCKET_ERROR_TYPE_TCP_TRANSPORT)
            ESP_LOGW(TAG, "bridge error: tls=0x%x stack=0x%x sock_errno=%d http=%d",
                     e->error_handle.esp_tls_last_esp_err, e->error_handle.esp_tls_stack_err,
                     e->error_handle.esp_transport_sock_errno, e->error_handle.esp_ws_handshake_status_code);
        else
            ESP_LOGW(TAG, "bridge error: type=%d http=%d", e->error_handle.error_type, e->error_handle.esp_ws_handshake_status_code);
        xEventGroupSetBits(s_events, WS_CLOSED);
        break;
    case WEBSOCKET_EVENT_DISCONNECTED:
    case WEBSOCKET_EVENT_CLOSED:
        ESP_LOGW(TAG, "bridge connection closed");
        xEventGroupSetBits(s_events, WS_CLOSED);
        break;
    default:
        break;
    }
}

// One connection attempt; returns when it ended (failed, closed, or Wi-Fi lost).
static void connect_once(void)
{
    // Server certificate validated against the bundle, hostname included. Nothing here may
    // relax that.
    esp_websocket_client_config_t cfg = {
        .uri = CONFIG_CLAUDE_BOARD_URL,
        .headers = s_headers,
        .crt_bundle_attach = esp_crt_bundle_attach,
        .disable_auto_reconnect = true, // net_task backs off between attempts
        .network_timeout_ms = 10000,
        .buffer_size = 4096,
        .task_stack = 6144,
    };
    xSemaphoreTake(s_client_lock, portMAX_DELAY);
    s_client = esp_websocket_client_init(&cfg);
    if (s_client) {
        esp_websocket_register_events(s_client, WEBSOCKET_EVENT_ANY, on_ws_event, NULL);
        xEventGroupClearBits(s_events, WS_CLOSED);
        if (esp_websocket_client_start(s_client) != ESP_OK) xEventGroupSetBits(s_events, WS_CLOSED);
    }
    xSemaphoreGive(s_client_lock);
    if (!s_client) return;

    ESP_LOGI(TAG, "connecting to %s", CONFIG_CLAUDE_BOARD_URL);
    // Leaves on close/error, or when Wi-Fi drops (the client would sit in its own timeouts).
    while (!(xEventGroupWaitBits(s_events, WS_CLOSED, pdFALSE, pdFALSE, pdMS_TO_TICKS(2000)) & WS_CLOSED)) {
        if (!(xEventGroupGetBits(s_events) & GOT_IP)) break;
    }

    xSemaphoreTake(s_client_lock, portMAX_DELAY);
    esp_websocket_client_destroy(s_client);
    s_client = NULL;
    xSemaphoreGive(s_client_lock);
    free(s_frame);
    s_frame = NULL;
    if (s_on_status) s_on_status(false);
}

static void net_task(void *arg)
{
    (void)arg;
    uint32_t backoff_ms = 1000;
    for (;;) {
        xEventGroupWaitBits(s_events, GOT_IP, pdFALSE, pdTRUE, portMAX_DELAY);
        if (!clock_valid()) {
            ESP_LOGI(TAG, "waiting for the clock (%s)", CONFIG_CLAUDE_BOARD_NTP_SERVER);
            if (esp_netif_sntp_sync_wait(pdMS_TO_TICKS(15000)) != ESP_OK || !clock_valid()) {
                ESP_LOGW(TAG, "clock not set; not connecting");
                vTaskDelay(pdMS_TO_TICKS(5000));
                continue;
            }
            ESP_LOGI(TAG, "clock set");
        }
        int64_t t0 = esp_timer_get_time();
        connect_once();
        // A connection that lasted starts the backoff over; failures back off up to 30 s.
        if (esp_timer_get_time() - t0 > 30 * 1000000LL) backoff_ms = 1000;
        ESP_LOGI(TAG, "next attempt in %u ms", (unsigned)backoff_ms);
        vTaskDelay(pdMS_TO_TICKS(backoff_ms));
        if (backoff_ms < 30000) backoff_ms *= 2;
    }
}

bool net_send(const char *json)
{
    bool ok = false;
    xSemaphoreTake(s_client_lock, portMAX_DELAY);
    if (s_client && esp_websocket_client_is_connected(s_client))
        ok = esp_websocket_client_send_text(s_client, json, (int)strlen(json), pdMS_TO_TICKS(2000)) >= 0;
    xSemaphoreGive(s_client_lock);
    return ok;
}

void net_start(net_message_cb on_message, net_status_cb on_status)
{
    s_on_message = on_message;
    s_on_status = on_status;
    if (!CONFIG_CLAUDE_BOARD_WIFI_SSID[0] || !CONFIG_CLAUDE_BOARD_TOKEN[0]) {
        ESP_LOGE(TAG, "no credentials compiled in: run `just board creds`, then rebuild");
        return;
    }
    snprintf(s_headers, sizeof s_headers, "Authorization: Bearer %s\r\n", CONFIG_CLAUDE_BOARD_TOKEN);

    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        err = nvs_flash_init();
    }
    ESP_ERROR_CHECK(err);

    s_events = xEventGroupCreate();
    s_client_lock = xSemaphoreCreateMutex();
    const esp_timer_create_args_t timer = {.callback = wifi_retry_cb, .name = "wifi_retry"};
    ESP_ERROR_CHECK(esp_timer_create(&timer, &s_wifi_retry));

    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    s_netif = esp_netif_create_default_wifi_sta();
    wifi_init_config_t wcfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&wcfg));
    ESP_ERROR_CHECK(esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID, on_wifi_event, NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP, on_ip_event, NULL));

    wifi_config_t sta = {0};
    strlcpy((char *)sta.sta.ssid, CONFIG_CLAUDE_BOARD_WIFI_SSID, sizeof sta.sta.ssid);
    strlcpy((char *)sta.sta.password, CONFIG_CLAUDE_BOARD_WIFI_PASS, sizeof sta.sta.password);
    sta.sta.threshold.authmode = WIFI_AUTH_WPA2_PSK; // WPA2 or better, so WPA2/WPA3 mixed works
    sta.sta.sae_pwe_h2e = WPA3_SAE_PWE_BOTH;
    sta.sta.pmf_cfg.capable = true;
    sta.sta.pmf_cfg.required = false;
    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_STA, &sta));

    esp_sntp_config_t sntp = ESP_NETIF_SNTP_DEFAULT_CONFIG(CONFIG_CLAUDE_BOARD_NTP_SERVER);
    ESP_ERROR_CHECK(esp_netif_sntp_init(&sntp));

    xTaskCreate(net_task, "net", 8192, NULL, 5, NULL);
    ESP_ERROR_CHECK(esp_wifi_start());
}
