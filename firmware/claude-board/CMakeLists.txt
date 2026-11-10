cmake_minimum_required(VERSION 3.16)

# sdkconfig.defaults.local (gitignored) carries the Wi-Fi password and the device token;
# `just board creds` writes it from sops.
set(SDKCONFIG_DEFAULTS "sdkconfig.defaults")
if(EXISTS "${CMAKE_CURRENT_LIST_DIR}/sdkconfig.defaults.local")
    list(APPEND SDKCONFIG_DEFAULTS "sdkconfig.defaults.local")
endif()

include($ENV{IDF_PATH}/tools/cmake/project.cmake)

add_compile_options(-Wno-format -Wno-error=attributes)
project(claude-board)
