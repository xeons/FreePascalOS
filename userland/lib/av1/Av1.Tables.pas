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
  The AV1 specification's constant arrays (Av1.Tables.inc, written by
  make-tables.py with the specification's names: scan orders, block and
  transform size conversions, filter kernels, quantizer lookups, ...)
  and the block dimension helpers the specification writes as
  Block_Width[ ] and Block_Height[ ].
}
unit Av1.Tables;

{$mode objfpc}

interface

uses
  Av1.Constants;

{$I Av1.Tables.inc}

type
  TScanOrder = PWord;

{ Block_Width[ size ] and Block_Height[ size ] of the specification. }
function Block_Width(BlockSize: Integer): Integer; inline;
function Block_Height(BlockSize: Integer): Integer; inline;

implementation

function Block_Width(BlockSize: Integer): Integer;
begin
  Result := Num_4x4_Blocks_Wide[BlockSize] * 4;
end;

function Block_Height(BlockSize: Integer): Integer;
begin
  Result := Num_4x4_Blocks_High[BlockSize] * 4;
end;

end.
