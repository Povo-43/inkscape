# SPDX-License-Identifier: GPL-2.0-or-later

add_library(dialog_extension SHARED dialog-extension.cpp)
target_link_libraries(dialog_extension inkscape_base)
target_include_directories(dialog_extension PRIVATE ${CMAKE_BINARY_DIR}/src)

install(TARGETS dialog_extension
        LIBRARY DESTINATION ${CMAKE_INSTALL_DATADIR}/inkscape/extensions/dialog_extension
)
install(FILES dialog-extension.inx custom_gui.ui
        DESTINATION ${CMAKE_INSTALL_DATADIR}/inkscape/extensions/dialog_extension
)
