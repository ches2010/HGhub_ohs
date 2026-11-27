cmake_minimum_required(VERSION 3.10)
project(quickjs_spike LANGUAGES C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

if(NOT QUICKJS_SRC)
  message(FATAL_ERROR "QUICKJS_SRC is required")
endif()

set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(QJS_ENABLE_INSTALL OFF CACHE BOOL "" FORCE)
set(QJS_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(QJS_BUILD_CLI_STATIC OFF CACHE BOOL "" FORCE)
set(QJS_BUILD_WERROR OFF CACHE BOOL "" FORCE)

add_subdirectory("${QUICKJS_SRC}" quickjs)

find_package(Threads REQUIRED)

add_library(quickjs_spike SHARED napi_init.c)
target_include_directories(quickjs_spike PRIVATE "${QUICKJS_SRC}")
if(NAPI_LIB)
  target_link_libraries(quickjs_spike PRIVATE qjs Threads::Threads "${NAPI_LIB}")
else()
  target_link_libraries(quickjs_spike PRIVATE qjs Threads::Threads libace_napi.z.so)
endif()

set_target_properties(quickjs_spike PROPERTIES
  PREFIX "lib"
  OUTPUT_NAME "quickjs_spike"
)
