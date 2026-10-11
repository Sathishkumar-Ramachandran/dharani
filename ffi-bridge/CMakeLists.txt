set(DHARANI_FFI_SOURCES dharani_c_api.cpp engine.cpp)
if(ANDROID)
  list(APPEND DHARANI_FFI_SOURCES android/jni_dharani_bridge.cpp)
endif()

add_library(dharani_ffi SHARED ${DHARANI_FFI_SOURCES})
target_include_directories(dharani_ffi PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(dharani_ffi PRIVATE dharani_protocol dharani_native)
target_compile_options(dharani_ffi PRIVATE -Wall -Wextra)

if(ANDROID)
  # Android 15+ devices may use 16 KB pages.
  target_link_options(dharani_ffi PRIVATE -Wl,-z,max-page-size=16384)
  target_link_libraries(dharani_ffi PRIVATE log)
endif()
if(APPLE AND NOT IOS)
  set_target_properties(dharani_ffi PROPERTIES SUFFIX ".dylib")
endif()
