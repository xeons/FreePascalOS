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
