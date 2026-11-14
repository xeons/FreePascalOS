{
  FreePascalOS
  Copyright (C) 2026 Brandon Scott

  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see <https://www.gnu.org/licenses/>.
}

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
