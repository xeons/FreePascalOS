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
  Surfaces for the rasterizer's groups, kept for the next group.

  Every opacity group, rounded clip, mask and filter draws into a
  transparent surface of its own; allocating and freeing one each time
  (large blocks come straight from the system, fresh pages every time)
  cost more than the drawing in it. Returned pixels are kept, up to a
  few blocks and a byte budget, and lent again to a group that fits in
  them, cleared to transparent.

  Painting is single threaded, as the glyph cache is.
}
unit Web.Paint.SurfacePool;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Surfaces;

{ A transparent Width x Height surface (Stride = Width). False when
  there is no memory or a size is not positive. }
function TakePooledSurface(out Surface: TSurface; Width, Height: LongInt): Boolean;
{ Gives a surface from TakePooledSurface back (Surface is emptied); one
  that is not the pool's is freed. }
procedure ReturnPooledSurface(var Surface: TSurface);
{ Frees the kept blocks. }
procedure EmptySurfacePool;

implementation

const
  { The blocks kept when not lent, and the bytes they may hold. }
  KeptBlockLimit = 8;
  KeptByteLimit = 32 * 1024 * 1024;

type
  TPoolBlock = record
    Pixels: PLongWord;
    { Pixels the block holds. }
    Capacity: PtrUInt;
    Lent: Boolean;
  end;

var
  Blocks: array of TPoolBlock;
  BlockCount: Integer = 0;

function KeptBytes: PtrUInt;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 0 to BlockCount - 1 do
    if not Blocks[Index].Lent then
      Inc(Result, Blocks[Index].Capacity * SizeOf(LongWord));
end;

function KeptBlocks: Integer;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 0 to BlockCount - 1 do
    if not Blocks[Index].Lent then
      Inc(Result);
end;

procedure RemoveBlock(Index: Integer);
begin
  FreeMem(Blocks[Index].Pixels);
  Blocks[Index] := Blocks[BlockCount - 1];
  Dec(BlockCount);
end;

{ The smallest kept block holding Count pixels, else -1. }
function FittingBlock(Count: PtrUInt): Integer;
var
  Index: Integer;
begin
  Result := -1;
  for Index := 0 to BlockCount - 1 do
    if not Blocks[Index].Lent and (Blocks[Index].Capacity >= Count) and
       ((Result < 0) or (Blocks[Index].Capacity < Blocks[Result].Capacity)) then
      Result := Index;
end;

{ The largest (or smallest) kept block, else -1. }
function ExtremeKeptBlock(Largest: Boolean): Integer;
var
  Index: Integer;
begin
  Result := -1;
  for Index := 0 to BlockCount - 1 do
    if not Blocks[Index].Lent and ((Result < 0) or
       ((Blocks[Index].Capacity > Blocks[Result].Capacity) = Largest)) then
      Result := Index;
end;

function TakePooledSurface(out Surface: TSurface; Width, Height: LongInt): Boolean;
var
  Count: PtrUInt;
  Index: Integer;
  Pixels: PLongWord;
begin
  Surface := Default(TSurface);
  if (Width <= 0) or (Height <= 0) then
    Exit(False);
  Count := PtrUInt(Width) * PtrUInt(Height);
  Index := FittingBlock(Count);
  if Index < 0 then
  begin
    Pixels := GetMem(Count * SizeOf(LongWord));
    if Pixels = nil then
      Exit(False);
    if BlockCount >= Length(Blocks) then
      SetLength(Blocks, BlockCount * 2 + 8);
    Index := BlockCount;
    Inc(BlockCount);
    Blocks[Index].Pixels := Pixels;
    Blocks[Index].Capacity := Count;
  end;
  Blocks[Index].Lent := True;
  FillChar(Blocks[Index].Pixels^, Count * SizeOf(LongWord), 0);
  Surface := SurfaceOnPixels(Blocks[Index].Pixels, Width, Height, Width * SizeOf(LongWord));
  Result := True;
end;

procedure ReturnPooledSurface(var Surface: TSurface);
var
  Index, Victim: Integer;
begin
  if Surface.Pixels = nil then
    Exit;
  if Surface.OwnsPixels then
  begin
    FreeSurface(Surface);
    Exit;
  end;
  for Index := 0 to BlockCount - 1 do
    if Blocks[Index].Lent and (Blocks[Index].Pixels = Surface.Pixels) then
    begin
      Blocks[Index].Lent := False;
      { Over the budget: the largest blocks go while the bytes are too
        many, the smallest while the blocks are. }
      while KeptBytes > KeptByteLimit do
      begin
        Victim := ExtremeKeptBlock(True);
        if Victim < 0 then
          Break;
        RemoveBlock(Victim);
      end;
      while KeptBlocks > KeptBlockLimit do
      begin
        Victim := ExtremeKeptBlock(False);
        if Victim < 0 then
          Break;
        RemoveBlock(Victim);
      end;
      Break;
    end;
  Surface := Default(TSurface);
end;

procedure EmptySurfacePool;
var
  Index: Integer;
begin
  Index := BlockCount - 1;
  while Index >= 0 do
  begin
    if not Blocks[Index].Lent then
      RemoveBlock(Index);
    Dec(Index);
  end;
end;

finalization
  EmptySurfacePool;
end.
