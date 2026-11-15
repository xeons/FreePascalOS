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
  Text in controls: the theme's face, measuring, drawing within a
  rectangle (aligned, cut short with "..." if it does not fit), and the
  characters of a UTF-8 string (where each starts), for editing.
}
unit Controls.Text;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Colors,
  Drawing.Rectangles,
  Drawing.Canvas,
  Font.Psf;

type
  THorizontalAlignment = (AlignTextLeft, AlignTextCenter, AlignTextRight);
  TCharacterOffsets = array of LongInt;

{ The text face (nil if the system has no fonts). }
function ControlFace: PFontFace;
function ControlBoldFace: PFontFace;
function TextWidth(Face: PFontFace; const Text: string): LongInt;
function TextHeight(Face: PFontFace): LongInt;
{ Text in Box, centred vertically, aligned across, "..." if too long. }
procedure DrawTextInBox(const Canvas: TCanvas; Face: PFontFace; const Text: string; const Box: TRectangle;
  Alignment: THorizontalAlignment; Color: TColor);
{ Disabled text: drawn twice, light then shadow, offset. }
procedure DrawDisabledText(const Canvas: TCanvas; Face: PFontFace; const Text: string; X, Y: LongInt);
{ Where each character starts (bytes, from 0), and one more entry: the
  length. }
function CharacterOffsets(const Text: string): TCharacterOffsets;
function CharacterCountOf(const Text: string): LongInt;
{ Characters First to First + Count - 1. }
function CharactersOf(const Text: string; First, Count: LongInt): string;

implementation

uses
  Font.Text,
  Font.Utf8,
  Windowing.Theme,
  Windowing.Fonts;

function ControlFace: PFontFace;
begin
  Result := TextFace;
end;

function ControlBoldFace: PFontFace;
begin
  Result := BoldTextFace;
end;

function TextWidth(Face: PFontFace; const Text: string): LongInt;
begin
  if Face = nil then
    Exit(0);
  Result := MeasureText(Face^, PChar(Text));
end;

function TextHeight(Face: PFontFace): LongInt;
begin
  if Face = nil then
    Exit(0);
  Result := Face^.Height;
end;

function CharacterOffsets(const Text: string): TCharacterOffsets;
var
  Cursor: PChar;
  CodePoint: LongWord;
  Count: LongInt;
begin
  SetLength(Result, Length(Text) + 1);
  Count := 0;
  Cursor := PChar(Text);
  Result[0] := 0;
  while NextCharacter(Cursor, CodePoint) do
  begin
    Inc(Count);
    Result[Count] := Cursor - PChar(Text);
  end;
  SetLength(Result, Count + 1);
end;

function CharacterCountOf(const Text: string): LongInt;
begin
  Result := CharacterCount(PChar(Text));
end;

function CharactersOf(const Text: string; First, Count: LongInt): string;
var
  Offsets: TCharacterOffsets;
  Last: LongInt;
begin
  Offsets := CharacterOffsets(Text);
  if First < 0 then
    First := 0;
  if First > High(Offsets) then
    First := High(Offsets);
  if Count < 0 then
    Count := 0;
  { Compared before adding: callers pass MaxInt for "to the end", and
    First + MaxInt would wrap round. }
  if Count > High(Offsets) - First then
    Last := High(Offsets)
  else
    Last := First + Count;
  Result := Copy(Text, Offsets[First] + 1, Offsets[Last] - Offsets[First]);
end;

{ Text cut short so it and "..." fit Width. }
function FittedText(Face: PFontFace; const Text: string; Width: LongInt): string;
var
  Count: LongInt;
begin
  if TextWidth(Face, Text) <= Width then
    Exit(Text);
  Count := CharacterCountOf(Text);
  while (Count > 0) and (TextWidth(Face, CharactersOf(Text, 0, Count) + '...') > Width) do
    Dec(Count);
  Result := CharactersOf(Text, 0, Count) + '...';
end;

procedure DrawTextInBox(const Canvas: TCanvas; Face: PFontFace; const Text: string; const Box: TRectangle;
  Alignment: THorizontalAlignment; Color: TColor);
var
  Shown: string;
  Width: LongInt;
  X: LongInt;
begin
  if Face = nil then
    Exit;
  Shown := FittedText(Face, Text, RectangleWidth(Box));
  Width := TextWidth(Face, Shown);
  case Alignment of
    AlignTextCenter: X := Box.Left + (RectangleWidth(Box) - Width) div 2;
    AlignTextRight: X := Box.Right - Width;
  else
    X := Box.Left;
  end;
  DrawText(Canvas, Face^, X, Box.Top + (RectangleHeight(Box) - Face^.Height) div 2, PChar(Shown), Color);
end;

procedure DrawDisabledText(const Canvas: TCanvas; Face: PFontFace; const Text: string; X, Y: LongInt);
begin
  if Face = nil then
    Exit;
  DrawText(Canvas, Face^, X + 1, Y + 1, PChar(Text), Theme.Highlight);
  DrawText(Canvas, Face^, X, Y, PChar(Text), Theme.DisabledText);
end;

end.
