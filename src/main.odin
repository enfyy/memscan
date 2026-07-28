package main

import "engine"
import "flyff"

// Which module owns the process at startup, chosen at COMPILE time:
//
//   odin build src -define:MAIN_MODULE=flyff      (or: build.bat debug flyff)
//
// With it set, that module takes control as soon as the session is up: it opens its own UI
// immediately (session.open_ui) and the process ends when that window closes - no REPL is ever
// started. Without it (the default) we launch the REPL and the module is reached the usual way,
// through its commands ('radar' / 'module flyff').
MAIN_MODULE :: #config(MAIN_MODULE, "")

// Every module name MAIN_MODULE accepts. flyff is the only module registered (flyff.session_init ->
// flyff_register), so anything else is a typo - fail the BUILD instead of shipping an exe that
// silently falls back to the REPL.
when MAIN_MODULE != "" && MAIN_MODULE != "flyff" {
  #panic(
    "unknown -define:MAIN_MODULE=" +
    MAIN_MODULE +
    " - the only module is 'flyff'. Omit the define to build the REPL.",
  )
}

main :: proc() {
  // The concrete storage is a flyff.Session (it embeds engine.Session as its first field). We init
  // the flyff module - which inits the engine + registers the flyff hooks - then hand the generic
  // engine session to the REPL. The REPL is Flyff-agnostic; it reaches flyff through the hooks.
  session: flyff.Session
  if !flyff.session_init(&session) {
    return
  }
  // Inject app identity so the generic `version` command can print it without engine depending on
  // main's generated VERSION / BUILD_HASH constants.
  session.app_version = VERSION
  session.app_build_hash = BUILD_HASH
  defer flyff.session_close(&session)
  when MAIN_MODULE != "" {
    // Main-module build: the module drives. It owns the process until its window closes; only a
    // module with no UI hook falls through to the REPL below (run_module_ui says so on stderr).
    if engine.run_module_ui(&session.eng) {
      return
    }
  }
  engine.run_repl(&session.eng)
}
