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
  What the PNG writer needs to know of a picture's colours to pick the
  smallest colour type: whether every pixel is opaque, whether every
  pixel is grey (red, green and blue equal), and, while there are no
  more than 256, the distinct colours and each one's palette index.

  The colours are kept in a small open-addressing hash table, so
  looking a pixel up costs about the same whatever the picture; once a
  257th colour turns up the table is given up (Fits becomes False).
  The palette is ordered with the colours that are not opaque first,
  so tRNS (one alpha for each of the first entries) is as short as it
  can be.
}
unit Image.Png.ColorTable;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Drawing.Colors,
  Image.Model;

const
  PngPaletteLimit = 256;

type
  TPngColorTable = class
  private
    FSlots: array[0..1023] of LongWord;
    FSlotUsed: array[0..1023] of Boolean;
    FSlotIndex: array[0..1023] of Word;
    FColors: array[0..PngPaletteLimit - 1] of TColor;
    FCount: LongInt;
    FFits: Boolean;
    FOpaque: Boolean;
    FGrey: Boolean;
    FTranslucentCount: LongInt;
    function SlotOf(Color: TColor): LongInt;
    procedure Add(Color: TColor);
    procedure Order;
  public
    constructor Create;
    { Counts Image's colours with those of the pictures added before. }
    procedure AddImage(Image: TImage);
    { Puts the palette in its final order; call after the last AddImage. }
    procedure Finish;
    { The palette index of Color (one of the picture's). }
    function IndexOf(Color: TColor): LongInt;
    function GetColor(Index: LongInt): TColor;
    { No more than 256 colours. }
    property Fits: Boolean read FFits;
    property Count: LongInt read FCount;
    property Opaque: Boolean read FOpaque;
    property Grey: Boolean read FGrey;
    { The entries, from the first, that are not opaque. }
    property TranslucentCount: LongInt read FTranslucentCount;
  end;

implementation

const
  SlotMask = 1023;

constructor TPngColorTable.Create;
begin
  inherited Create;
  FFits := True;
  FOpaque := True;
  FGrey := True;
end;

function HashColor(Color: TColor): LongWord; inline;
begin
  Result := (Color * LongWord(2654435761)) shr 22;
end;

function TPngColorTable.SlotOf(Color: TColor): LongInt;
begin
  Result := HashColor(Color) and SlotMask;
  while FSlotUsed[Result] and (FSlots[Result] <> Color) do
    Result := (Result + 1) and SlotMask;
end;

procedure TPngColorTable.Add(Color: TColor);
var
  Slot: LongInt;
begin
  Slot := SlotOf(Color);
  if FSlotUsed[Slot] then
    Exit;
  if FCount = PngPaletteLimit then
  begin
    FFits := False;
    Exit;
  end;
  FSlotUsed[Slot] := True;
  FSlots[Slot] := Color;
  FSlotIndex[Slot] := FCount;
  FColors[FCount] := Color;
  Inc(FCount);
end;

procedure TPngColorTable.AddImage(Image: TImage);
var
  Index: PtrUInt;
  Total: PtrUInt;
  Color: TColor;
  Previous: TColor;
begin
  Total := PtrUInt(Image.Width) * PtrUInt(Image.Height);
  Previous := 0;
  for Index := 0 to Total - 1 do
  begin
    Color := Image.Pixels[Index];
    if (Index > 0) and (Color = Previous) then
      Continue;
    Previous := Color;
    if (Color shr 24) <> AlphaOpaque then
      FOpaque := False;
    if FGrey and ((RedOf(Color) <> GreenOf(Color)) or (GreenOf(Color) <> BlueOf(Color))) then
      FGrey := False;
    if FFits then
      Add(Color);
  end;
end;

{ Translucent colours first, keeping the order they came in. }
procedure TPngColorTable.Order;
var
  Ordered: array[0..PngPaletteLimit - 1] of TColor;
  Index: LongInt;
  Position: LongInt;
begin
  Position := 0;
  for Index := 0 to FCount - 1 do
    if (FColors[Index] shr 24) <> AlphaOpaque then
    begin
      Ordered[Position] := FColors[Index];
      Inc(Position);
    end;
  FTranslucentCount := Position;
  for Index := 0 to FCount - 1 do
    if (FColors[Index] shr 24) = AlphaOpaque then
    begin
      Ordered[Position] := FColors[Index];
      Inc(Position);
    end;
  for Index := 0 to FCount - 1 do
  begin
    FColors[Index] := Ordered[Index];
    FSlotIndex[SlotOf(Ordered[Index])] := Index;
  end;
end;

procedure TPngColorTable.Finish;
begin
  if FFits then
    Order;
end;

function TPngColorTable.IndexOf(Color: TColor): LongInt;
var
  Slot: LongInt;
begin
  Slot := SlotOf(Color);
  if FSlotUsed[Slot] then
    Result := FSlotIndex[Slot]
  else
    Result := 0;
end;

function TPngColorTable.GetColor(Index: LongInt): TColor;
begin
  Result := FColors[Index];
end;

end.
