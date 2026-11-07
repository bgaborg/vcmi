# Godot extension libvcmi_xr.so of the Quest build: reads the game data the bridge in quest/bridge publishes.
# Built by quest/tools/make-extension.sh with the NDK the game uses; no VCMI headers, only the C ABI.
cmake_minimum_required(VERSION 3.17)
project(vcmi_xr LANGUAGES CXX)

set(GODOT_CPP_DIR "" CACHE PATH "godot-cpp checkout")
set(GODOTCPP_TARGET template_release CACHE STRING "")
add_subdirectory("${GODOT_CPP_DIR}" godot-cpp EXCLUDE_FROM_ALL)

add_library(vcmi_xr SHARED VcmiData.cpp)
# only the entry symbol (GDE_EXPORT) is exported
set_target_properties(vcmi_xr PROPERTIES CXX_STANDARD 17 CXX_EXTENSIONS OFF CXX_VISIBILITY_PRESET hidden)
target_link_libraries(vcmi_xr PRIVATE godot-cpp)
