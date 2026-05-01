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

# kintsuki: regenerate ares' resource.hpp/.cpp at configure time. Upstream
# uses a sourcery binary; we ship a Python stub generator instead since
# kintsuki is headless and never renders the bundled assets.
find_package(Python3 COMPONENTS Interpreter REQUIRED)
execute_process(
  COMMAND ${Python3_EXECUTABLE}
    ${CMAKE_CURRENT_SOURCE_DIR}/../scripts/gen_resource.py
    ${CMAKE_CURRENT_SOURCE_DIR}/ares/ares/resource/resource.bml
    ${CMAKE_CURRENT_SOURCE_DIR}/ares/ares/resource/resource.hpp
    ${CMAKE_CURRENT_SOURCE_DIR}/ares/ares/resource/resource.cpp
  RESULT_VARIABLE _gen_resource_rc
)
if(NOT _gen_resource_rc EQUAL 0)
  message(FATAL_ERROR "gen_resource.py failed (rc=${_gen_resource_rc})")
endif()

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
