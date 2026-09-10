# Make an iOS app image export the symbols its dlopened Bare modules resolve
# upward, and keep the archive members those symbols live in.
#
# A Bare module (ADR 0006) is a protocol-free framework linked with
# `-undefined dynamic_lookup`: every `lp_*` and every Qt symbol it uses is left
# undefined and bound to the app image at dlopen. Two things have to be true of
# the app for that to work, and neither is a linker default:
#
#   1. the symbol is IN the app. A static Qt is a pile of archives, and the
#      linker only pulls a member in if something already references it. Nothing
#      in the app references what only a module will call. `-u <sym>` forces the
#      member in and, because `-u` symbols are dead-strip roots, keeps it.
#   2. the symbol is EXPORTED by the app. Executables export their
#      default-visibility globals, so this comes free -- but "free" means
#      exporting all of them: measured on the spike's shell-preview, +908 KB
#      (a 431 KB export trie plus the code -dead_strip then had to keep) against
#      +65 KB for a list of 27. So the list is the default here and
#      EXPORT_ALL is a deliberate, noisy opt-out.
#
# Requires logos-nix's iOS Qt, which is built with reduce_exports off
# (nix/ios/qt-module.nix); with it on, Qt's API is `private external` in the
# archives, becomes local at link, and no amount of -u or -exported_symbols_list
# will put it in the app's export trie.
#
#   logos_ios_export_symbols(<target>
#       [SYMBOLS <name>...]        # linker spelling, i.e. a leading underscore
#       [SYMBOL_FILES <file>...]   # one name per line; `#` and blanks ignored
#       [NO_FORCE_LOAD]            # skip the -u references
#       [EXPORT_ALL]               # export everything; adds no list
#   )
#
# The usual producer of SYMBOL_FILES is the module set itself: the undefined
# symbols of each module image, intersected with what the app's libraries
# define. See docs/research/spikes/ios-dlopen-bare-module.md.

if(NOT COMMAND logos_ios_export_symbols)

function(logos_ios_export_symbols target)
    cmake_parse_arguments(PARSE_ARGV 1 arg
        "NO_FORCE_LOAD;EXPORT_ALL" "" "SYMBOLS;SYMBOL_FILES")
    if(arg_UNPARSED_ARGUMENTS)
        message(FATAL_ERROR "logos_ios_export_symbols: unknown argument(s): ${arg_UNPARSED_ARGUMENTS}")
    endif()
    if(NOT TARGET ${target})
        message(FATAL_ERROR "logos_ios_export_symbols: no such target: ${target}")
    endif()

    set(symbols ${arg_SYMBOLS})
    foreach(file IN LISTS arg_SYMBOL_FILES)
        # A path that moved would otherwise read as "this module needs nothing",
        # which links and installs and only fails at dlopen on the device.
        if(NOT EXISTS "${file}")
            message(FATAL_ERROR "logos_ios_export_symbols: no such symbol file: ${file}")
        endif()
        set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${file}")
        file(STRINGS "${file}" lines)
        foreach(line IN LISTS lines)
            string(STRIP "${line}" line)
            if(line AND NOT line MATCHES "^#")
                list(APPEND symbols "${line}")
            endif()
        endforeach()
    endforeach()
    list(REMOVE_DUPLICATES symbols)
    list(SORT symbols)

    if(NOT symbols AND NOT arg_EXPORT_ALL)
        message(FATAL_ERROR
            "logos_ios_export_symbols(${target}): no symbols. An empty list exports "
            "nothing, which links cleanly and then fails at dlopen; pass EXPORT_ALL "
            "if that is really what you want.")
    endif()

    if(NOT arg_NO_FORCE_LOAD)
        foreach(symbol IN LISTS symbols)
            target_link_options(${target} PRIVATE "LINKER:-u,${symbol}")
        endforeach()
    endif()

    if(arg_EXPORT_ALL)
        # Loud on purpose: this is the +908 KB shape, and it exports every
        # internal Qt symbol that survived to link time.
        message(WARNING
            "logos_ios_export_symbols(${target}): EXPORT_ALL -- the app exports every "
            "default-visibility global instead of the listed set.")
        return()
    endif()

    set(list_file "${CMAKE_CURRENT_BINARY_DIR}/${target}-exported-symbols.txt")
    list(JOIN symbols "\n" symbols_text)
    file(GENERATE OUTPUT "${list_file}" CONTENT "${symbols_text}\n")
    target_link_options(${target} PRIVATE "LINKER:-exported_symbols_list,${list_file}")
endfunction()

endif()
