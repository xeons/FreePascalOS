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
  The fonts programs draw with: the theme's two families (the
  interface's text, proportional, and a monospaced one), each listed
  once, and faces picked by size in points at the display's DPI. A
  face's glyphs are read the first time it is picked.
}
unit Windowing.Fonts;

{$mode objfpc}

interface

uses
  Font.Faces;

{ The face of the theme's text family for PointTenths tenths of a point
  (bold or not); nil if the system has no such fonts. }
function FontFace(PointTenths: LongWord; Bold: Boolean): PFontFace;
{ The same from the theme's monospaced family. }
function FixedFontFace(PointTenths: LongWord; Bold: Boolean): PFontFace;
{ The theme's text face, regular and bold, and its monospaced one. }
function TextFace: PFontFace;
function BoldTextFace: PFontFace;
function FixedTextFace: PFontFace;
{ The pixel size of the face FontFace would give, without reading it
  (0 if there is none): to list the sizes there are. }
function FontFaceSize(PointTenths: LongWord; Bold: Boolean): LongInt;
{ How many faces the text family has, and each of them, known by size
  and weight (their glyphs may not have been read). }
function SystemFaceCount: LongInt;
function SystemFace(Index: LongInt): PFontFace;

implementation

uses
  Font.Text,
  Font.Files,
  Windowing.Theme,
  Windowing.Connection;

type
  TFamily = record
    Fonts: TFontSet;
    Listed: Boolean;
    Available: Boolean;
  end;

var
  TextFamily: TFamily;
  FixedFamily: TFamily;

{ A family's directory is listed the first time any of its faces is
  wanted. }
procedure EnsureFamilyListed(var Family: TFamily; Name: PChar);
begin
  if not Family.Listed then
  begin
    Family.Available := LoadFontFamily(Name, Family.Fonts);
    Family.Listed := True;
  end;
end;

function FontFace(PointTenths: LongWord; Bold: Boolean): PFontFace;
begin
  EnsureFamilyListed(TextFamily, Theme.TextFamily);
  if not TextFamily.Available then
    Exit(nil);
  Result := SelectFace(TextFamily.Fonts, PointTenths, DisplayDpi, Bold);
end;

function FixedFontFace(PointTenths: LongWord; Bold: Boolean): PFontFace;
begin
  EnsureFamilyListed(FixedFamily, Theme.FixedFamily);
  if not FixedFamily.Available then
    Exit(FontFace(PointTenths, Bold));
  Result := SelectFace(FixedFamily.Fonts, PointTenths, DisplayDpi, Bold);
end;

function TextFace: PFontFace;
begin
  Result := FontFace(Theme.TextPoints, False);
end;

function BoldTextFace: PFontFace;
begin
  Result := FontFace(Theme.TextPoints, True);
end;

function FixedTextFace: PFontFace;
begin
  Result := FixedFontFace(Theme.TextPoints, False);
end;

function FontFaceSize(PointTenths: LongWord; Bold: Boolean): LongInt;
begin
  EnsureFamilyListed(TextFamily, Theme.TextFamily);
  if not TextFamily.Available then
    Exit(0);
  Result := SelectedFaceSize(TextFamily.Fonts, PointTenths, DisplayDpi, Bold);
end;

function SystemFaceCount: LongInt;
begin
  EnsureFamilyListed(TextFamily, Theme.TextFamily);
  if TextFamily.Available then
    Result := TextFamily.Fonts.Count
  else
    Result := 0;
end;

function SystemFace(Index: LongInt): PFontFace;
begin
  EnsureFamilyListed(TextFamily, Theme.TextFamily);
  Result := @TextFamily.Fonts.Faces[Index];
end;

end.
