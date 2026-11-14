{
  Part of threadtest: the second of two units whose initialization order
  is checked (see ThreadTest.InitFirst). Its finalization prints a line,
  which must appear after the program's own output and before the
  library finalizer's.
}
unit ThreadTest.InitSecond;

{$mode objfpc}

interface

uses
  ThreadTest.InitFirst;

{ Set by the program when its finalization line should be printed (only
  the normal test run prints it). }
var
  PrintFinalization: Boolean;

implementation

uses
  Sys.Streams;

initialization
  NoteInitialization('S');

finalization
  if PrintFinalization then
    PrintLine('threadtest: unit finalization ran');
end.
