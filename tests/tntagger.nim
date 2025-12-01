import std/[unittest, os, strutils, sequtils]

import ntagger

proc writeSampleModule(dir: string): string =
  ## Write a small Nim module with several declarations that should
  ## produce tags and return its path.
  let path = dir / "sample_module.nim"
  let content = """
## Sample module for tag tests

type
  Foo* = object
    field: int

var
  globalVar*: int

let
  globalLet* = 42

const
  globalConst* = 3.14

proc publicProc*(x: int): int =
  result = x + 1

func inlineFunc*(x: int): int = x * 2

iterator items*(n: int): int =
  for i in 0 ..< n:
    yield i

method doSomething*(f: Foo): int =
  result = f.field

converter toFoo*(x: int): Foo =
  Foo(field: x)

macro myMacro*(body: untyped): untyped =
  body

template myTemplate*(x: int): int = x + 10
"""
  writeFile(path, content.strip & "\n")
  result = path

proc tagsLinesForDir(dir: string): seq[string] =
  let tagsText = generateCtagsForDir(dir)
  tagsText.splitLines.filterIt(it.len > 0)

suite "ctags output":
  test "header is extended ctags":
    let tmp = getTempDir() / "ntagger_test_header"
    createDir(tmp)
    discard writeSampleModule(tmp)

    let lines = tagsLinesForDir(tmp)
    check lines.len > 4
    check lines[0].startsWith("!_TAG_FILE_FORMAT\t2\t")
    check lines[1].startsWith("!_TAG_FILE_SORTED\t1\t")
    check lines[2].startsWith("!_TAG_PROGRAM_NAME\tntagger\t")

  test "tag lines follow extended format":
    let tmp = getTempDir() / "ntagger_test_tags"
    createDir(tmp)
    let modPath = writeSampleModule(tmp)

    let lines = tagsLinesForDir(tmp)
    # Skip header lines
    let tagLines = lines.filterIt(not it.startsWith("!_TAG_"))
    check tagLines.len > 0

    for line in tagLines:
      let cols = line.split('\t')
      # tagname, filename, ex-command;" and at least one extended field
      check cols.len >= 4
      check cols[0].len > 0
      check cols[1].endsWith(".nim")
      # Third field must end with ;" to be an ex-command
      check cols[2].endsWith(";\"")
      # At least one extended field must specify kind:...
      check cols[3].startsWith("kind:")

    # Ensure specific symbols are present
    let tagsText = generateCtagsForDir(tmp)
    check tagsText.contains("publicProc")
    check tagsText.contains("Foo")
    check tagsText.contains("globalVar")
    check tagsText.contains("myTemplate")
