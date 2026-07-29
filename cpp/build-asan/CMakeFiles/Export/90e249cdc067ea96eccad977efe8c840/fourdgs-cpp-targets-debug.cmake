#----------------------------------------------------------------
# Generated CMake target import file for configuration "Debug".
#----------------------------------------------------------------

# Commands may need to know the format version.
set(CMAKE_IMPORT_FILE_VERSION 1)

# Import target "fourdgs::fourdgs-cpp" for configuration "Debug"
set_property(TARGET fourdgs::fourdgs-cpp APPEND PROPERTY IMPORTED_CONFIGURATIONS DEBUG)
set_target_properties(fourdgs::fourdgs-cpp PROPERTIES
  IMPORTED_LINK_INTERFACE_LANGUAGES_DEBUG "CXX"
  IMPORTED_LOCATION_DEBUG "${_IMPORT_PREFIX}/lib/libfourdgs-cpp.a"
  )

list(APPEND _cmake_import_check_targets fourdgs::fourdgs-cpp )
list(APPEND _cmake_import_check_files_for_fourdgs::fourdgs-cpp "${_IMPORT_PREFIX}/lib/libfourdgs-cpp.a" )

# Commands beyond this point should not need to know the version.
set(CMAKE_IMPORT_FILE_VERSION)
