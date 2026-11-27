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
  Select Graphic Rendition (ESC [ ... m): how the characters written
  from now on look.

    0 everything back to the default        1 bold (2, faint, too)
    4 underline     7 reverse               22 not bold, 24 not underlined,
                                            27 not reversed
    30-37 text colour, 39 the default        40-47 background, 49 default
    90-97 bright text colour                 100-107 bright background
    38;5;N and 48;5;N: colour N of the 256-colour palette (the first
    sixteen are the palette's; others are taken to the nearest of them)
    38;2;R;G;B and 48;2;R;G;B: a colour by value, to the nearest too
}
unit Terminal.Rendition;

{$mode objfpc}

interface

uses
  Terminal.Cells;

{ Applies Count parameters (none means 0) to Pen. }
procedure SelectGraphicRendition(var Pen: TCell; const Parameters: array of LongInt; Count: LongInt);

implementation

const
  { The palette's colours as red, green, blue: for colours given by
    value, which take the nearest. }
  PaletteRed: array[0..PaletteSize - 1] of Byte = (0, 205, 13, 229, 36, 188, 17, 229, 102, 241, 35, 245, 59, 214, 41, 255);
  PaletteGreen: array[0..PaletteSize - 1] of Byte = (0, 49, 188, 229, 114, 63, 168, 229, 102, 76, 209, 245, 142, 112, 184, 255);
  PaletteBlue: array[0..PaletteSize - 1] of Byte = (0, 49, 121, 16, 200, 188, 205, 229, 102, 76, 139, 67, 234, 214, 219, 255);

function NearestPaletteColor(Red, Green, Blue: LongInt): Byte;
var
  Index: LongInt;
  Distance: LongInt;
  Best: LongInt;
begin
  Result := 0;
  Best := MaxInt;
  for Index := 0 to PaletteSize - 1 do
  begin
    Distance := Sqr(Red - PaletteRed[Index]) + Sqr(Green - PaletteGreen[Index]) + Sqr(Blue - PaletteBlue[Index]);
    if Distance < Best then
    begin
      Best := Distance;
      Result := Byte(Index);
    end;
  end;
end;

{ Colour N of the 256-colour palette: 16 basic, a 6x6x6 cube, 24 greys. }
function ExtendedColor(Number: LongInt): Byte;
const
  CubeLevels: array[0..5] of LongInt = (0, 95, 135, 175, 215, 255);
var
  Cube: LongInt;
  Grey: LongInt;
begin
  if (Number >= 0) and (Number < PaletteSize) then
    Exit(Byte(Number));
  if (Number >= 16) and (Number < 232) then
  begin
    Cube := Number - 16;
    Exit(NearestPaletteColor(CubeLevels[Cube div 36], CubeLevels[(Cube div 6) mod 6], CubeLevels[Cube mod 6]));
  end;
  if (Number >= 232) and (Number < 256) then
  begin
    Grey := 8 + (Number - 232) * 10;
    Exit(NearestPaletteColor(Grey, Grey, Grey));
  end;
  Result := ColorDefault;
end;

{ 38 or 48 and what follows: sets Color and moves Index past it. }
procedure TakeChosenColor(const Parameters: array of LongInt; Count: LongInt; var Index: LongInt; out Color: Byte);
begin
  Color := ColorDefault;
  if (Index + 2 < Count) and (Parameters[Index + 1] = 5) then
  begin
    Color := ExtendedColor(Parameters[Index + 2]);
    Index := Index + 2;
  end
  else if (Index + 4 < Count) and (Parameters[Index + 1] = 2) then
  begin
    Color := NearestPaletteColor(Parameters[Index + 2], Parameters[Index + 3], Parameters[Index + 4]);
    Index := Index + 4;
  end;
end;

procedure SelectGraphicRendition(var Pen: TCell; const Parameters: array of LongInt; Count: LongInt);
var
  Index: LongInt;
  Value: LongInt;
  Color: Byte;
begin
  if Count = 0 then
  begin
    Pen := DefaultPen;
    Exit;
  end;
  Index := 0;
  while Index < Count do
  begin
    Value := Parameters[Index];
    case Value of
      0: Pen := DefaultPen;
      1, 2: Pen.Attributes := Pen.Attributes or AttributeBold;
      4: Pen.Attributes := Pen.Attributes or AttributeUnderline;
      7: Pen.Attributes := Pen.Attributes or AttributeReverse;
      22: Pen.Attributes := Pen.Attributes and not AttributeBold;
      24: Pen.Attributes := Pen.Attributes and not AttributeUnderline;
      27: Pen.Attributes := Pen.Attributes and not AttributeReverse;
      30..37: Pen.Foreground := Byte(Value - 30);
      38:
        begin
          TakeChosenColor(Parameters, Count, Index, Color);
          Pen.Foreground := Color;
        end;
      39: Pen.Foreground := ColorDefault;
      40..47: Pen.Background := Byte(Value - 40);
      48:
        begin
          TakeChosenColor(Parameters, Count, Index, Color);
          Pen.Background := Color;
        end;
      49: Pen.Background := ColorDefault;
      90..97: Pen.Foreground := Byte(Value - 90 + BrightOffset);
      100..107: Pen.Background := Byte(Value - 100 + BrightOffset);
    end;
    Inc(Index);
  end;
end;

end.
