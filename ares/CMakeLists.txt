cmake_minimum_required(VERSION 3.28...4.1)

include("${CMAKE_CURRENT_SOURCE_DIR}/cmake/common/bootstrap.cmake" NO_POLICY_SCOPE)

project(ares VERSION ${ARES_VERSION_CANONICAL})

include(compilerconfig)
include(defaults)
include(helpers)

add_subdirectory(thirdparty)
add_subdirectory(nall/nall)
add_subdirectory(libco)

# kintsuki strips ares to SNES-only headless. ARES_CORES is a single-element
# list because mia/hiro/ruby/desktop-ui are gone — ares core builds as a
# static library only, the kintsuki target adds the platform shim + C ABI.
set(ARES_CORES sfc CACHE STRING "List of systems to be built by the project")

add_subdirectory(ares)

# kintsuki sibling project: target-kintsuki/ contains program.cpp +
# libkintsuki.cpp (C ABI) + kintsuki_cli.cpp (Lua test runner).
if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/../target-kintsuki/CMakeLists.txt")
  add_subdirectory(
    "${CMAKE_CURRENT_SOURCE_DIR}/../target-kintsuki"
    target-kintsuki
  )
endif()

message_configuration()
return()
