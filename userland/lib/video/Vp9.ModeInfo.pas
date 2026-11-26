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
  What VP9 decodes about each block: its size, modes, transform size,
  segment, references and motion vectors (in eighth pixels), kept per
  8x8 unit ("mode info") of the frame: every unit a block covers points
  at the block's record, which is stored at the block's top left unit.

  The motion vectors of a frame are also kept per unit with its picture,
  since the next frame predicts its own from them.
}
unit Vp9.ModeInfo;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

type
  TVp9Mv = record
    Row, Col: SmallInt;
  end;
  PVp9Mv = ^TVp9Mv;

  TVp9SubblockInfo = record
    Mode: Byte;
    Mv: array[0..1] of TVp9Mv;
  end;

  TVp9ModeInfo = record
    BlockSize: Byte;
    Mode: Byte;
    UvMode: Byte;
    TransformSize: Byte;
    Skip: Boolean;
    Segment: Byte;
    SegmentPredicted: Byte;
    Filter: Byte;
    Reference: array[0..1] of ShortInt;
    Mv: array[0..1] of TVp9Mv;
    { The four 4x4 blocks of a block smaller than 8x8. }
    Subblocks: array[0..3] of TVp9SubblockInfo;
  end;
  PVp9ModeInfo = ^TVp9ModeInfo;
  PPVp9ModeInfo = ^PVp9ModeInfo;

  { A unit's references and motion vectors, kept for the next frame. }
  TVp9MvReference = record
    Reference: array[0..1] of ShortInt;
    Mv: array[0..1] of TVp9Mv;
  end;
  PVp9MvReference = ^TVp9MvReference;

  { The mode info of a frame: Cells[Row * Columns + Column] points at
    the record of the block covering the unit. }
  TVp9ModeInfoGrid = class
  public
    Rows, Columns: LongInt;
    Records: array of TVp9ModeInfo;
    Cells: array of PVp9ModeInfo;
    { Sizes the grid for Rows x Columns units, every cell empty. }
    procedure Resize(NewRows, NewColumns: LongInt);
  end;

function IsInter(Info: PVp9ModeInfo): Boolean; inline;
function HasSecondReference(Info: PVp9ModeInfo): Boolean; inline;
function SameMv(constref A, B: TVp9Mv): Boolean; inline;

implementation

procedure TVp9ModeInfoGrid.Resize(NewRows, NewColumns: LongInt);
begin
  Rows := NewRows;
  Columns := NewColumns;
  Records := nil;
  Cells := nil;
  SetLength(Records, Rows * Columns);
  SetLength(Cells, Rows * Columns);
end;

function IsInter(Info: PVp9ModeInfo): Boolean; inline;
begin
  Result := Info^.Reference[0] > 0;
end;

function HasSecondReference(Info: PVp9ModeInfo): Boolean; inline;
begin
  Result := Info^.Reference[1] > 0;
end;

function SameMv(constref A, B: TVp9Mv): Boolean; inline;
begin
  Result := (A.Row = B.Row) and (A.Col = B.Col);
end;

end.
