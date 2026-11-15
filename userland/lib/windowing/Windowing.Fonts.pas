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
  face's glyphs are read the first time it is picked. Either family can
  be asked for by name (TFontFamily: what a font dialog offers); a
  system without the monospaced fonts gets the text family's instead.
}
unit Windowing.Fonts;

{$mode objfpc}

interface

uses
  Font.Faces;

type
  TFontFamily = (FontFamilyText, FontFamilyFixed);

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
{ The same for either family. }
function FamilyFontFace(Family: TFontFamily; PointTenths: LongWord; Bold: Boolean): PFontFace;
function FamilyFaceSize(Family: TFontFamily; PointTenths: LongWord; Bold: Boolean): LongInt;
function FamilyFaceCount(Family: TFontFamily): LongInt;
function FamilyFace(Family: TFontFamily; Index: LongInt): PFontFace;
{ The family's name, to show ("DejaVu Sans"). }
function FamilyCaption(Family: TFontFamily): PChar;

implementation

uses
  Font.Text,
  Font.Files,
  Windowing.Theme,
  Windowing.Connection;

type
  PFontSet = ^TFontSet;

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

{ The family's fonts: the text family's when the monospaced one is not
  there. Nil if neither is. }
function FontsOf(Family: TFontFamily): PFontSet;
begin
  Result := nil;
  if Family = FontFamilyFixed then
  begin
    EnsureFamilyListed(FixedFamily, Theme.FixedFamily);
    if FixedFamily.Available then
      Exit(@FixedFamily.Fonts);
  end;
  EnsureFamilyListed(TextFamily, Theme.TextFamily);
  if TextFamily.Available then
    Result := @TextFamily.Fonts;
end;

function FamilyFontFace(Family: TFontFamily; PointTenths: LongWord; Bold: Boolean): PFontFace;
var
  Fonts: PFontSet;
begin
  Fonts := FontsOf(Family);
  if Fonts = nil then
    Exit(nil);
  Result := SelectFace(Fonts^, PointTenths, DisplayDpi, Bold);
end;

function FamilyFaceSize(Family: TFontFamily; PointTenths: LongWord; Bold: Boolean): LongInt;
var
  Fonts: PFontSet;
begin
  Fonts := FontsOf(Family);
  if Fonts = nil then
    Exit(0);
  Result := SelectedFaceSize(Fonts^, PointTenths, DisplayDpi, Bold);
end;

function FamilyFaceCount(Family: TFontFamily): LongInt;
var
  Fonts: PFontSet;
begin
  Fonts := FontsOf(Family);
  if Fonts = nil then
    Exit(0);
  Result := Fonts^.Count;
end;

function FamilyFace(Family: TFontFamily; Index: LongInt): PFontFace;
begin
  Result := @FontsOf(Family)^.Faces[Index];
end;

function FamilyCaption(Family: TFontFamily): PChar;
begin
  if Family = FontFamilyFixed then
    Result := 'Terminus'
  else
    Result := 'DejaVu Sans';
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
