cmake_minimum_required(VERSION 3.22)
project(dharani_core VERSION 0.2.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_C_STANDARD 99)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_VISIBILITY_INLINES_HIDDEN ON)

option(DHARANI_BUILD_TESTS "Build the native test suite" ON)

add_subdirectory(core-native)
add_subdirectory(beckn-protocol-layer)
add_subdirectory(ffi-bridge)

if(NOT ANDROID AND NOT IOS)
  # Second-vehicle simulator for end-to-end mesh checks from a laptop.
  add_executable(dharani_peer_sim tools/dharani_peer_sim.cpp)
  target_link_libraries(dharani_peer_sim PRIVATE dharani_native)
  set_target_properties(dharani_peer_sim PROPERTIES RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/tools)
endif()

if(DHARANI_BUILD_TESTS AND NOT ANDROID AND NOT IOS)
  enable_testing()
  add_subdirectory(tests)
endif()
