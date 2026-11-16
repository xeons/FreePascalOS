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
  BMP's run-length encodings, RLE8 (8-bit palette indices) and RLE4 (4).

  The data is pairs of bytes. A count above zero repeats the second
  byte's index (RLE8) or alternates its two nibbles (RLE4) that many
  pixels. A count of zero is an escape: 0 ends the line, 1 the picture,
  2 moves right and down by the next two bytes, and 3 or more is that
  many indices as they are (absolute mode), padded to a whole number of
  16-bit words.

  Lines go from the bottom up (from the top down for a negative height,
  which the format does not allow but some writers produce). Pixels the
  data skips (by a move or by ending lines early) are left transparent;
  pixels outside the picture are dropped; data that ends without its end
  marker leaves what was decoded.
}
unit Image.Bmp.Rle;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Drawing.Colors,
  Image.Model,
  Image.Bmp.Headers;

procedure DecodeBmpRle(const Data: TBytes; Start: PtrInt; const Info: TBmpInfo; Image: TImage);

implementation

type
  TRleState = record
    Image: TImage;
    TopDown: Boolean;
    X: LongInt;
    Row: LongInt;
    Palette: array of TColor;
  end;

procedure PutIndex(var State: TRleState; PaletteIndex: Byte);
var
  Y: LongInt;
  Color: TColor;
begin
  if (State.X < State.Image.Width) and (State.Row < State.Image.Height) then
  begin
    if PaletteIndex < Length(State.Palette) then
      Color := State.Palette[PaletteIndex]
    else
      Color := ColorBlack;
    if State.TopDown then
      Y := State.Row
    else
      Y := State.Image.Height - 1 - State.Row;
    State.Image.Line(Y)[State.X] := Color;
  end;
  Inc(State.X);
end;

procedure DecodeBmpRle(const Data: TBytes; Start: PtrInt; const Info: TBmpInfo; Image: TImage);
var
  State: TRleState;
  Position: PtrInt;
  Size: PtrInt;
  Count: LongInt;
  Value: Byte;
  Index: LongInt;
  FourBits: Boolean;
  DataBytes: LongInt;
begin
  State.Image := Image;
  State.TopDown := Info.TopDown;
  State.X := 0;
  State.Row := 0;
  State.Palette := Info.Palette;
  FourBits := Info.Compression = BmpCompressionRle4;
  Position := Start;
  Size := Length(Data);
  while (Position + 2 <= Size) and (State.Row < Image.Height) do
  begin
    Count := Data[Position];
    Value := Data[Position + 1];
    Inc(Position, 2);
    if Count > 0 then
    begin
      for Index := 0 to Count - 1 do
        if not FourBits then
          PutIndex(State, Value)
        else if (Index and 1) = 0 then
          PutIndex(State, Value shr 4)
        else
          PutIndex(State, Value and 15);
      Continue;
    end;
    case Value of
      0:
        begin
          State.X := 0;
          Inc(State.Row);
        end;
      1:
        Break;
      2:
        begin
          if Position + 2 > Size then
            Break;
          Inc(State.X, Data[Position]);
          Inc(State.Row, Data[Position + 1]);
          Inc(Position, 2);
        end;
    else
      begin
        Count := Value;
        if FourBits then
          DataBytes := (Count + 1) div 2
        else
          DataBytes := Count;
        if Position + DataBytes > Size then
          Break;
        for Index := 0 to Count - 1 do
          if not FourBits then
            PutIndex(State, Data[Position + Index])
          else if (Index and 1) = 0 then
            PutIndex(State, Data[Position + Index div 2] shr 4)
          else
            PutIndex(State, Data[Position + Index div 2] and 15);
        Inc(Position, DataBytes + (DataBytes and 1));
      end;
    end;
  end;
end;

end.
