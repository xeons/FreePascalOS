{
  Empty SysInit unit.

  Windows-style targets (which the UEFI loader is built as) implicitly use
  this unit for program startup code. The loader provides its own entry
  point, so nothing is needed here.
}
unit SysInit;

interface

implementation

end.
