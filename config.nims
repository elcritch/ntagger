# NimScript configuration and tasks for this repo
import std/[os, strformat, strutils]
import std/compilesettings
let nc = querySetting(libPath).splitFile.dir
let testDir = "tests"

switch("path", nc)
switch("nimcache", ".nimcache")

task test, "Compile and run all tests in tests/":
  withDir(testDir):
    for kind, path in walkDir("."):
      if kind == pcFile and path.endsWith(".nim") and not path.endsWith("config.nims"):
        let name = splitFile(path).name
        if not name.startsWith("t"): continue # run only t*.nim files
        echo fmt"[sigils] Running {path}"
        exec fmt"nim c --nimcache:../.nimcache -r {path}"

# begin Nimble config (version 2)
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config
