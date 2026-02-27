class StrTest
{
  Void test()
  {
    // Double-quoted strings
    a := "hello world"
    b := "escape \n \t \\ \""

    // String interpolation
    c := "value is $name"
    d := "value is $obj.field.sub"
    e := "value is ${expr + 1}"

    // Triple-quoted string
    f := """
         multi-line
         string with $interp
         and ${expr}
         """

    // Character literal
    ch1 := 'a'
    ch2 := '\n'
    ch3 := '\u0041'

    // URI literal
    u := `http://example.com/path`
  }
}
