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
  What a box is laid out with: the containing block's size, how its
  width is found (filling the containing block, shrink-to-fit, or given
  by a flex, grid or table container), the block formatting context's
  floats with the box's offset in it, and the lists the absolutely
  positioned and fixed boxes met on the way are put on (laid out once
  their containing block's size is known).
}
unit Web.Layout.Context;

{$mode objfpc}
{$H+}

interface

uses
  Web.Layout.Boxes, Web.Layout.Floats;

type
  TWidthMode = (
    { A block-level box in normal flow: fill the containing block. }
    wmStretch,
    { Floats, inline-blocks, absolutely positioned boxes with auto width. }
    wmShrinkToFit,
    { The border box width is given (FixedWidth). }
    wmFixed);

  TPositionedList = class
  public
    Boxes: array of TLayoutBox;
    Count: Integer;
    procedure Add(Box: TLayoutBox);
    procedure Clear;
  end;

  TLayoutInput = record
    { The containing block's content width and height (Indefinite = -1). }
    AvailableWidth: Single;
    ContainingHeight: Single;
    WidthMode: TWidthMode;
    FixedWidth: Single;
    { A border box height given from outside (flex, grid, tables), -1 none. }
    FixedHeight: Single;
    { The block formatting context the box is in, and the box's border
      box origin in its coordinates. }
    Floats: TFloatContext;
    BfcX, BfcY: Single;
    { Absolutely positioned boxes go to Positioned (their containing
      block's list), fixed ones to FixedBoxes (the viewport's). }
    Positioned: TPositionedList;
    FixedBoxes: TPositionedList;
    ViewportWidth, ViewportHeight: Single;
  end;

function SameLayoutInput(Box: TLayoutBox; const Input: TLayoutInput): Boolean;
procedure RememberLayoutInput(Box: TLayoutBox; const Input: TLayoutInput);

implementation

procedure TPositionedList.Add(Box: TLayoutBox);
begin
  if Count >= Length(Boxes) then
    SetLength(Boxes, Count * 2 + 4);
  Boxes[Count] := Box;
  Inc(Count);
end;

procedure TPositionedList.Clear;
begin
  Count := 0;
end;

function InputKey(const Input: TLayoutInput): Single;
begin
  case Input.WidthMode of
    wmFixed: Result := 100000 + Input.FixedWidth;
    wmShrinkToFit: Result := -100000 - Input.AvailableWidth;
  else
    Result := Input.AvailableWidth;
  end;
end;

function SameLayoutInput(Box: TLayoutBox; const Input: TLayoutInput): Boolean;
begin
  Result := (Box.LastAvailableWidth = InputKey(Input)) and
    (Box.LastAvailableHeight = Input.ContainingHeight + Input.FixedHeight * 3);
end;

procedure RememberLayoutInput(Box: TLayoutBox; const Input: TLayoutInput);
begin
  Box.LastAvailableWidth := InputKey(Input);
  Box.LastAvailableHeight := Input.ContainingHeight + Input.FixedHeight * 3;
end;

end.
