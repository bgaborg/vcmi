# OpenXR support for the Meta Quest build. Added after clientapp so that this file can hook
# itself into the existing client targets, which keeps the changes to upstream files minimal.

if(NOT ANDROID OR NOT ENABLE_SDL3)
	message(FATAL_ERROR "ENABLE_OPENXR requires an Android build with the SDL3 backend")
endif()

# Khronos OpenXR loader for Android (Apache-2.0 OR MIT). The same AAR is a Gradle dependency in
# android/vcmi-app/quest.gradle, which puts libopenxr_loader.so into the APK; keep both versions equal.
# Only the headers are taken from it here: the loader is opened at runtime.
set(OPENXR_LOADER_VERSION "1.1.65")
set(OPENXR_LOADER_SHA256 "a298c326085b09181c85235fb04d37510939bd30938ed4322c093c09780e8643")
set(OPENXR_LOADER_URL "https://repo1.maven.org/maven2/org/khronos/openxr/openxr_loader_for_android/${OPENXR_LOADER_VERSION}/openxr_loader_for_android-${OPENXR_LOADER_VERSION}.aar")

set(openxrAar "${CMAKE_CURRENT_BINARY_DIR}/openxr_loader_for_android-${OPENXR_LOADER_VERSION}.aar")
set(openxrDir "${CMAKE_CURRENT_BINARY_DIR}/openxr-${OPENXR_LOADER_VERSION}")

if(NOT EXISTS "${openxrDir}/prefab/modules/headers/include/openxr/openxr.h")
	file(DOWNLOAD "${OPENXR_LOADER_URL}" "${openxrAar}" EXPECTED_HASH SHA256=${OPENXR_LOADER_SHA256} STATUS downloadStatus)
	list(GET downloadStatus 0 downloadCode)
	if(NOT downloadCode EQUAL 0)
		message(FATAL_ERROR "Failed to download the OpenXR loader from ${OPENXR_LOADER_URL}: ${downloadStatus}")
	endif()
	file(ARCHIVE_EXTRACT INPUT "${openxrAar}" DESTINATION "${openxrDir}" PATTERNS "prefab/modules/headers/include/*")
endif()

set(vcmiXr_SRCS
	session/XrRuntimeProbe.cpp
)

set(vcmiXr_HEADERS
	session/XrRuntimeProbe.h
)

assign_source_group(${vcmiXr_SRCS} ${vcmiXr_HEADERS})

add_library(vcmiXr STATIC ${vcmiXr_SRCS} ${vcmiXr_HEADERS})

target_include_directories(vcmiXr PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
target_include_directories(vcmiXr SYSTEM PRIVATE "${openxrDir}/prefab/modules/headers/include")
# no link-time dependency on the loader: functions are resolved through xrGetInstanceProcAddr
target_compile_definitions(vcmiXr PRIVATE XR_NO_PROTOTYPES XR_USE_PLATFORM_ANDROID)
target_link_libraries(vcmiXr PRIVATE vcmi ${CMAKE_DL_LIBS})

target_link_libraries(vcmiclient PRIVATE vcmiXr)
target_compile_definitions(vcmiclient PRIVATE VCMI_OPENXR)
target_compile_definitions(vcmisdl3 PRIVATE VCMI_OPENXR)
