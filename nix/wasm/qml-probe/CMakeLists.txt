# The smallest thing that is still the RUNTIME SHAPE: a Qt Quick application,
# with Controls, SVG and Qt Remote Objects linked in, compiled to one wasm
# image. Not a hello-world: the sizes this produces are what ADR 0004's budget
# is compared against, so the image has to contain the same Qt modules the Web
# container's QML runtime will.
cmake_minimum_required(VERSION 3.21)
project(logos_qt_wasm_probe LANGUAGES CXX)

find_package(Qt6 REQUIRED COMPONENTS Core Gui Qml Quick QuickControls2 Svg RemoteObjects)

qt_standard_project_setup(REQUIRES 6.5)

qt_add_executable(logos_qt_wasm_probe main.cpp)

qt_add_qml_module(logos_qt_wasm_probe
    URI LogosWasmProbe
    VERSION 1.0
    QML_FILES Main.qml
)

target_link_libraries(logos_qt_wasm_probe PRIVATE
    Qt6::Quick
    Qt6::QuickControls2
    Qt6::Svg
    Qt6::RemoteObjects
)
