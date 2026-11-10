idf_component_register(
    SRCS main.c net.c ui.c ui_snapshot.c chime.c
    INCLUDE_DIRS .
    REQUIRES board_proto esp_wifi esp_event esp_netif nvs_flash esp_timer mbedtls esp_codec_dev)

idf_component_get_property(LVGL_LIB lvgl__lvgl COMPONENT_LIB)
target_compile_options(${LVGL_LIB} PRIVATE -DLV_LVGL_H_INCLUDE_SIMPLE -Wno-error=attributes)
