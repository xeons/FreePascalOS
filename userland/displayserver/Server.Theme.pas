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
  The display's scale and DPI, and the theme's metrics in pixels.

  The theme itself (colours and metrics in logical units) is
  Windowing.Theme, shared with the programs' controls, so frames and
  controls match.
}
unit Server.Theme;

{$mode objfpc}

interface

uses
  Windowing.Theme;

var
  { The display's scale in percent. }
  ScalePercent: LongWord;
  Dpi: LongWord;

{ A metric (logical units) in pixels. }
function ScaledMetric(Value: LongInt): LongInt;

implementation

uses
  Windowing.Protocol;

function ScaledMetric(Value: LongInt): LongInt;
begin
  Result := LogicalToPixels(Value, ScalePercent);
end;

end.
