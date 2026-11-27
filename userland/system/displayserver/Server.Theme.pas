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
  The theme's metrics in pixels, at a screen's scale.

  The theme itself (colours and metrics in logical units) is
  Windowing.Theme, shared with the programs' controls, so frames and
  controls match.
}
unit Server.Theme;

{$mode objfpc}

interface

uses
  Windowing.Theme;

{ A metric (logical units) in pixels at ScalePercent. }
function ScaledMetric(Value: LongInt; ScalePercent: LongWord): LongInt;

implementation

uses
  Windowing.Protocol;

function ScaledMetric(Value: LongInt; ScalePercent: LongWord): LongInt;
begin
  Result := LogicalToPixels(Value, ScalePercent);
end;

end.
