find_package(Qt6 6.8 REQUIRED COMPONENTS Core Gui Qml Quick QuickControls2 Test)

function(marquee_add_test target)
    qt_add_executable(${target} ${ARGN})
    target_link_libraries(${target} PRIVATE
        marquee_core
        marquee_coreplugin
        Qt6::Test)
    target_include_directories(${target} PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
    marquee_set_project_warnings(${target})
    marquee_enable_sanitizers(${target})
    add_test(NAME ${target} COMMAND ${target})
    set_tests_properties(${target} PROPERTIES
        ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QPA_PLATFORMTHEME=none"
    )
endfunction()

marquee_add_test(tst_navigation_controller
    navigation/tst_navigation_controller.cpp
)

marquee_add_test(tst_focus_navigator
    navigation/tst_focus_navigator.cpp
)

marquee_add_test(tst_navigation_keyboard
    navigation/tst_navigation_keyboard.cpp
)

set_tests_properties(tst_navigation_keyboard PROPERTIES
    ENVIRONMENT "QT_QPA_PLATFORM=minimal;QT_QPA_PLATFORMTHEME=none"
)

marquee_add_test(tst_sidebar_navigation
    navigation/tst_sidebar_navigation.cpp
)

# The sidebar needs key delivery, a laid-out window for its geometry
# assertions, and a real rendered image for its painted symbol-ink and
# Play Something surface assertions. The offscreen platform supplies all three.
set_tests_properties(tst_sidebar_navigation PROPERTIES
    ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QPA_PLATFORMTHEME=none"
)

# Painted sidebar chrome is judged in captured device pixels against logical
# scene geometry, so the whole sequence runs again at a doubled device pixel
# ratio.
add_test(NAME tst_sidebar_navigation_hidpi COMMAND tst_sidebar_navigation)
set_tests_properties(tst_sidebar_navigation_hidpi PROPERTIES
    ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QPA_PLATFORMTHEME=none;QT_SCALE_FACTOR=2"
)

marquee_add_test(tst_startup_smoke
    navigation/tst_startup_smoke.cpp
)

marquee_add_test(tst_settings_store
    navigation/tst_settings_store.cpp
)

marquee_add_test(tst_catalog_bootstrap
    catalog/tst_catalog_bootstrap.cpp
)

marquee_add_test(tst_library_scanner
    catalog/tst_library_scanner.cpp
)

marquee_add_test(tst_tv_scanner
    catalog/tst_tv_scanner.cpp
)

marquee_add_test(tst_library_browse
    browse/tst_library_browse.cpp
)

# The browse surface needs key delivery and a real rendered image for its
# default painted-chrome assertions. The offscreen platform supplies both.
set_tests_properties(tst_library_browse PROPERTIES
    ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QPA_PLATFORMTHEME=none"
)

# Painted chrome is judged in captured device pixels against logical scene
# geometry, so the complete browse sequence runs again at a doubled device
# pixel ratio.
add_test(NAME tst_library_browse_hidpi COMMAND tst_library_browse)
set_tests_properties(tst_library_browse_hidpi PROPERTIES
    ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QPA_PLATFORMTHEME=none;QT_SCALE_FACTOR=2"
)

marquee_add_test(tst_home_rows
    browse/tst_home_rows.cpp
)

# The hero's selection rules, its carousel position and timer, and the remote's
# walk over hero, capsule and rows are plain model behaviour: no window.
marquee_add_test(tst_hero_spotlight
    browse/tst_hero_spotlight.cpp
)

# Home's titled rows need key and pointer delivery into the shipped QML scene.
marquee_add_test(tst_home_screen
    browse/tst_home_screen.cpp
)

# Play Something's pick is a plain function over projected items: no window.
marquee_add_test(tst_play_something
    browse/tst_play_something.cpp
)

# Browse order, genre rows and the holiday score are plain functions and models
# over projected items: no window.
marquee_add_test(tst_browse_order
    browse/tst_browse_order.cpp
)

# The taste model behind Home's taste rows and Play Something's weight is a
# plain function over projected items: no window.
marquee_add_test(tst_taste_model
    browse/tst_taste_model.cpp
)

# Home's taste and seasonal rows, composed and as the model serves them.
marquee_add_test(tst_home_taste_rows
    browse/tst_home_taste_rows.cpp
)

# October Horror and Summer Blockbusters, with the date they read pinned.
marquee_add_test(tst_seasonal_rows
    browse/tst_seasonal_rows.cpp
)

# The similarity ranking behind Because You Watched: plain functions over
# projected items.
marquee_add_test(tst_similarity_index
    browse/tst_similarity_index.cpp
)

marquee_add_test(tst_movies_route
    browse/tst_movies_route.cpp
)

marquee_add_test(tst_tv_route
    browse/tst_tv_route.cpp
)
set_tests_properties(tst_tv_route PROPERTIES
    ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QPA_PLATFORMTHEME=none"
)

# The Movies route needs key delivery and a laid-out window for its geometry
# and placement assertions. The offscreen platform supplies both.
set_tests_properties(tst_movies_route PROPERTIES
    ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QPA_PLATFORMTHEME=none"
)

# The route's bottom fade is judged in captured device pixels against logical
# scene geometry, so the complete Movies sequence runs again at a doubled
# device pixel ratio.
add_test(NAME tst_movies_route_hidpi COMMAND tst_movies_route)
set_tests_properties(tst_movies_route_hidpi PROPERTIES
    ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QPA_PLATFORMTHEME=none;QT_SCALE_FACTOR=2"
)

marquee_add_test(tst_media_details
    details/tst_media_details.cpp
)

# The details surface needs key delivery and a real rendered image for its
# painted focus-chrome assertions. The offscreen platform supplies both.
set_tests_properties(tst_media_details PROPERTIES
    ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QPA_PLATFORMTHEME=none"
)

marquee_add_test(tst_watch_progress
    playback/tst_watch_progress.cpp
)

qt_add_executable(marquee_watch_progress_shutdown_child
    playback/watch_progress_shutdown_child.cpp
)
target_link_libraries(marquee_watch_progress_shutdown_child PRIVATE
    marquee_core
    marquee_coreplugin
)
marquee_set_project_warnings(marquee_watch_progress_shutdown_child)
marquee_enable_sanitizers(marquee_watch_progress_shutdown_child)

marquee_add_test(tst_watch_progress_process
    playback/tst_watch_progress_process.cpp
)
add_dependencies(tst_watch_progress_process marquee_watch_progress_shutdown_child)

# The keys' timing runs on a clock the test moves by hand, so it needs no
# window and no libmpv.
marquee_add_test(tst_seek_scrubber
    playback/tst_seek_scrubber.cpp
)

# The lead time, the order of episodes and the "Still watching?" rule are plain
# functions with an injectable clock: no window, no libmpv.
marquee_add_test(tst_next_episode
    playback/tst_next_episode.cpp
)

marquee_add_test(tst_player_hud
    playback/tst_player_hud.cpp
)

# The HUD's controls need real key and pointer delivery into the shipped QML
# scene, which the offscreen platform does not provide, and its auto-hide runs
# on a QML timer the animation driver only advances for a window a compositor
# has exposed.
set_tests_properties(tst_player_hud PROPERTIES
    ENVIRONMENT "QT_QPA_PLATFORM=minimal;QT_QPA_PLATFORMTHEME=none"
)

# The Next Episode control, card and "Still watching?" prompt in the shipped
# player screen need key and pointer delivery and the screen's timers, like
# the HUD's own cases.
marquee_add_test(tst_next_episode_flow
    playback/tst_next_episode_flow.cpp
)
set_tests_properties(tst_next_episode_flow PROPERTIES
    ENVIRONMENT "QT_QPA_PLATFORM=minimal;QT_QPA_PLATFORMTHEME=none"
)

marquee_add_test(tst_track_selection
    playback/tst_track_selection.cpp
)

marquee_add_test(tst_subtitle_discovery
    playback/tst_subtitle_discovery.cpp
)

# The item opens a real clip through libmpv and the test hands it the render
# context the scene graph would, so the track lists need no display.
marquee_add_test(tst_player_tracks
    playback/tst_player_tracks.cpp
)

# The window system's state reports are fed in by hand, as a compositor sends
# them; the minimal platform adds none of its own. QWindowSystemInterface is Qt's
# own private GUI API, so the test needs Qt's private development files, which
# some distributions ship separately; without them only this test is left out.
set(QT_NO_PRIVATE_MODULE_WARNING ON)
find_package(Qt6 6.8 QUIET COMPONENTS GuiPrivate)
if(TARGET Qt6::GuiPrivate)
    marquee_add_test(tst_playback_fullscreen
        playback/tst_playback_fullscreen.cpp
    )
    target_link_libraries(tst_playback_fullscreen PRIVATE Qt6::GuiPrivate)
    set_tests_properties(tst_playback_fullscreen PROPERTIES
        ENVIRONMENT "QT_QPA_PLATFORM=minimal;QT_QPA_PLATFORMTHEME=none"
    )
else()
    message(STATUS "tst_playback_fullscreen skipped: Qt6::GuiPrivate not found")
endif()

marquee_add_test(tst_player_window
    playback/tst_player_window.cpp
)

# The title shadow needs the OpenGL scene graph, which the offscreen platform
# does not provide, so the binary builds the same platform fallback chain as
# tst_playback and the shell's own QT_QPA_PLATFORM must not reach it. Every
# other case here runs on whichever platform connects. Each case builds and
# tears down its own window. Across those windows Qt's text node crashes now
# and then on either render loop (issues.md); the basic loop keeps the crash on
# the GUI thread, where its stack is readable.
set_tests_properties(tst_player_window PROPERTIES
    ENVIRONMENT "QT_QPA_PLATFORMTHEME=none;QSG_RENDER_LOOP=basic"
    ENVIRONMENT_MODIFICATION "QT_QPA_PLATFORM=unset:"
)

marquee_add_test(tst_playback
    playback/tst_playback.cpp
)

# The libmpv surface needs the OpenGL scene graph, which the offscreen platform
# does not provide, so the test binary builds a platform fallback chain from the
# live session's display variables and skips its rendering cases when nothing
# connects. The shell's own QT_QPA_PLATFORM must not reach it, or a session-wide
# offscreen or xcb setting would turn the rendering cases into silent skips.
set_tests_properties(tst_playback PROPERTIES
    ENVIRONMENT "QT_QPA_PLATFORMTHEME=none"
    ENVIRONMENT_MODIFICATION "QT_QPA_PLATFORM=unset:"
)

marquee_add_test(tst_profile_store
    profiles/tst_profile_store.cpp
)

marquee_add_test(tst_profile_picker
    profiles/tst_profile_picker.cpp
)

marquee_add_test(tst_kids_content
    profiles/tst_kids_content.cpp
)

marquee_add_test(tst_search_session
    search/tst_search_session.cpp
)

marquee_add_test(tst_search_screen
    search/tst_search_screen.cpp
)

marquee_add_test(tst_settings_screen
    settings/tst_settings_screen.cpp
)

# TMDB: the client, its parsing, the key and the artwork cache, all over saved
# JSON and a fake transport, so nothing here reaches the network.
marquee_add_test(tst_metadata_client
    metadata/tst_metadata_client.cpp
)
target_compile_definitions(tst_metadata_client PRIVATE
    MARQUEE_METADATA_FIXTURES="${CMAKE_CURRENT_SOURCE_DIR}/metadata/fixtures"
)

# One enrichment run over a synthetic library: what it stores, what it skips,
# what it does offline, without a key, with the switch off, and after a restart.
marquee_add_test(tst_metadata_enrichment
    metadata/tst_metadata_enrichment.cpp
)
target_compile_definitions(tst_metadata_enrichment PRIVATE
    MARQUEE_METADATA_FIXTURES="${CMAKE_CURRENT_SOURCE_DIR}/metadata/fixtures"
)

# The Online Metadata switch, its key note, and the key lookup.
marquee_add_test(tst_metadata_switch
    metadata/tst_metadata_switch.cpp
)

# The stored TMDB fields on the models' roles.
marquee_add_test(tst_metadata_models
    metadata/tst_metadata_models.cpp
)
