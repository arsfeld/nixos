idf_component_register(
    SRCS "board_display.c"
    INCLUDE_DIRS "."
    REQUIRES esp_lcd esp_timer esp_driver_spi esp_driver_i2c esp_driver_i2s esp_driver_gpio)
