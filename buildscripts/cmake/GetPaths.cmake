include(GetPlatformInfo)

if (OS_IS_MAC)
    set(INSTALL_SUBDIR "MuseScore Lite 4.app/Contents/MacOS/")
    set(INSTALL_BIN_DIR ${CMAKE_INSTALL_PREFIX}/${INSTALL_SUBDIR})
else()
    set(INSTALL_SUBDIR bin)
    set(INSTALL_BIN_DIR ${CMAKE_INSTALL_PREFIX}/${INSTALL_SUBDIR})
endif()
