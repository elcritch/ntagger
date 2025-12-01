import std/[os, strutils, algorithm, parseopt]

import deps/compiler/[ast, syntaxes, options, idents, msgs, pathutils, renderer]

type
  TagKind* = enum
    tkType, tkVar, tkLet, tkConst,
    tkProc, tkFunc, tkMethod, tkIterator,
    tkConverter, tkMacro, tkTemplate

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

proc addTag(tags: var seq[Tag], file: string, line: int, name: string, k: TagKind,
            signature = "") =
  if name.len == 0: return
  tags.add Tag(name: name, file: file, line: line, kind: k,
      signature: signature)

proc nodeName(n: PNode): string =
  ## Extracts the plain identifier name for a symbol definition node.
  ##
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

proc collectTagsFromAst(n: PNode, file: string, tags: var seq[Tag]) =
  ## Based on compiler/docgen.generateTags: walks the AST and collects
  ## tags for declarations we care about.
  case n.kind
  of nkCommentStmt:
    discard
  of nkProcDef:
    if isExportedName(n[namePos]):
      let name = nodeName(n[namePos])
      addTag(tags, file, int(n.info.line), name, tkProc, buildSignature(n))
  of nkFuncDef:
    if isExportedName(n[namePos]):
      let name = nodeName(n[namePos])
      addTag(tags, file, int(n.info.line), name, tkFunc, buildSignature(n))
  of nkMethodDef:
    if isExportedName(n[namePos]):
      let name = nodeName(n[namePos])
      addTag(tags, file, int(n.info.line), name, tkMethod, buildSignature(n))
  of nkIteratorDef:
    if isExportedName(n[namePos]):
      let name = nodeName(n[namePos])
      addTag(tags, file, int(n.info.line), name, tkIterator, buildSignature(n))
  of nkMacroDef:
    if isExportedName(n[namePos]):
      let name = nodeName(n[namePos])
      addTag(tags, file, int(n.info.line), name, tkMacro, buildSignature(n))
  of nkTemplateDef:
    if isExportedName(n[namePos]):
      let name = nodeName(n[namePos])
      addTag(tags, file, int(n.info.line), name, tkTemplate, buildSignature(n))
  of nkConverterDef:
    if isExportedName(n[namePos]):
      let name = nodeName(n[namePos])
      addTag(tags, file, int(n.info.line), name, tkConverter, buildSignature(n))
  of nkTypeSection, nkVarSection, nkLetSection, nkConstSection:
    for i in 0..<n.len:
      if n[i].kind == nkCommentStmt: continue
      let def = n[i]
      let nameNode = def[0]
      if isExportedName(nameNode):
        let name = nodeName(nameNode)
        let kindOffset = ord(n.kind) - ord(nkTypeSection)
        let symKind = TagKind(ord(tkType) + kindOffset)
        addTag(tags, file, int(def.info.line), name, symKind)
  of nkStmtList:
    for i in 0..<n.len:
      collectTagsFromAst(n[i], file, tags)
  of nkWhenStmt:
    # Follow the first branch only, like docgen.generateTags.
    if n.len > 0 and n[0].len > 0:
      collectTagsFromAst(lastSon(n[0]), file, tags)
  else:
    discard

proc parseNimFile(conf: ConfigRef, cache: IdentCache, file: string): PNode =
  let abs = AbsoluteFile(absolutePath(file))
  let idx = fileInfoIdx(conf, abs)
  result = syntaxes.parseFile(idx, cache, conf)

proc collectTagsForFile*(conf: ConfigRef, cache: IdentCache, file: string): seq[Tag] =
  let ast = parseNimFile(conf, cache, file)
  if ast.isNil: return
  collectTagsFromAst(ast, file, result)

proc generateCtagsForDir*(root: string): string =
  ## Generate a universal-ctags compatible tags file for all Nim
  ## modules found under `root` (searched recursively).
  var conf = newConfigRef()
  let absRoot = absolutePath(root)
  conf.projectPath = AbsoluteDir(absRoot)
  var cache = newIdentCache()

  var tags: seq[Tag] = @[]
  for path in walkDirRec(absRoot):
    if path.endsWith(".nim"):
      tags.add collectTagsForFile(conf, cache, path)

  # sort tags by name, then file, then line, as expected by ctags when
  # reporting a sorted file
  tags.sort(proc(a, b: Tag): int =
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

  let baseDir = getCurrentDir()

  for t in tags:
    let relFile =
      try:
        relativePath(t.file, baseDir)
      except OSError:
        # Fallback to the original path if a relative path
        # cannot be constructed for some reason.
        t.file

    var line =
      t.name & "\t" &
      relFile & "\t" &
      $t.line & ";\"\t" &
      "kind:" & tagKindName(t.kind) & "\t" &
      "line:" & $t.line & "\t"

    if t.signature.len > 0:
      line.add "signature:" & t.signature & "\t"

    line.add "language:Nim\n"
    result.add line

when isMainModule:
  ## Simple CLI for ntagger.
  ##
  ## Supports a `-f` flag (like ctags/universal-ctags) to control
  ## where the generated tags are written. If `-f` is not provided
  ## or is set to `-`, tags are written to stdout.

  var
    root = ""
    outFile = ""
    expectOutFile = false

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
        else:
          discard
    of cmdArgument:
      if expectOutFile:
        outFile = key
        expectOutFile = false
      elif root.len == 0:
        root = key
    of cmdEnd:
      discard

  if root.len == 0:
    root = getCurrentDir()

  let tags = generateCtagsForDir(root)

  if outFile.len == 0 or outFile == "-":
    stdout.write(tags)
  else:
    writeFile(outFile, tags)
