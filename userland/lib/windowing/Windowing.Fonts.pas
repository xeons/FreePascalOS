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
  The fonts programs draw with: the system's fonts, loaded once, and
  faces picked by size in points at the display's DPI.
}
unit Windowing.Fonts;

{$mode objfpc}

interface

uses
  Font.Psf;

{ The face for PointTenths tenths of a point (bold or not); nil if the
  system has no fonts. }
function FontFace(PointTenths: LongWord; Bold: Boolean): PFontFace;
{ The theme's text face, regular and bold. }
function TextFace: PFontFace;
function BoldTextFace: PFontFace;

implementation

uses
  Font.Text,
  Font.Files,
  Windowing.Theme,
  Windowing.Connection;

var
  Fonts: TFontSet;
  Loaded: Boolean;
  Available: Boolean;

function FontFace(PointTenths: LongWord; Bold: Boolean): PFontFace;
begin
  if not Loaded then
  begin
    Available := LoadSystemFonts(Fonts);
    Loaded := True;
  end;
  if not Available then
    Exit(nil);
  Result := SelectFace(Fonts, PointTenths, DisplayDpi, Bold);
end;

function TextFace: PFontFace;
begin
  Result := FontFace(Theme.TextPoints, False);
end;

function BoldTextFace: PFontFace;
begin
  Result := FontFace(Theme.TextPoints, True);
end;

end.
