# Two iOS executables that differ only in the helper call, so the check can
# assert what logos_ios_export_symbols() changes rather than that it ran.
cmake_minimum_required(VERSION 3.24)
project(LogosIosSymbolExportsCheck LANGUAGES C)

# Bare executables: nothing here is installed on a device, and a bundle would
# only put the two images the check compares behind extra path.
set(CMAKE_MACOSX_BUNDLE OFF)

include(${LOGOS_IOS_CMAKE_DIR}/LogosIosSymbolExports.cmake)

add_library(probe STATIC probe_used.c probe_unused.c)

# The control: an ordinary iOS executable. Exports its default-visibility
# globals and never pulls probe_unused.c in.
add_executable(app_plain main.c)
target_link_libraries(app_plain PRIVATE probe)

add_executable(app_list main.c)
target_link_libraries(app_list PRIVATE probe)
logos_ios_export_symbols(app_list SYMBOL_FILES ${LOGOS_IOS_EXPORTED_SYMBOLS_FILE})

install(TARGETS app_plain app_list DESTINATION bin)
