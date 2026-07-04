package main

import "flyff"

main :: proc() {
  session: flyff.Session
  if !flyff.session_init(&session) {
    return
  }
  // The hotkey watcher (in package flyff) runs bound commands through this pointer, so flyff
  // never needs to import the cli/main package.
  session.exec_line = cli_execute_line
  defer flyff.session_close(&session)
  run_cli(&session)
}
