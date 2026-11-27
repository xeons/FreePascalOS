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
  PaintTest - Paint's plain logic and its work on pixels, on the host

    PaintTest

  The logic (PaintTest.Logic): the zoom's mapping, the geometry of
  dragging, file formats by name, the undo history. The pixels
  (PaintTest.Pixels): flood fill, shapes, strokes, the selection, the
  Image menu's transforms and the zoomed view. The units are Paint's
  own (userland/apps/paint) and libimage's and libdrawing's, which need
  nothing of the system.

  Every check prints a line; the last reads "N passed, M failed", and
  the exit code is 1 if any failed. This is a host tool, built with the
  normal Free Pascal runtime library.
}
program PaintTest;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  PaintTest.Checks,
  PaintTest.Logic,
  PaintTest.Pixels;

begin
  TestPaintLogic;
  TestPaintPixels;
  WriteLn(Passed, ' passed, ', Failed, ' failed');
  if Failed > 0 then
    Halt(1);
end.
