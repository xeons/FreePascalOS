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
  Adam7, PNG's interlacing: the picture is sent as seven smaller
  pictures (passes), each a regular grid of its pixels, so a viewer
  can show a coarse picture early:

    pass  first column  first line  column step  line step
     1         0            0            8           8
     2         4            0            8           8
     3         0            4            4           8
     4         2            0            4           4
     5         0            2            2           4
     6         1            0            2           2
     7         0            1            1           2

  Each pass is filtered on its own (its first line has a line of
  zeros above it); a pass with no columns or no lines is left out of
  the data altogether, filter bytes and all.
}
unit Image.Png.Interlace;

{$mode objfpc}
{$H+}

interface

type
  TAdam7Pass = record
    FirstColumn: LongInt;
    FirstLine: LongInt;
    ColumnStep: LongInt;
    LineStep: LongInt;
  end;

const
  Adam7PassCount = 7;
  Adam7Passes: array[0..Adam7PassCount - 1] of TAdam7Pass = (
    (FirstColumn: 0; FirstLine: 0; ColumnStep: 8; LineStep: 8),
    (FirstColumn: 4; FirstLine: 0; ColumnStep: 8; LineStep: 8),
    (FirstColumn: 0; FirstLine: 4; ColumnStep: 4; LineStep: 8),
    (FirstColumn: 2; FirstLine: 0; ColumnStep: 4; LineStep: 4),
    (FirstColumn: 0; FirstLine: 2; ColumnStep: 2; LineStep: 4),
    (FirstColumn: 1; FirstLine: 0; ColumnStep: 2; LineStep: 2),
    (FirstColumn: 0; FirstLine: 1; ColumnStep: 1; LineStep: 2));

{ The columns and lines pass Pass (0 to 6) has in a picture of Width x
  Height; 0 when it has none. }
function Adam7PassWidth(Pass, Width: LongInt): LongInt;
function Adam7PassHeight(Pass, Height: LongInt): LongInt;

implementation

function CountSteps(First, Step, Size: LongInt): LongInt;
begin
  if Size <= First then
    Result := 0
  else
    Result := (Size - First + Step - 1) div Step;
end;

function Adam7PassWidth(Pass, Width: LongInt): LongInt;
begin
  Result := CountSteps(Adam7Passes[Pass].FirstColumn, Adam7Passes[Pass].ColumnStep, Width);
end;

function Adam7PassHeight(Pass, Height: LongInt): LongInt;
begin
  Result := CountSteps(Adam7Passes[Pass].FirstLine, Adam7Passes[Pass].LineStep, Height);
end;

end.
