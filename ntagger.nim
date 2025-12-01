import std/[os, strutils, algorithm]

import deps/compiler/[ast, syntaxes, options, idents, msgs, pathutils]

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

proc addTag(tags: var seq[Tag], file: string, line: int, name: string, k: TagKind) =
  if name.len == 0: return
  tags.add Tag(name: name, file: file, line: line, kind: k)

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

proc collectTagsFromAst(n: PNode, file: string, tags: var seq[Tag]) =
  ## Based on compiler/docgen.generateTags: walks the AST and collects
  ## tags for declarations we care about.
  case n.kind
  of nkCommentStmt:
    discard
  of nkProcDef:
    if isExportedName(n[namePos]):
      let name = nodeName(n[namePos])
      addTag(tags, file, int(n.info.line), name, tkProc)
  of nkFuncDef:
    if isExportedName(n[namePos]):
      let name = nodeName(n[namePos])
      addTag(tags, file, int(n.info.line), name, tkFunc)
  of nkMethodDef:
    if isExportedName(n[namePos]):
      let name = nodeName(n[namePos])
      addTag(tags, file, int(n.info.line), name, tkMethod)
  of nkIteratorDef:
    if isExportedName(n[namePos]):
      let name = nodeName(n[namePos])
      addTag(tags, file, int(n.info.line), name, tkIterator)
  of nkMacroDef:
    if isExportedName(n[namePos]):
      let name = nodeName(n[namePos])
      addTag(tags, file, int(n.info.line), name, tkMacro)
  of nkTemplateDef:
    if isExportedName(n[namePos]):
      let name = nodeName(n[namePos])
      addTag(tags, file, int(n.info.line), name, tkTemplate)
  of nkConverterDef:
    if isExportedName(n[namePos]):
      let name = nodeName(n[namePos])
      addTag(tags, file, int(n.info.line), name, tkConverter)
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
    # third field is an ex-command; using the line number is valid
    # and simple: `<line>;"`.
    result.add(
      t.name & "\t" &
      relFile & "\t" &
      $t.line & ";\"\t" &
      "kind:" & tagKindName(t.kind) & "\t" &
      "line:" & $t.line & "\t" &
      "language:Nim" & "\n"
    )

when isMainModule:
  let root = if paramCount() >= 1: paramStr(1) else: getCurrentDir()
  stdout.write generateCtagsForDir(root)
