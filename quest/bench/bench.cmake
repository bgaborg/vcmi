# Object benchmark of the Quest build (quest/bench/ObjectBench.cpp), added to the Android build tree by
# quest/tools/object-bench.sh through CMAKE_PROJECT_VCMI_INCLUDE: no change to VCMI's CMake files. Not built by the APK
# build (EXCLUDE_FROM_ALL). Deferred to the end of the top directory, where the vcmi library target exists.
cmake_language(DEFER DIRECTORY "${CMAKE_SOURCE_DIR}" CALL _vcmi_quest_object_bench)
function(_vcmi_quest_object_bench)
	add_library(object-bench SHARED EXCLUDE_FROM_ALL
		"${CMAKE_SOURCE_DIR}/quest/bench/ObjectBench.cpp"
		"${CMAKE_SOURCE_DIR}/quest/bridge/ObjectScan.cpp")
	target_link_libraries(object-bench PRIVATE vcmi)
	# not next to the game's libraries, which the APK packages
	set_target_properties(object-bench PROPERTIES LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/object-bench")
endfunction()
