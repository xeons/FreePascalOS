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
  PNG's five line filters, both ways.

  Every line of the image data starts with a byte naming its filter;
  the rest is the line's bytes, each stored as the difference from a
  prediction made of bytes already known: the byte a pixel to the left
  (Stride bytes back, 0 before the line starts), the byte above (0 on
  a pass's first line) and the byte above that one on the left:

    0 None     nothing predicted
    1 Sub      the left byte
    2 Up       the byte above
    3 Average  (left + above) div 2
    4 Paeth    whichever of left, above and upper left is nearest to
               left + above - upper left (ties in that order)

  All arithmetic is modulo 256. The decoder undoes a line in place,
  with the line above as it was unfiltered (a line of zeros for the
  first). The encoder filters a line into an output buffer; the
  adaptive choice (Image.Png.Writing) tries all five and keeps the one
  whose bytes, taken as signed, add up to the least: libpng's
  heuristic, good on photographs and drawings alike.
}
unit Image.Png.Filters;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Image.Errors;

const
  PngFilterNone = 0;
  PngFilterSub = 1;
  PngFilterUp = 2;
  PngFilterAverage = 3;
  PngFilterPaeth = 4;
  PngFilterCount = 5;

{ Undoes filter FilterType on Row (Count bytes) in place; Previous is
  the line above, unfiltered, Count bytes too. A filter type above 4 is
  ImageErrorMalformed. }
procedure UnfilterRow(FilterType: Byte; Row, Previous: PByte; Count, Stride: PtrInt);
{ Row filtered with FilterType into Output (Count bytes each). }
procedure FilterRow(FilterType: Byte; Row, Previous, Output: PByte; Count, Stride: PtrInt);
{ How well filtered bytes compress, roughly: the sum of their sizes as
  signed numbers (smaller is better). }
function FilteredRowCost(Filtered: PByte; Count: PtrInt): PtrUInt;

implementation

function PaethPredictor(Left, Above, UpperLeft: LongInt): LongInt; inline;
var
  DistanceLeft: LongInt;
  DistanceAbove: LongInt;
  DistanceUpperLeft: LongInt;
begin
  DistanceLeft := Abs(Above - UpperLeft);
  DistanceAbove := Abs(Left - UpperLeft);
  DistanceUpperLeft := Abs(Left + Above - 2 * UpperLeft);
  if (DistanceLeft <= DistanceAbove) and (DistanceLeft <= DistanceUpperLeft) then
    Result := Left
  else if DistanceAbove <= DistanceUpperLeft then
    Result := Above
  else
    Result := UpperLeft;
end;

procedure UnfilterSub(Row: PByte; Count, Stride: PtrInt);
var
  Index: PtrInt;
begin
  for Index := Stride to Count - 1 do
    Row[Index] := Byte(Row[Index] + Row[Index - Stride]);
end;

procedure UnfilterUp(Row, Previous: PByte; Count: PtrInt);
var
  Index: PtrInt;
begin
  for Index := 0 to Count - 1 do
    Row[Index] := Byte(Row[Index] + Previous[Index]);
end;

procedure UnfilterAverage(Row, Previous: PByte; Count, Stride: PtrInt);
var
  Index: PtrInt;
  First: PtrInt;
begin
  First := Stride;
  if First > Count then
    First := Count;
  for Index := 0 to First - 1 do
    Row[Index] := Byte(Row[Index] + Previous[Index] shr 1);
  for Index := First to Count - 1 do
    Row[Index] := Byte(Row[Index] + (LongWord(Row[Index - Stride]) + Previous[Index]) shr 1);
end;

procedure UnfilterPaeth(Row, Previous: PByte; Count, Stride: PtrInt);
var
  Index: PtrInt;
  First: PtrInt;
begin
  First := Stride;
  if First > Count then
    First := Count;
  { With nothing on the left the predictor is the byte above. }
  for Index := 0 to First - 1 do
    Row[Index] := Byte(Row[Index] + Previous[Index]);
  for Index := First to Count - 1 do
    Row[Index] := Byte(Row[Index] + PaethPredictor(Row[Index - Stride], Previous[Index], Previous[Index - Stride]));
end;

procedure UnfilterRow(FilterType: Byte; Row, Previous: PByte; Count, Stride: PtrInt);
begin
  case FilterType of
    PngFilterNone: ;
    PngFilterSub: UnfilterSub(Row, Count, Stride);
    PngFilterUp: UnfilterUp(Row, Previous, Count);
    PngFilterAverage: UnfilterAverage(Row, Previous, Count, Stride);
    PngFilterPaeth: UnfilterPaeth(Row, Previous, Count, Stride);
  else
    RaiseImageError(ImageErrorMalformed, 'PNG filter type ' + IntToStr(FilterType));
  end;
end;

procedure FilterRow(FilterType: Byte; Row, Previous, Output: PByte; Count, Stride: PtrInt);
var
  Index: PtrInt;
  Left: LongInt;
  UpperLeft: LongInt;
  Prediction: LongInt;
begin
  for Index := 0 to Count - 1 do
  begin
    if Index >= Stride then
    begin
      Left := Row[Index - Stride];
      UpperLeft := Previous[Index - Stride];
    end
    else
    begin
      Left := 0;
      UpperLeft := 0;
    end;
    case FilterType of
      PngFilterSub: Prediction := Left;
      PngFilterUp: Prediction := Previous[Index];
      PngFilterAverage: Prediction := (Left + Previous[Index]) shr 1;
      PngFilterPaeth: Prediction := PaethPredictor(Left, Previous[Index], UpperLeft);
    else
      Prediction := 0;
    end;
    Output[Index] := Byte(Row[Index] - Prediction);
  end;
end;

function FilteredRowCost(Filtered: PByte; Count: PtrInt): PtrUInt;
var
  Index: PtrInt;
  Value: LongWord;
begin
  Result := 0;
  for Index := 0 to Count - 1 do
  begin
    Value := Filtered[Index];
    if Value < 128 then
      Inc(Result, Value)
    else
      Inc(Result, 256 - Value);
  end;
end;

end.
