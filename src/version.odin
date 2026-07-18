package main

import "core:fmt"

// Human-readable project version. Bump this by hand when the project reaches a good state
// (the user drives this; see BACKLOG "Versioning"). The paired BUILD_HASH lives in the
// generated build_hash.g.odin and is refreshed from the current source tree on every
// build.bat run - so 'version' tells you exactly which build you are running and makes a
// stale build easy to spot (compare the hash against the one build.bat printed).
VERSION :: "1.0.0"

cli_version :: proc() {
  fmt.printfln("memscan v%s (build %s)", VERSION, BUILD_HASH)
}
