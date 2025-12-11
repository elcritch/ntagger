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

proc badFilePath(): string =
  ## Resolve the location of the bad.nim test file
  ## regardless of whether the test is run from the repo root
  ## or from within the tests/ directory.
  let cwd = getCurrentDir()
  if fileExists(cwd / "bad.nim"):
    result = cwd / "bad.nim"
  elif fileExists(cwd / "tests" / "bad.nim"):
    result = cwd / "tests" / "bad.nim"
  else:
    raise newException(OSError, "bad.nim test file not found")

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

  test "modules are tagged using module kind":
    let tmp = sampleDir()
    let lines = tagsLinesForDir(tmp)
    let tagLines = lines.filterIt(not it.startsWith("!_TAG_"))

    let moduleLines = tagLines.filterIt(it.contains("\tkind:module\t"))
    check moduleLines.len == 1

    let moduleCols = moduleLines[0].split('\t')
    check moduleCols.len >= 3
    check moduleCols[0] == "sample_module"
    check moduleCols[1].endsWith("sample_module.nim")

    let importLines = tagLines.filterIt(it.contains("\tkind:import\t"))
    check importLines.len == 0

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

  test "private symbols can be included explicitly":
    let tmp = sampleDir()
    let tagsText = generateCtagsForDir(tmp, @[], true)

    # By default, private symbols are omitted (covered by another
    # test), but when explicitly requested they should be present
    # alongside the exported ones.
    check tagsText.contains("publicProc")
    check tagsText.contains("privateProc")

  test "explicit file roots are supported":
    let tmp = sampleDir()
    let filePath = tmp / "sample_module.nim"

    # When passing a single file as the root, we still produce a
    # valid tags stream and respect the exported-only default.
    let tagsText = generateCtagsForDir(filePath)
    check tagsText.contains("publicProc")
    check not tagsText.contains("privateProc")

    # A module tag should also be present for the file root.
    check tagsText.contains("sample_module\t")
    check tagsText.contains("kind:module\t")

  test "signatures remain on a single line":
    let badPath = badFilePath()

    # When generating tags for a file that contains a complex
    # default parameter expression, the resulting signature field
    # should not introduce embedded newlines that split the tag
    # across multiple lines.
    let tagsText = generateCtagsForDir(badPath)
    let lines = tagsText.splitLines.filterIt(it.len > 0)
    let tagLines = lines.filterIt(not it.startsWith("!_TAG_"))

    # We expect a single tag line for addOTAMethods, not a
    # continuation line caused by a newline in the signature.
    let otaLines = tagLines.filterIt(it.startsWith("addOTAMethods\t"))
    check otaLines.len == 1
