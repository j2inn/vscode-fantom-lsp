using concurrent

abstract class Base
{
  virtual Void doSomething() {}
}

class Example : Base
{
  const static Int MAX := 100
  private Str name

  override Void doSomething()
  {
    if (true)
    {
      for (i := 0; i < MAX; i++) break
    }
    else
    {
      while (false) continue
    }

    try { throw Err("oops") }
    catch (Err e) {}
    finally {}

    val := true
    nul := null
    no := false

    switch (val)
    {
      case true: return
      default: return
    }
  }
}
