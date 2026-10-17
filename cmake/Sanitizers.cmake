function(marquee_enable_sanitizers target)
    if(NOT MARQUEE_ENABLE_SANITIZERS)
        return()
    endif()

    if(CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
        target_compile_options(${target} PRIVATE
            -fsanitize=address,undefined
            -fno-omit-frame-pointer
        )
        target_link_options(${target} PRIVATE
            -fsanitize=address,undefined
        )
    else()
        message(WARNING "MARQUEE_ENABLE_SANITIZERS is not supported by this compiler")
    endif()
endfunction()
