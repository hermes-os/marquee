cmake_minimum_required(VERSION 3.24)

project(Marquee
    VERSION 3.0.0
    DESCRIPTION "Native local home-theater library browser"
    LANGUAGES CXX
)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

option(MARQUEE_BUILD_TESTS "Build Marquee tests" ON)
option(MARQUEE_ENABLE_SANITIZERS "Enable address and undefined-behavior sanitizers" OFF)
option(MARQUEE_WARNINGS_AS_ERRORS "Treat compiler warnings as errors" OFF)

include(GNUInstallDirs)
include(cmake/CompilerWarnings.cmake)
include(cmake/Sanitizers.cmake)

find_package(Qt6 6.8 REQUIRED COMPONENTS
    Concurrent
    Core
    Gui
    OpenGL
    Qml
    Quick
    QuickControls2
    ShaderTools
    Sql
)

find_package(PkgConfig REQUIRED)
pkg_check_modules(MPV REQUIRED IMPORTED_TARGET mpv)

qt_standard_project_setup(REQUIRES 6.8)

set_source_files_properties(qml/Theme.qml PROPERTIES
    QT_QML_SINGLETON_TYPE TRUE
)

# The QML module lives in a static library so tests link the shipped module
# instead of re-listing sources or reimplementing QML surfaces.
qt_add_library(marquee_core STATIC)

qt_add_qml_module(marquee_core
    URI Marquee
    VERSION 3.0

    # Keep the tooling copy of the module out of the app binary's directory:
    # the QML engine scans the executable's directory as an import path, and a
    # disk qmldir there conflicts with the statically linked registration.
    OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/qml/Marquee"

    QML_FILES
        qml/Main.qml
        qml/Theme.qml
        qml/components/ConfirmDialog.qml
        qml/components/DetailCapsuleButton.qml
        qml/components/EpisodeRow.qml
        qml/components/ErrorToast.qml
        qml/components/FocusFrame.qml
        qml/components/GradientWordmark.qml
        qml/components/HeroCarousel.qml
        qml/components/MarqueeSymbol.qml
        qml/components/MediaItemRow.qml
        qml/components/PlayerCardButton.qml
        qml/components/PlayerHudButton.qml
        qml/components/PlayerTrackMenu.qml
        qml/components/PlayerVolumeSlider.qml
        qml/components/PosterArt.qml
        qml/components/PosterCard.qml
        qml/components/ProfileCard.qml
        qml/components/ProfileEditor.qml
        qml/components/ProfileManagementTile.qml
        qml/components/RemoteSearchKeyboard.qml
        qml/components/SettingsPicker.qml
        qml/components/SettingsFolderList.qml
        qml/components/SettingsSlider.qml
        qml/components/SettingsSwitch.qml
        qml/components/ShowCardRow.qml
        qml/components/Sidebar.qml
        qml/components/SoftShadow.qml
        qml/components/TransitionLoading.qml
        qml/screens/DetailsScreen.qml
        qml/screens/HomeScreen.qml
        qml/screens/MoviesScreen.qml
        qml/screens/PlayerScreen.qml
        qml/screens/ProfilePickerScreen.qml
        qml/screens/SearchScreen.qml
        qml/screens/SettingsScreen.qml
        qml/screens/ShowDetailScreen.qml
        qml/screens/ShowsScreen.qml
        qml/screens/WelcomeScreen.qml

    RESOURCES
        resources/icons/marquee.svg
        qml/components/SymbolPaths.js

    SOURCES
        src/app/AppPaths.hpp
        src/app/AppPaths.cpp
        src/app/ApplicationController.hpp
        src/app/ApplicationController.cpp

        src/catalog/CatalogDatabase.hpp
        src/catalog/CatalogDatabase.cpp
        src/catalog/CatalogStore.hpp
        src/catalog/CatalogStore.cpp
        src/catalog/CatalogWorker.hpp
        src/catalog/CatalogWorker.cpp
        src/catalog/LibraryRoot.hpp
        src/catalog/LibraryScanner.hpp
        src/catalog/LibraryScanner.cpp
        src/catalog/MediaItem.hpp

        src/models/BrowseSemantics.hpp
        src/models/BrowseSemantics.cpp
        src/models/HeroSpotlight.hpp
        src/models/HeroSpotlight.cpp
        src/models/HomeRowsModel.hpp
        src/models/HomeRowsModel.cpp
        src/models/LibraryModel.hpp
        src/models/LibraryModel.cpp
        src/models/MovieRowsModel.hpp
        src/models/MovieRowsModel.cpp
        src/models/PlaySomething.hpp
        src/models/PlaySomething.cpp
        src/models/ShowsModel.hpp
        src/models/ShowsModel.cpp

        src/navigation/FocusNavigator.hpp
        src/navigation/FocusNavigator.cpp
        src/navigation/NavigationController.hpp
        src/navigation/NavigationController.cpp

        src/playback/AutoPlayPolicy.hpp
        src/playback/AutoPlayPolicy.cpp
        src/playback/MpvVideoItem.hpp
        src/playback/MpvVideoItem.cpp
        src/playback/NextEpisodeCard.hpp
        src/playback/NextEpisodeCard.cpp
        src/playback/PlaybackFullscreen.hpp
        src/playback/PlaybackFullscreen.cpp
        src/playback/PlayerController.hpp
        src/playback/PlayerController.cpp
        src/playback/SeekScrubber.hpp
        src/playback/SeekScrubber.cpp
        src/playback/SubtitleDiscovery.hpp
        src/playback/SubtitleDiscovery.cpp
        src/playback/TrackSelection.hpp
        src/playback/TrackSelection.cpp

        src/profiles/ContentPolicy.hpp
        src/profiles/ContentPolicy.cpp
        src/profiles/ProfileStore.hpp
        src/profiles/ProfileStore.cpp

        src/search/SearchSession.hpp
        src/search/SearchSession.cpp

        src/settings/SettingsSession.hpp
        src/settings/SettingsSession.cpp
        src/settings/SettingsStore.hpp
        src/settings/SettingsStore.cpp

        src/support/AppError.hpp
        src/support/FileIdentity.hpp
        src/support/FileIdentity.cpp
        src/support/Logging.hpp
        src/support/Logging.cpp

        src/ui/FocusRing.hpp
        src/ui/FocusRing.cpp
)

qt_add_shaders(marquee_core "marquee_shaders"
    PREFIX "/qt/qml/Marquee"
    FILES qml/shaders/wordmarkgradient.frag
)

target_include_directories(marquee_core PUBLIC src)

# The generated qmltyperegistrations unit includes QML_ELEMENT headers by
# basename, so their directories must be resolvable on this target.
target_include_directories(marquee_core PRIVATE
    src/navigation
    src/playback
    src/profiles
    src/search
    src/settings
    src/ui
)

target_compile_definitions(marquee_core PUBLIC
    MARQUEE_VERSION="${PROJECT_VERSION}"
)

target_link_libraries(marquee_core PUBLIC
    Qt6::Concurrent
    Qt6::Core
    Qt6::Gui
    Qt6::OpenGL
    Qt6::Qml
    Qt6::Quick
    Qt6::QuickControls2
    Qt6::Sql
    PkgConfig::MPV
)

marquee_set_project_warnings(marquee_core)
marquee_enable_sanitizers(marquee_core)

qt_add_executable(marquee
    src/main.cpp
)

target_link_libraries(marquee PRIVATE
    marquee_core
    marquee_coreplugin
)

marquee_set_project_warnings(marquee)
marquee_enable_sanitizers(marquee)

install(TARGETS marquee
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
)

if(MARQUEE_BUILD_TESTS)
    enable_testing()
    add_subdirectory(tests)
endif()
