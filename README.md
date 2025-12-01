# ntagger

ntagger is a small Nim tool that generates
universal-ctags–compatible tag files for Nim
projects by reusing the Nim compiler's own
parser and AST.

It can be used both as a CLI (producing a
`tags` stream on stdout or in a file) and as a
library via `generateCtagsForDir`.

## Installation

```sh
nimble install https://github.com/elcritch/ntagger
```

Then run it:

```sh
ntagger -f tags --exclude:deps
```

## Features

- Generates extended ctags format (with
  `!_TAG_FILE_*` headers).
- Emits tags for exported Nim symbols:
  types, `var`/`let`/`const`, procs/funcs,
  methods, iterators, converters, macros and
  templates.
- Includes extra fields such as `kind`,
  source `line`, `signature` and
  `language:Nim`.
- Output is sorted by name, then file, then
  line, like `ctags --sorted=1`.

## Repository layout

- `ntagger.nim` – main module and CLI entry; defines
  `Tag`, `TagKind` and `generateCtagsForDir`.
- `tests/` – unit tests and fixtures.
- `config.nims` – NimScript tasks (notably the
  `test` task).
- `deps/` – vendored dependencies and compiler
  sources (managed by Atlas).
- `nim.cfg` / `ntagger.nimble` – local compiler
  settings and minimal package manifest.

## Building

Prerequisites:

- Nim installed locally.
- Dependencies checked out in `deps/` (if
  you use Atlas, run `atlas install` at the
  workspace root).

Build the `ntagger` binary in the repo root:

```bash
nim c ntagger.nim
```

This produces a `ntagger` executable in the
same directory.

## CLI usage

Basic usage:

```bash
ntagger            # scan . and write tags to stdout
ntagger path/to/project
```

Write tags to a file (like ctags):

```bash
ntagger -f tags path/to/project
ntagger --output=tags path/to/project
```

Use `-` to force stdout (even if `-f` is
given):

```bash
ntagger -f - path/to/project
```

### Excluding paths

ntagger supports `--exclude` arguments in a
ctags-like way: any Nim file whose path (relative
to the chosen root) contains one of the provided
patterns is skipped.

You can repeat `--exclude`/`-e` to add
multiple patterns:

```bash
# Skip everything under deps and the tests directory
ntagger --exclude deps --exclude tests .

# Short option form
ntagger -e deps -e tests .

# "=value" form
ntagger --exclude=deps .
```

Patterns are simple substrings, not globs.
They are matched against normalized
`/`-separated paths relative to the scan
root.

### Auto and System Mode

`--auto` (or `-a`) enables an auto mode
that makes ntagger behave more like a
project-wide ctags generator for Nim. It
defaults to outputting `tags` file and searches
Nimble paths or Atlas style `nim.cfg` paths for
tags.

`--system` (or `-s`) enables generating tags for
Nim's standard library.

Example:

```bash
ntagger --auto            # write tags to ./tags 
ntagger --system          # write tags to ./tags 
ntagger --auto -f mytags .  # override output file name
ntagger --auto --system -f mytags .  # override output file name
```

## Library usage

You can also call ntagger from Nim code by
importing the module and using
`generateCtagsForDir`:

```nim
import ntagger

let tagsText = generateCtagsForDir("path/to/project")
```

To apply excludes programmatically:

```nim
let tagsText = generateCtagsForDir("path/to/project",
                                   ["deps", "tests"])
```

The returned string is the full tags file
contents (including headers).
