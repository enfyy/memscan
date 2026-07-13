package main

import "engine"
import "flyff"

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
  engine.run_repl(&session.eng)
}
