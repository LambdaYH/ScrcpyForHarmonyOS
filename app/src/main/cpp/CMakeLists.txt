cmake_minimum_required(VERSION 3.5.0)
project(scrcpy_native)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})
set(BORINGSSL_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR}/thirdparty/boringssl)
set(BUILD_TESTING OFF CACHE BOOL "" FORCE)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(OPENSSL_NO_ASM ON CACHE BOOL "" FORCE)

add_subdirectory(${BORINGSSL_ROOT_PATH} ${CMAKE_CURRENT_BINARY_DIR}/boringssl)

get_property(BORINGSSL_TARGETS DIRECTORY ${BORINGSSL_ROOT_PATH} PROPERTY BUILDSYSTEM_TARGETS)
foreach(BORINGSSL_TARGET ${BORINGSSL_TARGETS})
    if(TARGET ${BORINGSSL_TARGET})
        target_compile_options(${BORINGSSL_TARGET} PRIVATE
            -Wno-unused-command-line-argument
            -Wno-error=unused-command-line-argument
        )
    endif()
endforeach()

include_directories(${NATIVERENDER_ROOT_PATH} ${NATIVERENDER_ROOT_PATH}/thirdparty)

add_library(scrcpy_native SHARED
    decoder/VideoDecoderNative.cpp
    decoder/AudioDecoderNative.cpp

    manager/ScrcpyStreamManager.cpp
    manager/ScrcpyStreamManagerLifecycle.cpp
    manager/ScrcpyStreamManagerVideo.cpp
    manager/ScrcpyStreamManagerAudio.cpp
    manager/ScrcpyStreamManagerControl.cpp
    manager/ScrcpyStreamManagerReverse.cpp
    stream/adapters/ForwardStreamAdapter.cpp
    stream/adapters/ReverseStreamAdapter.cpp
    stream/StreamIO.cpp
    adb/core/AdbProtocol.cpp
    adb/channel/LocalSocketChannel.cpp
    adb/channel/TcpChannel.cpp
    adb/channel/TlsAdbChannel.cpp
    adb/crypto/AdbKeyPair.cpp
    adb/core/Adb.cpp
    adb/pairing/PairingAuth.cpp
    adb/pairing/TlsConnection.cpp
    adb/pairing/AdbPair.cpp
    napi_init.cpp
)

target_include_directories(scrcpy_native PRIVATE
    ${BORINGSSL_ROOT_PATH}/include
)

target_link_libraries(scrcpy_native PUBLIC
    ssl
    crypto
    libace_ndk.z.so
    libace_napi.z.so
    libhilog_ndk.z.so
    libnative_media_codecbase.so
    libnative_media_core.so
    libnative_media_vdec.so
    libnative_media_acodec.so
    libnative_window.so
    libohaudio.so
    libohcrypto.so
)

