#include "board_display.h"

#include <math.h>
#include <stdlib.h>

#include "driver/gpio.h"
#include "driver/i2c_master.h"
#include "driver/i2s_std.h"
#include "driver/spi_master.h"
#include "esp_codec_dev.h"
#include "esp_codec_dev_defaults.h"
#include "esp_lcd_co5300.h"
#include "esp_lcd_panel_io.h"
#include "esp_lcd_touch_cst9217.h"
#include "esp_lcd_panel_ops.h"
#include "esp_lcd_touch.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"

// The panel, touch and audio set-up below is adapted from Waveshare's BSP for the
// ESP32-S3-Touch-AMOLED-1.75 (waveshare/esp32_s3_touch_amoled_1_75 3.0.1, Apache-2.0), with its LVGL
// layer removed: that package depends on LVGL and a component-manager dependency set that
// esp-idf-sys cannot configure (MissingKconfigError: LV_USE_FREETYPE).

static const char *TAG = "board_display";

#define LCD_H_RES 466
#define LCD_V_RES 466
#define PIN_I2C_SCL GPIO_NUM_14
#define PIN_I2C_SDA GPIO_NUM_15
#define PIN_I2S_SCLK GPIO_NUM_9
#define PIN_I2S_MCLK GPIO_NUM_16
#define PIN_I2S_LCLK GPIO_NUM_45
#define PIN_I2S_DOUT GPIO_NUM_8
#define PIN_I2S_DSIN GPIO_NUM_10
#define PIN_POWER_AMP GPIO_NUM_46
#define PIN_LCD_CS GPIO_NUM_12
#define PIN_LCD_PCLK GPIO_NUM_38
#define PIN_LCD_D0 GPIO_NUM_4
#define PIN_LCD_D1 GPIO_NUM_5
#define PIN_LCD_D2 GPIO_NUM_6
#define PIN_LCD_D3 GPIO_NUM_7
#define PIN_LCD_RST GPIO_NUM_39
#define PIN_TOUCH_RST GPIO_NUM_40
#define PIN_TOUCH_INT GPIO_NUM_11
#define LCD_SPI_HOST SPI2_HOST
#define I2C_PORT 1
#define I2S_PORT 1
#define LCD_TRANS_QUEUE_DEPTH 10
#define TOUCH_I2C_HZ 400000
// The BSP's default. 80 MHz measured 17 ms per full frame against 27 ms, but has not been checked by eye on
// the panel (its pins go through the GPIO matrix); raise it only after looking for noise.
#define LCD_PCLK_HZ (40 * 1000 * 1000)

static const co5300_lcd_init_cmd_t lcd_init_cmds[] = {
    {0xFE, (uint8_t[]){0x20}, 1, 0},
    {0x19, (uint8_t[]){0x10}, 1, 0},
    {0x1C, (uint8_t[]){0xA0}, 1, 0},
    {0xFE, (uint8_t[]){0x00}, 1, 0},
    {0xC4, (uint8_t[]){0x80}, 1, 0},
    {0x3A, (uint8_t[]){0x55}, 1, 0},
    {0x35, (uint8_t[]){0x00}, 1, 0},
    {0x53, (uint8_t[]){0x20}, 1, 0},
    {0x51, (uint8_t[]){0xFF}, 1, 0},
    {0x63, (uint8_t[]){0xFF}, 1, 0},
    {0x2A, (uint8_t[]){0x00, 0x06, 0x01, 0xD7}, 4, 0},
    {0x2B, (uint8_t[]){0x00, 0x00, 0x01, 0xD1}, 4, 600},
    {0x11, NULL, 0, 600},
    {0x29, NULL, 0, 0},
};

static esp_lcd_panel_handle_t s_panel;
static esp_lcd_panel_io_handle_t s_io;
static esp_lcd_touch_handle_t s_touch;
static SemaphoreHandle_t s_done;
static volatile int s_pending; // colour transfers queued and not finished (only the drawing task changes it up)
static i2c_master_bus_handle_t s_i2c;
static i2s_chan_handle_t s_i2s_tx, s_i2s_rx;
static const audio_codec_data_if_t *s_i2s_data_if;

static esp_err_t i2c_init(void)
{
    if (s_i2c) return ESP_OK;
    i2c_master_bus_config_t conf = {
        .clk_source = I2C_CLK_SRC_DEFAULT,
        .sda_io_num = PIN_I2C_SDA,
        .scl_io_num = PIN_I2C_SCL,
        .i2c_port = I2C_PORT,
    };
    return i2c_new_master_bus(&conf, &s_i2c);
}

static esp_err_t display_new(int max_transfer_sz)
{
    const spi_bus_config_t buscfg = CO5300_PANEL_BUS_QSPI_CONFIG(PIN_LCD_PCLK, PIN_LCD_D0, PIN_LCD_D1, PIN_LCD_D2,
                                                                  PIN_LCD_D3, max_transfer_sz);
    esp_err_t err = spi_bus_initialize(LCD_SPI_HOST, &buscfg, SPI_DMA_CH_AUTO);
    if (err != ESP_OK) return err;
    esp_lcd_panel_io_spi_config_t io_config = CO5300_PANEL_IO_QSPI_CONFIG(PIN_LCD_CS, NULL, NULL);
    io_config.trans_queue_depth = LCD_TRANS_QUEUE_DEPTH;
    io_config.pclk_hz = LCD_PCLK_HZ;
    co5300_vendor_config_t vendor = {
        .init_cmds = lcd_init_cmds,
        .init_cmds_size = sizeof(lcd_init_cmds) / sizeof(lcd_init_cmds[0]),
        .flags = {.use_qspi_interface = 1},
    };
    err = esp_lcd_new_panel_io_spi((esp_lcd_spi_bus_handle_t)LCD_SPI_HOST, &io_config, &s_io);
    if (err != ESP_OK) return err;
    const esp_lcd_panel_dev_config_t panel_config = {
        .reset_gpio_num = PIN_LCD_RST,
        .rgb_ele_order = LCD_RGB_ELEMENT_ORDER_RGB,
        .bits_per_pixel = 16,
        .vendor_config = &vendor,
    };
    err = esp_lcd_new_panel_co5300(s_io, &panel_config, &s_panel);
    if (err != ESP_OK) return err;
    esp_lcd_panel_set_gap(s_panel, 0x06, 0);
    esp_lcd_panel_reset(s_panel);
    esp_lcd_panel_init(s_panel);
    esp_lcd_panel_disp_on_off(s_panel, true);
    return ESP_OK;
}

static esp_err_t touch_new(void)
{
    esp_err_t err = i2c_init();
    if (err != ESP_OK) return err;
    const esp_lcd_touch_config_t tp_cfg = {
        .x_max = LCD_H_RES,
        .y_max = LCD_V_RES,
        .rst_gpio_num = PIN_TOUCH_RST, // shared with the LCD reset
        .int_gpio_num = PIN_TOUCH_INT,
        .levels = {.reset = 0, .interrupt = 0},
        .flags = {.swap_xy = 0, .mirror_x = 1, .mirror_y = 1}, // as the BSP's own defaults
    };
    esp_lcd_panel_io_handle_t tp_io = NULL;
    esp_lcd_panel_io_i2c_config_t tp_io_cfg = ESP_LCD_TOUCH_IO_I2C_CST9217_CONFIG();
    tp_io_cfg.scl_speed_hz = TOUCH_I2C_HZ;
    err = esp_lcd_new_panel_io_i2c(s_i2c, &tp_io_cfg, &tp_io);
    if (err != ESP_OK) return err;
    return esp_lcd_touch_new_i2c_cst9217(tp_io, &tp_cfg, &s_touch);
}

static esp_err_t audio_init(void)
{
    if (s_i2s_data_if) return ESP_OK;
    i2s_chan_config_t chan_cfg = I2S_CHANNEL_DEFAULT_CONFIG(I2S_PORT, I2S_ROLE_MASTER);
    chan_cfg.auto_clear = true;
    esp_err_t err = i2s_new_channel(&chan_cfg, &s_i2s_tx, &s_i2s_rx);
    if (err != ESP_OK) return err;
    const i2s_std_config_t std_cfg = {
        .clk_cfg = I2S_STD_CLK_DEFAULT_CONFIG(22050),
        .slot_cfg = I2S_STD_PHILIP_SLOT_DEFAULT_CONFIG(I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_MONO),
        .gpio_cfg = {.mclk = PIN_I2S_MCLK, .bclk = PIN_I2S_SCLK, .ws = PIN_I2S_LCLK, .dout = PIN_I2S_DOUT, .din = PIN_I2S_DSIN},
    };
    if ((err = i2s_channel_init_std_mode(s_i2s_tx, &std_cfg)) != ESP_OK) return err;
    if ((err = i2s_channel_enable(s_i2s_tx)) != ESP_OK) return err;
    if ((err = i2s_channel_init_std_mode(s_i2s_rx, &std_cfg)) != ESP_OK) return err;
    if ((err = i2s_channel_enable(s_i2s_rx)) != ESP_OK) return err;
    audio_codec_i2s_cfg_t i2s_cfg = {.port = I2S_PORT, .rx_handle = s_i2s_rx, .tx_handle = s_i2s_tx};
    s_i2s_data_if = audio_codec_new_i2s_data(&i2s_cfg);
    return s_i2s_data_if ? ESP_OK : ESP_FAIL;
}

static esp_codec_dev_handle_t speaker_init(void)
{
    if (i2c_init() != ESP_OK || audio_init() != ESP_OK) return NULL;
    const audio_codec_gpio_if_t *gpio_if = audio_codec_new_gpio();
    audio_codec_i2c_cfg_t i2c_cfg = {.port = I2C_PORT, .addr = ES8311_CODEC_DEFAULT_ADDR, .bus_handle = s_i2c};
    const audio_codec_ctrl_if_t *ctrl_if = audio_codec_new_i2c_ctrl(&i2c_cfg);
    if (!ctrl_if) return NULL;
    es8311_codec_cfg_t es8311_cfg = {
        .ctrl_if = ctrl_if,
        .gpio_if = gpio_if,
        .codec_mode = ESP_CODEC_DEV_WORK_MODE_DAC,
        .pa_pin = PIN_POWER_AMP,
        .pa_reverted = false,
        .master_mode = false,
        .use_mclk = true,
        .digital_mic = false,
        .invert_mclk = false,
        .invert_sclk = false,
        .hw_gain = {.pa_voltage = 5.0, .codec_dac_voltage = 3.3},
    };
    const audio_codec_if_t *codec = es8311_codec_new(&es8311_cfg);
    if (!codec) return NULL;
    esp_codec_dev_cfg_t dev_cfg = {.dev_type = ESP_CODEC_DEV_TYPE_OUT, .codec_if = codec, .data_if = s_i2s_data_if};
    return esp_codec_dev_new(&dev_cfg);
}

// Microphone: the ES7210 ADC on the shared I2C bus, a slave on the same I2S clock as the ES8311. Its two real
// microphones are MIC1 (left slot) and MIC2 (right slot); MIC3/4 carry the speaker reference and are not selected.
#define MIC_GAIN_DB 24.0f
#define MIC_STAGE_FRAMES 256 // stereo frames read from the codec at a time (2 KiB of stack)
#define MIC_OPEN_WAIT_MS 1000

static esp_codec_dev_handle_t mic_init(void)
{
    if (i2c_init() != ESP_OK || audio_init() != ESP_OK) return NULL;
    audio_codec_i2c_cfg_t i2c_cfg = {.port = I2C_PORT, .addr = ES7210_CODEC_DEFAULT_ADDR, .bus_handle = s_i2c};
    const audio_codec_ctrl_if_t *ctrl_if = audio_codec_new_i2c_ctrl(&i2c_cfg);
    if (!ctrl_if) return NULL;
    es7210_codec_cfg_t es7210_cfg = {
        .ctrl_if = ctrl_if,
        .master_mode = false, // the ESP32 drives BCLK/WS/MCLK (MCLK = 256 x rate)
        .mic_selected = ES7210_SEL_MIC1 | ES7210_SEL_MIC2,
    };
    const audio_codec_if_t *codec = es7210_codec_new(&es7210_cfg);
    if (!codec) return NULL;
    esp_codec_dev_cfg_t dev_cfg = {.dev_type = ESP_CODEC_DEV_TYPE_IN, .codec_if = codec, .data_if = s_i2s_data_if};
    return esp_codec_dev_new(&dev_cfg);
}

#define STRIP_ROWS 16 // the largest update window bd_draw accepts, in rows of the full width
#define CHIME_RATE 16000
#define CHIME_NOTE_MS 110
#define CHIME_MIN_GAP_US (3 * 1000000LL)


static esp_codec_dev_handle_t s_speaker;
static esp_codec_dev_handle_t s_mic;
// Capture and playback share one I2S clock, so they must never overlap. s_audio_lock guards s_mic_open and the
// chime's whole open/write/close; the mic stays "open" (flag set) from bd_mic_open to bd_mic_close.
static SemaphoreHandle_t s_audio_lock;
static bool s_mic_open;
static bool s_spk_open; // a speech stream is open (bd_speaker_begin .. bd_speaker_end), also under s_audio_lock
static SemaphoreHandle_t s_chime_wake;
static int64_t s_chime_last_us;

static bool on_color_done(esp_lcd_panel_io_handle_t io, esp_lcd_panel_io_event_data_t *ev, void *ctx)
{
    (void)io; (void)ev; (void)ctx;
    BaseType_t woken = pdFALSE;
    xSemaphoreGiveFromISR(s_done, &woken);
    return woken == pdTRUE;
}

static void tone(int16_t *out, int n, float hz)
{
    for (int i = 0; i < n; i++) {
        float env = 1.0f;
        if (i < 200) env = i / 200.0f;           // fade in: no click
        if (i > n - 400) env = (n - i) / 400.0f; // fade out
        out[i] = (int16_t)(sinf(2.0f * (float)M_PI * hz * (float)i / CHIME_RATE) * 9000.0f * env);
    }
}

static void chime_task(void *arg)
{
    (void)arg;
    const int n = CHIME_RATE * CHIME_NOTE_MS / 1000;
    int16_t *buf = malloc((size_t)n * 2 * sizeof *buf);
    if (!buf) vTaskDelete(NULL);
    tone(buf, n, 880.0f);
    tone(buf + n, n, 1175.0f);
    esp_codec_dev_sample_info_t fs = {.sample_rate = CHIME_RATE, .channel = 1, .bits_per_sample = 16};
    for (;;) {
        xSemaphoreTake(s_chime_wake, portMAX_DELAY);
        xSemaphoreTake(s_audio_lock, portMAX_DELAY);
        if (!s_mic_open && !s_spk_open) { // a recording or a spoken reply has the clock: skip the chime
            if (esp_codec_dev_open(s_speaker, &fs) != ESP_CODEC_DEV_OK) {
                ESP_LOGW(TAG, "speaker open failed");
            } else {
                esp_codec_dev_set_out_vol(s_speaker, 55);
                esp_codec_dev_write(s_speaker, buf, n * 2 * (int)sizeof *buf);
                esp_codec_dev_close(s_speaker); // silent, and no idle hiss between chimes
            }
        }
        xSemaphoreGive(s_audio_lock);
    }
}

esp_err_t bd_init(void)
{
    s_done = xSemaphoreCreateCounting(32, 0); // counts finished transfers: several complete while we copy
    esp_err_t err = display_new(STRIP_ROWS * LCD_H_RES * 2 + 8);
    if (err != ESP_OK) return err;
    const esp_lcd_panel_io_callbacks_t cbs = {.on_color_trans_done = on_color_done};
    err = esp_lcd_panel_io_register_event_callbacks(s_io, &cbs, NULL);
    if (err != ESP_OK) return err;
    bd_set_brightness(70);

    if (touch_new() != ESP_OK) ESP_LOGW(TAG, "no touch controller");

    s_audio_lock = xSemaphoreCreateMutex();
    s_speaker = speaker_init();
    if (s_speaker) {
        s_chime_wake = xSemaphoreCreateBinary();
        xTaskCreate(chime_task, "chime", 4096, NULL, 3, NULL);
    } else {
        ESP_LOGW(TAG, "no speaker: chimes disabled");
    }
    s_mic = mic_init();
    if (!s_mic) ESP_LOGW(TAG, "no microphone: voice disabled");
    return ESP_OK;
}

esp_err_t bd_draw(int x0, int y0, int x1, int y1, const uint16_t *rgb565)
{
    // The panel IO drains earlier colour transfers before it sends this window's address commands, so
    // once this call returns the buffer of the previous call is free again.
    esp_err_t err = esp_lcd_panel_draw_bitmap(s_panel, x0, y0, x1, y1, rgb565);
    if (err == ESP_OK) s_pending++;
    return err;
}

esp_err_t bd_wait(void)
{
    while (s_pending > 0) {
        if (xSemaphoreTake(s_done, pdMS_TO_TICKS(200)) != pdTRUE) {
            ESP_LOGW(TAG, "panel transfer did not finish (%d pending)", s_pending);
            s_pending = 0;
            return ESP_ERR_TIMEOUT;
        }
        s_pending--;
    }
    return ESP_OK;
}

bool bd_touch_read(bd_touch_t *out)
{
    if (!s_touch) return false;
    if (esp_lcd_touch_read_data(s_touch) != ESP_OK) return false;
    esp_lcd_touch_point_data_t p[1];
    uint8_t n = 0;
    if (esp_lcd_touch_get_data(s_touch, p, &n, 1) != ESP_OK) return false;
    out->pressed = n > 0;
    if (n > 0) {
        out->x = (int16_t)p[0].x;
        out->y = (int16_t)p[0].y;
    }
    return true;
}

void bd_set_brightness(uint8_t percent)
{
    if (percent > 100) percent = 100;
    uint8_t param = (uint8_t)(percent * 255 / 100);
    esp_lcd_panel_io_tx_param(s_io, (0x02u << 24) | (0x51u << 8), &param, 1); // CO5300 DCS: set brightness
}

void bd_chime(void)
{
    if (!s_speaker || s_mic_open || s_spk_open) return;
    int64_t now = esp_timer_get_time();
    if (now - s_chime_last_us < CHIME_MIN_GAP_US) return;
    s_chime_last_us = now;
    xSemaphoreGive(s_chime_wake);
}

esp_err_t bd_mic_open(uint32_t rate_hz)
{
    if (!s_mic || !s_audio_lock) return ESP_ERR_NOT_SUPPORTED;
    // Waits out a chime that is playing (about 0.3 s); the flag then keeps new ones away until bd_mic_close.
    if (xSemaphoreTake(s_audio_lock, pdMS_TO_TICKS(MIC_OPEN_WAIT_MS)) != pdTRUE) return ESP_ERR_TIMEOUT;
    esp_err_t err = ESP_OK;
    if (s_mic_open || s_spk_open) { // never alongside a stream: one shared clock
        err = ESP_ERR_INVALID_STATE;
    } else {
        // Stereo on the wire (MIC1 left, MIC2 right); bd_mic_read downmixes to mono.
        esp_codec_dev_sample_info_t fs = {.sample_rate = rate_hz, .channel = 2, .bits_per_sample = 16};
        if (esp_codec_dev_open(s_mic, &fs) != ESP_CODEC_DEV_OK) {
            err = ESP_FAIL;
        } else {
            s_mic_open = true;
            // After open: open re-applies the stored gain, which is 0 dB until set once.
            if (esp_codec_dev_set_in_gain(s_mic, MIC_GAIN_DB) != ESP_CODEC_DEV_OK) ESP_LOGW(TAG, "mic gain not set");
        }
    }
    xSemaphoreGive(s_audio_lock);
    return err;
}

// Fills up to max_samples mono PCM16 samples (the two microphones averaged) and returns how many, or a negative
// value on error or when timeout_ms passed before they all arrived (nothing is then returned).
int bd_mic_read(int16_t *out, int max_samples, uint32_t timeout_ms)
{
    if (!s_mic || !s_mic_open || !out || max_samples <= 0) return -1;
    int16_t stage[MIC_STAGE_FRAMES * 2];
    const int64_t deadline = esp_timer_get_time() + (int64_t)timeout_ms * 1000;
    int done = 0;
    while (done < max_samples) {
        if (esp_timer_get_time() > deadline) return -2;
        int n = max_samples - done < MIC_STAGE_FRAMES ? max_samples - done : MIC_STAGE_FRAMES;
        if (esp_codec_dev_read(s_mic, stage, n * 2 * (int)sizeof(int16_t)) != ESP_CODEC_DEV_OK) return -1;
        for (int i = 0; i < n; i++) out[done + i] = (int16_t)(((int)stage[2 * i] + (int)stage[2 * i + 1]) / 2);
        done += n;
    }
    return done;
}

void bd_mic_close(void)
{
    if (!s_mic || !s_audio_lock) return;
    xSemaphoreTake(s_audio_lock, portMAX_DELAY);
    if (s_mic_open) {
        esp_codec_dev_close(s_mic); // powers the ADC down; the next chime reopens TX at its own rate
        s_mic_open = false;
    }
    xSemaphoreGive(s_audio_lock);
}

// Spoken replies: one stream of 16-bit mono PCM at the rate the bridge announced. The same speaker codec handle as
// the chime; esp_codec_dev reprograms the shared I2S clock when a device is opened at a different rate, so the stream
// opens at its own rate and the chime and the microphone each reopen at theirs. s_spk_open is set between begin and
// end (under s_audio_lock): while set, bd_chime and the chime task do nothing and bd_mic_open refuses, and
// bd_speaker_begin refuses while the microphone is open (ESP_ERR_INVALID_STATE, never a wait for it). It does wait
// up to SPK_OPEN_WAIT_MS for a chime in progress. The lock is NOT held while writing: exactly one thread (the
// player) calls begin, write and end, so they need no further guarding.
#define SPK_OPEN_WAIT_MS 1000
#define SPK_VOLUME 55 // as the chime

esp_err_t bd_speaker_begin(uint32_t rate_hz)
{
    if (!s_speaker || !s_audio_lock) return ESP_ERR_NOT_SUPPORTED;
    if (xSemaphoreTake(s_audio_lock, pdMS_TO_TICKS(SPK_OPEN_WAIT_MS)) != pdTRUE) return ESP_ERR_TIMEOUT;
    esp_err_t err = ESP_OK;
    if (s_mic_open || s_spk_open) {
        err = ESP_ERR_INVALID_STATE;
    } else {
        esp_codec_dev_sample_info_t fs = {.sample_rate = rate_hz, .channel = 1, .bits_per_sample = 16};
        if (esp_codec_dev_open(s_speaker, &fs) != ESP_CODEC_DEV_OK) {
            err = ESP_FAIL;
        } else {
            s_spk_open = true;
            if (esp_codec_dev_set_out_vol(s_speaker, SPK_VOLUME) != ESP_CODEC_DEV_OK) ESP_LOGW(TAG, "speaker volume not set");
        }
    }
    xSemaphoreGive(s_audio_lock);
    return err;
}

// Blocks until the samples are queued to the I2S driver (about as long as they take to play, give or take the DMA
// buffer). bytes should be a whole number of samples. Returns bytes written, or negative on error or no open stream.
int bd_speaker_write(const void *pcm, size_t bytes)
{
    if (!s_speaker || !s_spk_open || !pcm || bytes == 0 || bytes > INT32_MAX) return -1;
    if (esp_codec_dev_write(s_speaker, (void *)pcm, (int)bytes) != ESP_CODEC_DEV_OK) return -2;
    return (int)bytes;
}

// Closes the stream (esp_codec_dev_close disables the channel after the DMA buffer has played out, and powers the DAC
// and amplifier down: silent, no idle hiss). Safe to call when nothing is open.
void bd_speaker_end(void)
{
    if (!s_speaker || !s_audio_lock) return;
    xSemaphoreTake(s_audio_lock, portMAX_DELAY);
    if (s_spk_open) {
        // A little silence first, so the tail of the speech is not cut off by the channel being disabled.
        static int16_t silence[1024];
        esp_codec_dev_write(s_speaker, silence, sizeof silence);
        esp_codec_dev_close(s_speaker);
        s_spk_open = false;
    }
    xSemaphoreGive(s_audio_lock);
}
