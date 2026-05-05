# Two artifacts share the lua-free Program implementation:
#   libkintsuki.dylib (C ABI for ctypes / Swift hosts)
#   kintsuki         (CLI test runner with embedded LuaJIT)

# ---------------------------------------------------------------------------
# Linux aarch64 portable baseline
# ---------------------------------------------------------------------------
# CI builds the Linux ARM wheel on AWS Graviton (ARMv8.2-A + crc + crypto).
# Without an explicit -march, GCC defaults to whatever the build host
# advertises, which can include features the same wheel won't run on
# elsewhere (Apple Silicon under Docker Desktop / HVF lacks SVE; some
# guests strip BF16 / I8MM). Pin the lowest common denominator so the
# wheel runs on Graviton, Ampere, and Apple-virt aarch64 Linux containers
# alike.
if(CMAKE_SYSTEM_NAME STREQUAL "Linux"
   AND CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64|arm64")
  add_compile_options(-march=armv8.2-a+crc+crypto -mtune=generic)
endif()

# ---------------------------------------------------------------------------
# Shared Program object (compiled once)
# ---------------------------------------------------------------------------
add_library(kintsuki-program OBJECT program.cpp heuristics.cpp)

set_target_properties(kintsuki-program PROPERTIES
  CXX_STANDARD 20
  CXX_STANDARD_REQUIRED ON
  POSITION_INDEPENDENT_CODE ON
)

target_include_directories(kintsuki-program PUBLIC
  ${CMAKE_CURRENT_SOURCE_DIR}
  ${ares_SOURCE_DIR}
  ${ares_SOURCE_DIR}/ares
  ${ares_SOURCE_DIR}/nall
)

# Default location of ares' System/ tree (boards.bml + ipl.rom).
# ares_SOURCE_DIR resolves to the directory holding ares' CMakeLists, so
# this works whether kintsuki is configured at the repo root or at ares/.
target_compile_definitions(kintsuki-program PUBLIC
  KINTSUKI_SYSTEM_PAK_DEFAULT="${ares_SOURCE_DIR}/ares/System/Super Famicom"
)

target_link_libraries(kintsuki-program PUBLIC
  ares::ares
  ares::nall
)

# ---------------------------------------------------------------------------
# Shared library: C ABI shim
# ---------------------------------------------------------------------------
add_library(kintsuki SHARED libkintsuki.cpp adbg.cpp)

set_target_properties(kintsuki PROPERTIES
  CXX_STANDARD 20
  CXX_STANDARD_REQUIRED ON
  POSITION_INDEPENDENT_CODE ON
  CXX_VISIBILITY_PRESET default
  C_VISIBILITY_PRESET default
  VISIBILITY_INLINES_HIDDEN OFF
  OUTPUT_NAME kintsuki
  PREFIX "lib"
)

# ares sets -fvisibility=hidden on its targets; we need our extern "C" symbols
# visible on the shared library boundary.
target_compile_options(kintsuki PRIVATE -fvisibility=default)

target_link_libraries(kintsuki PRIVATE
  kintsuki-program
  ares::ares
  ares::nall
)

# ---------------------------------------------------------------------------
# Executable: Lua test runner CLI (LuaJIT 2.1, homebrew)
# ---------------------------------------------------------------------------
find_path(LUAJIT_INCLUDE_DIR lua.h
  HINTS /opt/homebrew/opt/luajit/include/luajit-2.1
        /usr/local/opt/luajit/include/luajit-2.1
        /usr/include/luajit-2.1)
find_library(LUAJIT_LIBRARY NAMES luajit-5.1
  HINTS /opt/homebrew/opt/luajit/lib
        /usr/local/opt/luajit/lib)

if(LUAJIT_INCLUDE_DIR AND LUAJIT_LIBRARY)
  add_executable(kintsuki-cli kintsuki_cli.cpp)

  set_target_properties(kintsuki-cli PROPERTIES
    CXX_STANDARD 20
    CXX_STANDARD_REQUIRED ON
    OUTPUT_NAME kintsuki
  )

  target_include_directories(kintsuki-cli PRIVATE ${LUAJIT_INCLUDE_DIR})
  # Link nall directly: it's an OBJECT library and CMake doesn't always
  # propagate object files transitively via PRIVATE deps.
  target_link_libraries(kintsuki-cli PRIVATE
    kintsuki-program
    ares::ares
    ares::nall
    ${LUAJIT_LIBRARY}
  )
else()
  message(STATUS "LuaJIT not found; skipping kintsuki CLI (install via `brew install luajit`)")
endif()
