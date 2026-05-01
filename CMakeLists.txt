cmake_minimum_required(VERSION 3.28)

# Top-level wrapper so `cmake -S . -B build` works from the repo root.
# Real build logic lives in ares/CMakeLists.txt; this just delegates and
# saves the user from having to remember the subdirectory.

project(kintsuki-root)

add_subdirectory(ares)
