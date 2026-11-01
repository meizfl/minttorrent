cmake_minimum_required(VERSION 3.20)
project(MintTorrent LANGUAGES NONE)

if(NOT CMAKE_HOST_SYSTEM_NAME STREQUAL "Linux")
    message(FATAL_ERROR
        "The root CMake server builder targets Linux only. "
        "For Windows desktop cross-builds use scripts/build-desktop.sh windows.")
endif()

foreach(tool IN ITEMS bash go tar ldd readelf python3)
    string(TOUPPER "${tool}" tool_upper)
    find_program(MINTTORRENT_${tool_upper}_EXECUTABLE NAMES "${tool}")
    if(NOT MINTTORRENT_${tool_upper}_EXECUTABLE)
        message(FATAL_ERROR "Required build tool not found: ${tool}")
    endif()
endforeach()

set(MINTTORRENT_BUILD_ROOT "${CMAKE_BINARY_DIR}/artifacts" CACHE PATH
    "Directory for MintTorrent component build outputs")
set(MINTTORRENT_DIST_DIR "${CMAKE_BINARY_DIR}/dist" CACHE PATH
    "Directory for the standalone MintTorrent bundle")

set(MINTTORRENT_BUILD_JOBS "4" CACHE STRING
    "Maximum parallel C++ build jobs")

file(STRINGS "${CMAKE_CURRENT_SOURCE_DIR}/VERSION" MINTTORRENT_VERSION LIMIT_COUNT 1)
execute_process(
    COMMAND uname -m
    OUTPUT_VARIABLE MINTTORRENT_HOST_ARCH
    OUTPUT_STRIP_TRAILING_WHITESPACE
    COMMAND_ERROR_IS_FATAL ANY)
set(MINTTORRENT_BUNDLE_NAME
    "MintTorrent-${MINTTORRENT_VERSION}-${MINTTORRENT_HOST_ARCH}-unknown-linux-gnu")

set(_bundle_archive "${MINTTORRENT_DIST_DIR}/${MINTTORRENT_BUNDLE_NAME}.tar.gz")
set(_bundle_checksum "${_bundle_archive}.sha256")

add_custom_target(minttorrent ALL
    COMMAND "${CMAKE_COMMAND}" -E env
        "MINTTORRENT_BUILD_ROOT=${MINTTORRENT_BUILD_ROOT}"
        "MINTTORRENT_DIST_DIR=${MINTTORRENT_DIST_DIR}"
        "MINTTORRENT_BUILD_JOBS=${MINTTORRENT_BUILD_JOBS}"
        "GOCACHE=${MINTTORRENT_BUILD_ROOT}/go-cache"
        "${MINTTORRENT_BASH_EXECUTABLE}"
        "${CMAKE_CURRENT_SOURCE_DIR}/scripts/build-bundle.sh"
    BYPRODUCTS "${_bundle_archive}" "${_bundle_checksum}"
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
    USES_TERMINAL
    COMMENT "Building MintTorrent components and standalone bundle")

add_custom_target(minttorrent-smoke
    COMMAND "${MINTTORRENT_BASH_EXECUTABLE}"
        "${CMAKE_CURRENT_SOURCE_DIR}/scripts/smoke-bundle.sh"
        "${MINTTORRENT_DIST_DIR}/${MINTTORRENT_BUNDLE_NAME}"
    DEPENDS minttorrent
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
    USES_TERMINAL
    COMMENT "Running the loopback-only bundle smoke check")

add_custom_target(minttorrent-netstack-check
    COMMAND "${MINTTORRENT_BASH_EXECUTABLE}"
        "${CMAKE_CURRENT_SOURCE_DIR}/scripts/test-qbittorrent-host-interface-isolation.sh"
        "${MINTTORRENT_BUILD_ROOT}/qbittorrent-nox-build"
    COMMAND "${CMAKE_COMMAND}" -E env
        "MINTTORRENT_BUILD_ROOT=${MINTTORRENT_BUILD_ROOT}"
        "${MINTTORRENT_BASH_EXECUTABLE}"
        "${CMAKE_CURRENT_SOURCE_DIR}/scripts/test-netstack-socket-retry.sh"
    DEPENDS minttorrent
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
    USES_TERMINAL
    COMMENT "Checking the C++ userspace TCP/UDP socket adapters")

add_custom_target(minttorrent-cli-check
    COMMAND "${MINTTORRENT_BASH_EXECUTABLE}"
        "${CMAKE_CURRENT_SOURCE_DIR}/scripts/test-cli.sh"
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
    USES_TERMINAL
    COMMENT "Checking launcher and CLI command routing")

add_custom_target(minttorrent-cli-go-check
    COMMAND "${CMAKE_COMMAND}" -E env
        "GOCACHE=${MINTTORRENT_BUILD_ROOT}/go-cache"
        "${MINTTORRENT_GO_EXECUTABLE}" test -count=1 ./...
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/components/cli"
    USES_TERMINAL
    COMMENT "Running MintTorrent CLI Go tests")

add_custom_target(minttorrent-awg-go-check
    COMMAND "${CMAKE_COMMAND}" -E env
        "GOCACHE=${MINTTORRENT_BUILD_ROOT}/go-cache"
        "${MINTTORRENT_GO_EXECUTABLE}" test -race -count=1 -tags awgnet_test ./...
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/components/awgnet"
    USES_TERMINAL
    COMMENT "Running AmneziaWG/gVisor bridge race tests")

add_custom_target(minttorrent-update-validation-check
    COMMAND "${MINTTORRENT_BASH_EXECUTABLE}"
        "${CMAKE_CURRENT_SOURCE_DIR}/scripts/test-update-validation.sh"
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
    USES_TERMINAL
    COMMENT "Checking update archive and checksum validation")

add_custom_target(minttorrent-update-rollback-check
    COMMAND "${MINTTORRENT_BASH_EXECUTABLE}"
        "${CMAKE_CURRENT_SOURCE_DIR}/scripts/test-update-rollback.sh"
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
    USES_TERMINAL
    COMMENT "Checking update rollback in a user namespace")

add_custom_target(minttorrent-update-preservation-check
    COMMAND "${MINTTORRENT_BASH_EXECUTABLE}"
        "${CMAKE_CURRENT_SOURCE_DIR}/scripts/test-update-preservation.sh"
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
    USES_TERMINAL
    COMMENT "Checking successful update preserves operator data")

add_custom_target(minttorrent-packet-capture-check
    COMMAND "${MINTTORRENT_PYTHON3_EXECUTABLE}"
        "${CMAKE_CURRENT_SOURCE_DIR}/scripts/test-packet-capture-parser.py"
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
    USES_TERMINAL
    COMMENT "Checking IPv4/IPv6 packet-capture leak analysis")

add_custom_target(minttorrent-check
    DEPENDS minttorrent-smoke minttorrent-netstack-check minttorrent-cli-check
        minttorrent-cli-go-check minttorrent-awg-go-check
        minttorrent-update-validation-check minttorrent-update-rollback-check
        minttorrent-update-preservation-check minttorrent-packet-capture-check
    COMMENT "Running MintTorrent build checks")

add_custom_target(minttorrent-clean
    COMMAND "${CMAKE_COMMAND}" -E rm -rf
        "${MINTTORRENT_BUILD_ROOT}" "${MINTTORRENT_DIST_DIR}"
    COMMENT "Removing MintTorrent build artifacts and bundles")

message(STATUS "MintTorrent version: ${MINTTORRENT_VERSION}")
message(STATUS "Component outputs: ${MINTTORRENT_BUILD_ROOT}")
message(STATUS "Standalone bundle: ${_bundle_archive}")
message(STATUS "C++ parallel jobs: ${MINTTORRENT_BUILD_JOBS}")
