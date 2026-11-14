{
  Part of threadtest: the first of two units whose initialization order
  is checked. ThreadTest.InitSecond uses this unit, so this unit must be
  initialized first and finalized last.

  It also holds a threadvar, which each thread of the test sets to its
  own value.
}
unit ThreadTest.InitFirst;

{$mode objfpc}

interface

const
  InitTraceCapacity = 16;

var
  { One letter per unit initialization, in the order they ran. }
  InitTrace: array[0..InitTraceCapacity - 1] of Char;
  InitTraceLength: Integer;
  { The value of tlstest_init_calls when this unit was initialized:
    library initializers run before unit initialization. }
  LibraryInitCallsSeen: LongInt;

threadvar
  ThreadOwnValue: Int64;

procedure NoteInitialization(Letter: Char);

implementation

var
  tlstest_init_calls: LongInt; external name 'tlstest_init_calls';

procedure NoteInitialization(Letter: Char);
begin
  if InitTraceLength < InitTraceCapacity - 1 then
  begin
    InitTrace[InitTraceLength] := Letter;
    Inc(InitTraceLength);
    InitTrace[InitTraceLength] := #0;
  end;
end;

initialization
  LibraryInitCallsSeen := tlstest_init_calls;
  NoteInitialization('F');
end.
