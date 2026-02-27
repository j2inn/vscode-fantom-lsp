class OpTest
{
  Void test()
  {
    a := 10
    b := a + 1
    c := a - 1
    d := a * 2
    e := a / 2
    f := a % 3

    eq := a == b
    ne := a != b
    lt := a < b
    gt := a > b
    le := a <= b
    ge := a >= b
    se := a === b
    sne := a !== b

    x := true && false
    y := true || false
    z := !true

    a += 1
    a -= 1
    a *= 2

    r := 0..10
    r2 := 0..<10
    cmp := a <=> b

    val := x ?: "default"
    safe := obj?.method

    arrow := |->| {}
  }
}
