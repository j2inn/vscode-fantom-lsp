class BracketTest
{
  // Parentheses
  Void test(Int a, Str b) { }
  Int calc() { return (1 + 2) * (3 + 4) }

  // Square brackets
  Int[] list := [1, 2, 3]
  Str val := list[0]
  [Str:Int] map := ["a":1]

  // Curly braces
  Void method() { if (true) { doSomething() } }

  // Nested brackets
  Int[][] nested := [[1, 2], [3, 4]]
  Void complex() { list.each |Int v| { echo(v) } }
}
