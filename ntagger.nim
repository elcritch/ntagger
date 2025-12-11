import std/[os, strutils, algorithm, parseopt, osproc]

import compiler/[ast, syntaxes, options, idents, msgs, pathutils, renderer]

type
  TagKind* = enum
    tkType, tkVar, tkLet, tkConst,
    tkProc, tkFunc, tkMethod, tkIterator,
    tkConverter, tkMacro, tkTemplate,
    tkModule

  Tag* = object
    name*: string
    file*: string
    line*: int
    kind*: TagKind
    signature*: string

proc tagKindName*(k: TagKind): string =
  case k
  of tkType: "type"
  of tkVar: "var"
  of tkLet: "let"
  of tkConst: "const"
  of tkProc: "proc"
  of tkFunc: "func"
  of tkMethod: "method"
  of tkIterator: "iterator"
  of tkConverter: "converter"
  of tkMacro: "macro"
  of tkTemplate: "template"
  of tkModule: "module"

proc addTag(tags: var seq[Tag], file: string, line: int, name: string, k: TagKind,
            signature = "") =
  if name.len == 0:
    return
  tags.add Tag(name: name, file: file, line: line, kind: k,
      signature: signature)

proc nodeName(n: PNode): string =
  ## Extracts the plain identifier name for a symbol definition node.
  ## Mirrors the logic of compiler/docgen.getNameIdent, but returns a
  ## simple string instead of an identifier.
  case n.kind
  of nkPostfix:
    result = nodeName(n[1])
  of nkPragmaExpr:
    result = nodeName(n[0])
  of nkSym:
    if n.sym != nil and n.sym.name != nil:
      result = n.sym.name.s
  of nkIdent:
    if n.ident != nil:
      result = n.ident.s
  of nkAccQuoted:
    for i in 0 ..< n.len:
      result.add nodeName(n[i])
  of nkOpenSymChoice, nkClosedSymChoice, nkOpenSym:
    result = nodeName(n[0])
  else:
    discard

proc isExportedName(n: PNode): bool =
  ## Returns true if a name node represents an exported symbol.
  ##
  ## We treat a ``nkPostfix`` name (e.g. ``foo*``) as exported and
  ## follow the same structural patterns as ``nodeName``.
  case n.kind
  of nkPostfix:
    result = true
  of nkPragmaExpr:
    result = isExportedName(n[0])
  of nkAccQuoted:
    result = isExportedName(n[0])
  of nkOpenSymChoice, nkClosedSymChoice, nkOpenSym:
    result = isExportedName(n[0])
  else:
    result = false

proc buildSignature(n: PNode): string =
  ## Builds a Nim-like signature string for routine definition nodes.
  ##
  ## The structure mirrors the JSON signature generation in
  ## deps/compiler/docgen.nim, but flattens it to a single string in
  ## the form: "[T](x: int, y: string = 0): int {. pragmas .}".

  # Generic parameters
  if n[genericParamsPos].kind != nkEmpty:
    result.add "["
    var firstGen = true
    for genericParam in n[genericParamsPos]:
      if not firstGen:
        result.add ", "
      firstGen = false
      result.add $genericParam
    result.add "]"

  # Parameters
  result.add "("
  if n[paramsPos].len > 1:
    var firstParam = true
    for paramIdx in 1 ..< n[paramsPos].len:
      let param = n[paramsPos][paramIdx]
      if param.kind == nkEmpty:
        continue

      let paramType = $param[^2]
      let defaultNode = param[^1]

      for identIdx in 0 ..< param.len - 2:
        let nameNode = param[identIdx]
        if nameNode.kind == nkEmpty:
          continue
        if not firstParam:
          result.add ", "
        firstParam = false
        result.add $nameNode
        if paramType.len > 0:
          result.add ": "
          result.add paramType
        if defaultNode.kind != nkEmpty:
          result.add " = "
          result.add $defaultNode
  result.add ")"

  # Return type
  if n[paramsPos][0].kind != nkEmpty:
    result.add ": "
    result.add $n[paramsPos][0]

  # Pragmas
  if n[pragmasPos].kind != nkEmpty:
    result.add " {. "
    var firstPragma = true
    for pragma in n[pragmasPos]:
      if not firstPragma:
        result.add ", "
      firstPragma = false
      result.add $pragma
    result.add " .}"

proc collectTagsFromAst(n: PNode, file: string, tags: var seq[Tag],
    includePrivate: bool) =
  ## Walks the AST and collects tags for declarations we care about.
  case n.kind
  of nkCommentStmt:
    discard
  of nkProcDef:
    if includePrivate or isExportedName(n[namePos]):
      let name = nodeName(n[namePos])
      addTag(tags, file, int(n.info.line), name, tkProc, buildSignature(n))
  of nkFuncDef:
    if includePrivate or isExportedName(n[namePos]):
      let name = nodeName(n[namePos])
      addTag(tags, file, int(n.info.line), name, tkFunc, buildSignature(n))
  of nkMethodDef:
    if includePrivate or isExportedName(n[namePos]):
      let name = nodeName(n[namePos])
      addTag(tags, file, int(n.info.line), name, tkMethod, buildSignature(n))
  of nkIteratorDef:
    if includePrivate or isExportedName(n[namePos]):
      let name = nodeName(n[namePos])
      addTag(tags, file, int(n.info.line), name, tkIterator, buildSignature(n))
  of nkMacroDef:
    if includePrivate or isExportedName(n[namePos]):
      let name = nodeName(n[namePos])
      addTag(tags, file, int(n.info.line), name, tkMacro, buildSignature(n))
  of nkTemplateDef:
    if includePrivate or isExportedName(n[namePos]):
      let name = nodeName(n[namePos])
      addTag(tags, file, int(n.info.line), name, tkTemplate, buildSignature(n))
  of nkConverterDef:
    if includePrivate or isExportedName(n[namePos]):
      let name = nodeName(n[namePos])
      addTag(tags, file, int(n.info.line), name, tkConverter, buildSignature(n))
  of nkTypeSection, nkVarSection, nkLetSection, nkConstSection:
    for i in 0 ..< n.len:
      if n[i].kind == nkCommentStmt:
        continue
      let def = n[i]
      let nameNode = def[0]
      if includePrivate or isExportedName(nameNode):
        let name = nodeName(nameNode)
        let kindOffset = ord(n.kind) - ord(nkTypeSection)
        let symKind = TagKind(ord(tkType) + kindOffset)
        addTag(tags, file, int(def.info.line), name, symKind)
  of nkStmtList:
    for i in 0 ..< n.len:
      collectTagsFromAst(n[i], file, tags, includePrivate)
  of nkWhenStmt:
    # Follow the first branch only, like docgen.generateTags.
    if n.len > 0 and n[0].len > 0:
      collectTagsFromAst(lastSon(n[0]), file, tags, includePrivate)
  else:
    discard

proc parseNimFile(conf: ConfigRef, cache: IdentCache, file: string): PNode =
  let abs = AbsoluteFile(absolutePath(file))
  let idx = fileInfoIdx(conf, abs)
  result = syntaxes.parseFile(idx, cache, conf)

proc collectTagsForFile*(conf: ConfigRef, cache: IdentCache, file: string,
    includePrivate = false): seq[Tag] =
  let ast = parseNimFile(conf, cache, file)
  if ast.isNil:
    return
  collectTagsFromAst(ast, file, result, includePrivate)

proc moduleNameFromPath(path: string): string =
  ## Derive the Nim module name from a file path by taking the last
  ## path component without its extension.
  let (_, namePart, _) = splitFile(path)
  result = namePart

proc isExcludedPath(path: string, excludes: openArray[string]): bool =
  ## Returns true if `path` should be excluded based on the
  ## user-provided exclude patterns.
  ##
  ## We keep the semantics intentionally simple and ctags-like:
  ## any pattern that appears as a substring of the normalized
  ## (DirSep -> '/') path will exclude the file.
  var normalized = path.replace(DirSep, '/')
  for pat in excludes:
    if pat.len == 0:
      continue
    let normPat = pat.replace(DirSep, '/')
    if normalized.contains(normPat):
      return true

proc sanitizeTagFieldValue(s: string): string =
  ## Normalize a tag field value so that it does not contain any
  ## embedded newlines or tab characters, which would otherwise
  ## break the ctags line-oriented format.
  var lastWasSpace = false
  for ch in s:
    if ch in ['\n', '\r', '\t']:
      if not lastWasSpace:
        result.add ' '
        lastWasSpace = true
    else:
      result.add ch
      lastWasSpace = (ch == ' ')

proc generateCtagsForDirImpl*(
    roots: openArray[string],
    excludes: openArray[string],
    baseDir = "",
    includePrivate = false,
    modulesOnly = false,
    tagRelative = false
): seq[Tag] =

  ## Generate a universal-ctags compatible tags file for all Nim
  ## modules found under one or more `roots` (searched recursively),
  ## optionally skipping files whose paths match any of the
  ## `excludes` patterns.
  if roots.len == 0:
    return

  var conf = newConfigRef()
  let firstRootAbs = absolutePath(roots[0])
  let projectDir =
    if dirExists(firstRootAbs):
      firstRootAbs
    elif fileExists(firstRootAbs):
      parentDir(firstRootAbs)
    else:
      getCurrentDir()
  conf.projectPath = AbsoluteDir(projectDir)
  var cache = newIdentCache()

  let effectiveBaseDir = if baseDir.len == 0: getCurrentDir() else: baseDir

  var tags: seq[Tag] = @[]

  for root in roots:
    let absRoot = absolutePath(root)

    if dirExists(absRoot):
      for path in walkDirRec(absRoot):
        if not path.endsWith(".nim"):
          continue

        let relPath =
          try:
            relativePath(path, absRoot)
          except OSError:
            path

        if isExcludedPath(relPath, excludes):
          continue

        let moduleName = moduleNameFromPath(path)
        addTag(tags, path, 1, moduleName, tkModule)
        if not modulesOnly:
          tags.add collectTagsForFile(conf, cache, path, includePrivate)
    elif fileExists(absRoot):
      # Allow roots to be explicit Nim files in addition to
      # directories; in that case, process just the file itself.
      if not absRoot.endsWith(".nim"):
        continue

      let relPath =
        try:
          relativePath(absRoot, parentDir(absRoot))
        except OSError:
          absRoot

      if isExcludedPath(relPath, excludes):
        continue

      let moduleName = moduleNameFromPath(absRoot)
      addTag(tags, absRoot, 1, moduleName, tkModule)
      if not modulesOnly:
        tags.add collectTagsForFile(conf, cache, absRoot, includePrivate)

  if tagRelative:
    for tag in tags.mitems:
      try:
        tag.file = relativePath(tag.file, effectiveBaseDir)
      except OSError:
        # Keep absolute path if relative cannot be constructed
        discard

  result = tags

proc `$`*(tags: seq[Tag]): string =
  # Sort tags by name, then file, then line, as expected by ctags
  # when reporting a sorted file.
  var tags = tags
  tags.sort(proc (a, b: Tag): int =
    result = cmp(a.name, b.name)
    if result == 0:
      result = cmp(a.file, b.file)
    if result == 0:
      result = cmp(a.line, b.line)
  )

  # Header lines for extended ctags format
  result.add "!_TAG_FILE_FORMAT\t2\t/extended format/\n"
  result.add "!_TAG_FILE_SORTED\t1\t/0=unsorted, 1=sorted, 2=foldcase/\n"
  result.add "!_TAG_PROGRAM_NAME\tntagger\t//\n"
  result.add "!_TAG_PROGRAM_VERSION\t0.1\t//\n"

  for t in tags:
    var line =
      t.name & "\t" &
      t.file & "\t" &
      $t.line & ";\"\t" &
      "kind:" & tagKindName(t.kind) & "\t" &
      "line:" & $t.line & "\t"

    if t.signature.len > 0:
      line.add "signature:" & sanitizeTagFieldValue(t.signature) & "\t"

    line.add "language:Nim\n"
    result.add line

proc queryNimSettingSeq(setting: string): seq[string] =
  ## Invoke the Nim compiler to query a setting sequence such as
  ## `searchPaths` or `nimblePaths`, returning the list of paths.
  let evalCode =
    "import std/compilesettings; for x in querySettingSeq(" &
      setting & "): echo x"
  try:
    let output = execProcess("nim",
                             args = ["--verbosity:0", "--eval:" & evalCode],
                             options = {poStdErrToStdOut, poUsePath})
    for line in output.splitLines:
      let trimmed = line.strip()
      if trimmed.len > 0:
        result.add trimmed
  except CatchableError:
    # If Nim is not available or the query fails, just return an
    # empty list and continue without the extra paths.
    discard

proc addRootIfDir(roots: var seq[string], path: string) =
  ## Add `path` to `roots` if it is a directory and not already
  ## present in the list.
  let p = path.strip()
  if p.len == 0 or not dirExists(p):
    return
  for existing in roots:
    if existing == p:
      return
  roots.add(p)

proc nimCfgPaths(): seq[string] =
  if fileExists("nim.cfg"):
    for line in readLines("nim.cfg"):
      if line.startsWith("--path:"):
        result.addRootIfDir(line[7..^1])

proc nimblePaths(): seq[string] =
  for p in queryNimSettingSeq("nimblePaths"):
    result.addRootIfDir(p)

proc searchPaths(): seq[string] =
  for p in queryNimSettingSeq("searchPaths"):
    result.addRootIfDir(p)

proc main() =
  ## Simple CLI for ntagger.
  ##
  ## Supports a `-f` flag (like ctags/universal-ctags) to control
  ## where the generated tags are written. If `-f` is not provided
  ## or is set to `-`, tags are written to stdout.
  ##
  ## Additionally supports one or more `--exclude`/`-e` options whose
  ## values are simple path substrings; any Nim file whose path (relative
  ## to the search root) contains one of these substrings will be
  ## skipped, similar to ctags' exclude handling.
  ##
  ## The `--auto`/`-a` flag enables an "auto" mode that sets the
  ## default output file to `tags` and also includes tags for Nim
  ## search paths and Nimble package paths discovered via the Nim
  ## compiler's `compilesettings` module.
  ##
  ## The `--private`/`-p` flag controls whether tags are also
  ## generated for private (non-exported) symbols in addition to
  ## exported ones.

  var
    roots: seq[string] = @[]
    outFile = ""
    expectOutFile = false
    expectExclude = false
    autoMode = false
    systemMode = false
    atlasMode = false
    atlasAllMode = false
    includePrivate = false
    depsOnly = false
    tagRelative = false
    systemModules = false
    excludes: seq[string] = @[]

  var parser = initOptParser(commandLineParams())

  for kind, key, val in parser.getopt():
    case kind
    of cmdShortOption, cmdLongOption:
      # Special-case a lone '-' that is parsed as a short option with
      # an empty name: treat it as the filename "-" when it follows
      # `-f`.
      if expectOutFile and kind == cmdShortOption and key.len == 0:
        outFile = "-"
        expectOutFile = false
      else:
        case key
        of "f", "output":
          if val.len > 0:
            outFile = val
            expectOutFile = false
          else:
            # Remember that the next argument should be treated as the
            # value for this option (e.g. `-f tags`).
            expectOutFile = true
        of "e", "exclude":
          if val.len > 0:
            excludes.add val
            expectExclude = false
          else:
            # Next argument will be treated as an exclude pattern.
            expectExclude = true
        of "a", "auto":
          autoMode = true
        of "s", "system":
          systemMode = true
        of "M", "system-modules":
          systemModules = true
        of "p", "private":
          includePrivate = true
        of "atlas-all":
          atlasAllMode = true
        of "atlas":
          atlasMode = true
        of "tag-relative":
          if val == "yes":
            tagRelative = true
          elif val == "no":
            tagRelative = false
        else:
          discard
    of cmdArgument:
      if expectOutFile:
        outFile = key
        expectOutFile = false
      elif expectExclude:
        excludes.add key
        expectExclude = false
      else:
        roots.add key
    of cmdEnd:
      discard

  if roots.len == 0:
    roots.add getCurrentDir()
  var rootsToScan: seq[string] = @[]
  let depsDir = "deps"

  echo "searchpaths: ", searchpaths()

  if atlasMode or atlasAllMode:
    if not fileExists(depsDir / "tags") or atlasAllMode:
      for pth in searchPaths():
        let name = pth.splitFile().name
        if name.startsWith("_"): continue
        if not systemMode and not pth.isRelativeTo(depsDir):
          continue
        rootsToScan.add(pth)
      let depTags = generateCtagsForDirImpl(rootsToScan, [],
          baseDir = (if tagRelative: depsDir else: ""),
          includePrivate = includePrivate, tagRelative = tagRelative)
      writeFile(depsDir/"tags", $depTags)

    rootsToScan.add(roots)
    outFile = "tags"
  else:
    rootsToScan.add(roots)

  if autoMode:
    # Query Nim for its search paths and Nimble package paths and
    # include those directories as additional roots.
    rootsToScan.add(nimCfgPaths())
    rootsToScan.add(nimblePaths())

    # In auto mode, default the output file to `tags` unless the
    # user has explicitly provided a different `-f`/`--output`.
    if outFile.len == 0:
      outFile = "tags"

  if systemMode:
    for pth in searchPaths():
      if pth.isRelativeTo(depsDir): continue
      rootsToScan.add(pth)
  
  let baseDir =
    if tagRelative:
      if outFile.len > 0 and outFile != "-":
        parentDir(outFile)
      else:
        getCurrentDir()
    else: ""

  let tags = generateCtagsForDirImpl(rootsToScan, excludes,
                                     baseDir = baseDir,
                                     includePrivate = includePrivate,
                                     tagRelative = tagRelative)

  if outFile.len == 0 or outFile == "-":
    stdout.write($tags)
  else:
    writeFile(outFile, $tags)

when isMainModule:
  main()
