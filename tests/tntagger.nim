import std/[unittest, os, strutils, sequtils]

import ntagger

proc sampleDir(): string =
  ## Resolve the location of the sample1 test directory
  ## regardless of whether the test is run from the repo root
  ## or from within the tests/ directory.
  let cwd = getCurrentDir()
  if dirExists(cwd / "sample1"):
    result = cwd / "sample1"
  elif dirExists(cwd / "tests" / "sample1"):
    result = cwd / "tests" / "sample1"
  else:
    raise newException(OSError, "sample1 test directory not found")

proc tagsLinesForDir(dir: string): seq[string] =
  let tagsText = generateCtagsForDir(dir)
  tagsText.splitLines.filterIt(it.len > 0)

suite "ctags output":
  test "header is extended ctags":
    let tmp = sampleDir()
    let lines = tagsLinesForDir(tmp)
    for line in lines:
      echo "LINE: ", line
    check lines.len >= 4
    check lines[0].startsWith("!_TAG_FILE_FORMAT\t2\t")
    check lines[1].startsWith("!_TAG_FILE_SORTED\t1\t")
    check lines[2].startsWith("!_TAG_PROGRAM_NAME\tntagger\t")

  test "tag lines follow extended format":
    let tmp = sampleDir()
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
    # And that private symbols are not exported
    check not tagsText.contains("privateProc")

    # Verify that routine tags include a signature field.
    let publicLine = tagLines.filterIt(it.startsWith("publicProc\t"))
    check publicLine.len == 1
    let publicCols = publicLine[0].split('\t')
    let sigField = publicCols.filterIt(it.startsWith("signature:"))
    check sigField.len == 1
    check sigField[0].contains("x: int")

  test "exclude patterns skip matching files":
    let tmp = sampleDir()

    let allLines = tagsLinesForDir(tmp)
    let allTagLines = allLines.filterIt(not it.startsWith("!_TAG_"))
    check allTagLines.len > 0

    # Exclude the only Nim file in the sample directory by name.
    let tagsWithExclude = generateCtagsForDir(tmp, ["sample_module.nim"])
    let linesWithExclude = tagsWithExclude.splitLines.filterIt(it.len > 0)
    let tagLinesWithExclude = linesWithExclude.filterIt(not it.startsWith("!_TAG_"))

    # We still emit the header lines, but there should be no tag lines
    # once the file is excluded.
    check linesWithExclude.len >= 4
    check tagLinesWithExclude.len == 0
