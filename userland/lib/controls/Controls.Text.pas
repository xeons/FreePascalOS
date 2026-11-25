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

  Captions may mark a mnemonic: an ampersand before a character ("&File",
  "Save &as...") makes that character the one Alt picks the control or
  menu item with, and it is drawn underlined; "&&" is an ampersand
  itself. The mnemonic functions draw and measure such captions without
  the ampersands.
}
unit Controls.Text;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Colors,
  Drawing.Rectangles,
  Drawing.Canvas,
  Font.Faces;

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

{ A caption without its mnemonic marks: what is shown ("&Save" gives
  "Save", "&&" gives "&"). }
function TextWithoutMnemonic(const Text: string): string;
{ The caption's mnemonic, a code point in lower case; 0 if it has none. }
function MnemonicOf(const Text: string): LongWord;
{ Whether Character (typed with Alt, say) picks the caption: the same
  letter in either case. }
function MnemonicMatches(const Text: string; Character: LongWord): Boolean;
function LowerCaseCharacter(CodePoint: LongWord): LongWord;
function MnemonicTextWidth(Face: PFontFace; const Text: string): LongInt;
{ DrawTextInBox and DrawDisabledText for captions: shown without the
  marks, the mnemonic underlined. }
procedure DrawMnemonicTextInBox(const Canvas: TCanvas; Face: PFontFace; const Text: string; const Box: TRectangle;
  Alignment: THorizontalAlignment; Color: TColor);
procedure DrawDisabledMnemonicText(const Canvas: TCanvas; Face: PFontFace; const Text: string; X, Y: LongInt);

implementation

uses
  Font.Text,
  Font.Utf8,
  Font.ColorBitmaps,
  Image.PictureColors,
  Controls.TextPositions,
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
  CodePoint: LongWord;
  CharacterBytes: LongInt;
  Count: LongInt;
begin
  Result := nil;
  SetLength(Result, Length(Text) + 1);
  Count := 0;
  Result[0] := 0;
  { Up to a zero byte, where Font.Utf8 stops, as drawing does. }
  CharacterBytes := CharacterAt(Text, 1, CodePoint);
  while CharacterBytes > 0 do
  begin
    Inc(Count);
    Result[Count] := Result[Count - 1] + CharacterBytes;
    CharacterBytes := CharacterAt(Text, Result[Count] + 1, CodePoint);
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

{ --- Mnemonics ------------------------------------------------------------------ }

const
  MnemonicMark = '&';

{ Where the mnemonic character starts in the shown text (bytes, from 1),
  0 if none: only the first single ampersand counts. }
function MnemonicPosition(const Text: string): LongInt;
var
  Index: LongInt;
  Shown: LongInt;
begin
  Result := 0;
  Index := 1;
  Shown := 0;
  while Index <= Length(Text) do
  begin
    if (Text[Index] = MnemonicMark) and (Index < Length(Text)) then
    begin
      Inc(Index);
      if Text[Index] <> MnemonicMark then
        Exit(Shown + 1);
    end;
    Inc(Shown);
    Inc(Index);
  end;
end;

function TextWithoutMnemonic(const Text: string): string;
var
  Index: LongInt;
begin
  Result := '';
  Index := 1;
  while Index <= Length(Text) do
  begin
    { A mark is dropped; the character after it stays (an ampersand too,
      for "&&"). }
    if (Text[Index] = MnemonicMark) and (Index < Length(Text)) then
      Inc(Index);
    Result := Result + Text[Index];
    Inc(Index);
  end;
end;

function LowerCaseCharacter(CodePoint: LongWord): LongWord;
begin
  Result := CodePoint;
  if (CodePoint >= Ord('A')) and (CodePoint <= Ord('Z')) then
    Result := CodePoint + (Ord('a') - Ord('A'));
end;

function MnemonicOf(const Text: string): LongWord;
var
  Shown: string;
  Position: LongInt;
  CodePoint: LongWord;
begin
  Result := 0;
  Position := MnemonicPosition(Text);
  if Position = 0 then
    Exit;
  Shown := TextWithoutMnemonic(Text);
  if CharacterAt(Shown, Position, CodePoint) > 0 then
    Result := LowerCaseCharacter(CodePoint);
end;

function MnemonicMatches(const Text: string; Character: LongWord): Boolean;
begin
  Result := (Character <> 0) and (MnemonicOf(Text) = LowerCaseCharacter(Character));
end;

function MnemonicTextWidth(Face: PFontFace; const Text: string): LongInt;
begin
  Result := TextWidth(Face, TextWithoutMnemonic(Text));
end;

{ A line under the mnemonic of Text, which is drawn without its marks
  at (X, Y) as Shown. Shown may have been cut short with "...": then the
  line goes only if the mnemonic is still before the dots. }
procedure UnderlineMnemonic(const Canvas: TCanvas; Face: PFontFace; const Text, Shown: string; X, Y: LongInt;
  Color: TColor);
var
  Position: LongInt;
  VisibleLength: LongInt;
  CodePoint: LongWord;
  CharacterBytes: LongInt;
  Left: LongInt;
  Width: LongInt;
  LineTop: LongInt;
  Thickness: LongInt;
begin
  Position := MnemonicPosition(Text);
  if Position = 0 then
    Exit;
  VisibleLength := Length(Shown);
  if Shown <> TextWithoutMnemonic(Text) then
    VisibleLength := Length(Shown) - Length('...');
  if Position > VisibleLength then
    Exit;
  CharacterBytes := CharacterAt(Shown, Position, CodePoint);
  if CharacterBytes = 0 then
    Exit;
  if Position + CharacterBytes - 1 > VisibleLength then
    Exit;
  { Measured with the character, so kerning before it counts. }
  Width := TextWidth(Face, Copy(Shown, Position, CharacterBytes));
  Left := X + TextWidth(Face, Copy(Shown, 1, Position + CharacterBytes - 1)) - Width;
  { Where the face puts its underline: just under the baseline. }
  LineTop := Y + Face^.UnderlineTop;
  Thickness := Face^.UnderlineThickness;
  FillRectangle(Canvas, MakeRectangle(Left, LineTop, Width, Thickness), Color);
end;

procedure DrawMnemonicTextInBox(const Canvas: TCanvas; Face: PFontFace; const Text: string; const Box: TRectangle;
  Alignment: THorizontalAlignment; Color: TColor);
var
  Shown: string;
  Width: LongInt;
  X: LongInt;
  Y: LongInt;
begin
  if Face = nil then
    Exit;
  Shown := FittedText(Face, TextWithoutMnemonic(Text), RectangleWidth(Box));
  Width := TextWidth(Face, Shown);
  case Alignment of
    AlignTextCenter: X := Box.Left + (RectangleWidth(Box) - Width) div 2;
    AlignTextRight: X := Box.Right - Width;
  else
    X := Box.Left;
  end;
  Y := Box.Top + (RectangleHeight(Box) - Face^.Height) div 2;
  DrawText(Canvas, Face^, X, Y, PChar(Shown), Color);
  UnderlineMnemonic(Canvas, Face, Text, Shown, X, Y, Color);
end;

procedure DrawDisabledMnemonicText(const Canvas: TCanvas; Face: PFontFace; const Text: string; X, Y: LongInt);
var
  Shown: string;
begin
  if Face = nil then
    Exit;
  Shown := TextWithoutMnemonic(Text);
  DrawText(Canvas, Face^, X + 1, Y + 1, PChar(Shown), Theme.Highlight);
  UnderlineMnemonic(Canvas, Face, Text, Shown, X + 1, Y + 1, Theme.Highlight);
  DrawText(Canvas, Face^, X, Y, PChar(Shown), Theme.DisabledText);
  UnderlineMnemonic(Canvas, Face, Text, Shown, X, Y, Theme.DisabledText);
end;

initialization
  { Colour glyphs (emoji) are decoded with libimage. }
  if ColorBitmapDecoder = nil then
    ColorBitmapDecoder := @DecodePictureColors;
end.
