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
  The heading of a taskbar pop-up (the network list): a navy header
  band (Controls.HeaderBands) across the pop-up's top, just inside its
  raised edge, where the theme bands its panels; otherwise a plain
  label at the margin.
}
unit Desktop.PopupHeading;

{$mode objfpc}
{$H+}

interface

uses
  Controls.Base,
  Controls.HeaderBands;

{ A heading at the top of a pop-up PopupWidth wide (logical units): a
  band Height + Margin high across it, or a label at (Margin, Margin). }
function CreatePopupHeading(Parent: TControl; const Text: string; PopupWidth, Margin, Height: LongInt): THeaderBand;

implementation

const
  { Logical units: the pop-up's raised edge. }
  EdgeWidth = 2;

function CreatePopupHeading(Parent: TControl; const Text: string; PopupWidth, Margin, Height: LongInt): THeaderBand;
begin
  Result := THeaderBand.Create(Parent);
  Result.Text := Text;
  Result.Style := HeaderBandNavy;
  if THeaderBand.ThemeBands then
    Result.SetBounds(EdgeWidth, EdgeWidth, PopupWidth - 2 * EdgeWidth, Margin + Height - EdgeWidth)
  else
    Result.SetBounds(Margin, Margin, PopupWidth - 2 * Margin, Height);
end;

end.
