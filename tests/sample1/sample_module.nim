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

proc privateProc(x: int): int =
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

