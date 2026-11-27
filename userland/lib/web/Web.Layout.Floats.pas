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
  The floats of one block formatting context.

  Floats are kept as margin boxes in the coordinates of the formatting
  context's root (its border box origin). Placing one follows CSS 2.2
  9.5.1: as high as possible but not above an earlier float or the
  current line, as far left (or right) as possible, moved down past
  floats until it fits. Line boxes and formatting context roots ask
  for the band left free at a height; clear asks for the bottom of the
  floats on a side.
}
unit Web.Layout.Floats;

{$mode objfpc}
{$H+}

interface

type
  TFloatRecord = record
    LeftSide: Boolean;
    X, Y, Width, Height: Single;
  end;

  TFloatContext = class
  private
    FFloats: array of TFloatRecord;
    FCount: Integer;
    FLowestTop: Single;
  public
    procedure Clear;
    { Drops the floats placed after the first Count (a layout redone). }
    procedure Truncate(NewCount: Integer);
    { The band free of floats between Top and Top + Height within
      [LeftLimit, RightLimit]; True if a float narrowed it. }
    function FreeBand(Top, Height, LeftLimit, RightLimit: Single; out Left, Right: Single): Boolean;
    { Places a float of the given margin box size at or below MinimumY;
      returns its margin box position. }
    procedure Place(LeftSide: Boolean; Width, Height, MinimumY, LeftLimit, RightLimit: Single;
      out PlacedX, PlacedY: Single);
    { The lowest float bottom on a side (Left, Right or both), -1e30 if none. }
    function ClearanceBottom(ClearLeft, ClearRight: Boolean): Single;
    { The first float bottom below Y within the band (to move down past),
      or Y when none. }
    function NextBottomBelow(Y, LeftLimit, RightLimit: Single): Single;
    { The first float bottom below Top of the floats between Top and
      Top + Height (where a box that does not fit beside them tries
      next), or Top when none. }
    function NextBottomWithin(Top, Height: Single): Single;
    function LowestBottom: Single;
    property Count: Integer read FCount;
  end;

implementation

const
  NoBottom = -1e30;

procedure TFloatContext.Clear;
begin
  FCount := 0;
  FLowestTop := 0;
end;

procedure TFloatContext.Truncate(NewCount: Integer);
var
  Index: Integer;
begin
  if NewCount < FCount then
  begin
    FCount := NewCount;
    FLowestTop := 0;
    for Index := 0 to FCount - 1 do
      if FFloats[Index].Y > FLowestTop then
        FLowestTop := FFloats[Index].Y;
  end;
end;

function TFloatContext.FreeBand(Top, Height, LeftLimit, RightLimit: Single; out Left, Right: Single): Boolean;
var
  Index: Integer;
  Bottom: Single;
  Float: ^TFloatRecord;
begin
  Left := LeftLimit;
  Right := RightLimit;
  Result := False;
  if Height < 1 then
    Height := 1;
  Bottom := Top + Height;
  for Index := 0 to FCount - 1 do
  begin
    Float := @FFloats[Index];
    if (Float^.Y >= Bottom) or (Float^.Y + Float^.Height <= Top) or (Float^.Height <= 0) then
      Continue;
    if Float^.LeftSide then
    begin
      if Float^.X + Float^.Width > Left then
      begin
        Left := Float^.X + Float^.Width;
        Result := True;
      end;
    end
    else if Float^.X < Right then
    begin
      Right := Float^.X;
      Result := True;
    end;
  end;
end;

function TFloatContext.NextBottomBelow(Y, LeftLimit, RightLimit: Single): Single;
var
  Index: Integer;
  Best: Single;
begin
  Best := 1e30;
  for Index := 0 to FCount - 1 do
    if (FFloats[Index].Y + FFloats[Index].Height > Y) and (FFloats[Index].Y <= Y) and
       (FFloats[Index].Y + FFloats[Index].Height < Best) then
      Best := FFloats[Index].Y + FFloats[Index].Height;
  if Best >= 1e30 then
    Result := Y
  else
    Result := Best;
end;

function TFloatContext.NextBottomWithin(Top, Height: Single): Single;
var
  Index: Integer;
  Best, Bottom: Single;
begin
  Best := 1e30;
  if Height < 1 then
    Height := 1;
  for Index := 0 to FCount - 1 do
  begin
    Bottom := FFloats[Index].Y + FFloats[Index].Height;
    if (FFloats[Index].Height > 0) and (FFloats[Index].Y < Top + Height) and (Bottom > Top) and (Bottom < Best) then
      Best := Bottom;
  end;
  if Best >= 1e30 then
    Result := Top
  else
    Result := Best;
end;

procedure TFloatContext.Place(LeftSide: Boolean; Width, Height, MinimumY, LeftLimit, RightLimit: Single;
  out PlacedX, PlacedY: Single);
var
  Y, Left, Right, Next: Single;
  Guard: Integer;
begin
  Y := MinimumY;
  if Y < FLowestTop then
    Y := FLowestTop;
  Guard := 0;
  repeat
    FreeBand(Y, Height, LeftLimit, RightLimit, Left, Right);
    if (Right - Left >= Width - 0.01) or ((Left = LeftLimit) and (Right = RightLimit)) then
      Break;
    Next := NextBottomBelow(Y, LeftLimit, RightLimit);
    if Next <= Y then
      Break;
    Y := Next;
    Inc(Guard);
  until Guard > 1000;
  if LeftSide then
    PlacedX := Left
  else
    PlacedX := Right - Width;
  PlacedY := Y;
  if FCount >= Length(FFloats) then
    SetLength(FFloats, FCount * 2 + 4);
  FFloats[FCount].LeftSide := LeftSide;
  FFloats[FCount].X := PlacedX;
  FFloats[FCount].Y := PlacedY;
  FFloats[FCount].Width := Width;
  FFloats[FCount].Height := Height;
  Inc(FCount);
  FLowestTop := PlacedY;
end;

function TFloatContext.ClearanceBottom(ClearLeft, ClearRight: Boolean): Single;
var
  Index: Integer;
begin
  Result := NoBottom;
  for Index := 0 to FCount - 1 do
    if (FFloats[Index].LeftSide and ClearLeft) or (not FFloats[Index].LeftSide and ClearRight) then
      if FFloats[Index].Y + FFloats[Index].Height > Result then
        Result := FFloats[Index].Y + FFloats[Index].Height;
end;

function TFloatContext.LowestBottom: Single;
begin
  Result := ClearanceBottom(True, True);
end;

end.
