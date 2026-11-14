{
  Minimal ObjPas unit.

  The compiler implicitly uses this unit for every module compiled in
  objfpc mode. The only thing it needs to provide here is the 32-bit
  Integer type that object pascal mode expects.
}
unit ObjPas;

interface

type
  Integer = LongInt;

implementation

end.
