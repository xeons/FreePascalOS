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
  The building blocks of a CFF table (Compact Font Format, the "CFF "
  and "CFF2" tables of OpenType fonts with PostScript outlines).

  An INDEX is an array of byte strings: a count (16 bits in CFF, 32 in
  CFF2), the size of an offset (1 to 4 bytes), count + 1 offsets (from
  1, relative to the byte before the data) and the data. A DICT is
  operands (numbers) followed by an operator (one byte, or 12 and a
  second byte); FindDictOperands gives the operands of one operator.

  Every read is checked against the table (Font.FontData); an INDEX
  whose offsets go backwards or past its table is refused.
}
unit Font.CffData;

{$mode objfpc}
{$H+}

interface

uses
  Font.FontData;

const
  { Two-byte DICT operators: 12 and the second byte, as 1200 + it. }
  EscapedOperator = 1200;

type
  TCffIndex = record
    Present: Boolean;
    Count: LongWord;
    OffsetSize: LongWord;
    { Where the offsets start, and the byte before the data (inside
      the table). }
    OffsetsStart: QWord;
    DataBase: QWord;
    { Where the next structure begins after it. }
    EndOffset: QWord;
    Table: TFontTable;
  end;

  TDictOperands = record
    Count: LongInt;
    Values: array[0..47] of Double;
  end;

{ The INDEX at Offset; Wide for CFF2's 32-bit count. False (and not
  Present) if it is broken. An empty INDEX is Present with Count 0. }
function ReadCffIndex(const Table: TFontTable; Offset: QWord; Wide: Boolean; out Index: TCffIndex): Boolean;
{ Item Item (0 based) of an INDEX as a part of the table. }
function CffIndexItem(const Index: TCffIndex; Item: LongWord): TFontTable;
{ The operands of OperatorCode in Dict (the last ones if it is given more
  than once); False if the DICT does not have it. Blend operators
  (CFF2's 23) keep only the default values. }
function FindDictOperands(const Dict: TFontTable; OperatorCode: LongInt; out Operands: TDictOperands): Boolean;
{ A DICT number operand at Position; Position moves past it. False if
  it is not a number. }
function ReadDictNumber(const Dict: TFontTable; var Position: QWord; out Value: Double): Boolean;
{ The bias added to a subroutine number for a subroutine INDEX of
  Count items. }
function SubroutineBias(Count: LongWord): LongInt;

implementation

const
  DictBlendOperator = 23;
  EscapeByte = 12;
  MaximumRealDigits = 64;

function ReadOffset(const Table: TFontTable; Position: QWord; Size: LongWord): QWord;
var
  Index: LongWord;
begin
  Result := 0;
  for Index := 1 to Size do
    Result := (Result shl 8) or ReadByte(Table, Position + Index - 1);
end;

function ReadCffIndex(const Table: TFontTable; Offset: QWord; Wide: Boolean; out Index: TCffIndex): Boolean;
var
  CountBytes: LongWord;
  Item: LongWord;
  Previous: QWord;
  Current: QWord;
begin
  Result := False;
  Index.Present := False;
  Index.Count := 0;
  Index.OffsetSize := 0;
  Index.OffsetsStart := 0;
  Index.DataBase := 0;
  Index.EndOffset := Offset;
  Index.Table := Table;
  if Wide then
    CountBytes := 4
  else
    CountBytes := 2;
  if not Has(Table, Offset, CountBytes) then
    Exit;
  if Wide then
    Index.Count := ReadUnsigned32(Table, Offset)
  else
    Index.Count := ReadUnsigned16(Table, Offset);
  if Index.Count = 0 then
  begin
    Index.Present := True;
    Index.EndOffset := Offset + CountBytes;
    Exit(True);
  end;
  if not Has(Table, Offset + CountBytes, 1) then
    Exit;
  Index.OffsetSize := ReadByte(Table, Offset + CountBytes);
  if (Index.OffsetSize < 1) or (Index.OffsetSize > 4) then
    Exit;
  Index.OffsetsStart := Offset + CountBytes + 1;
  if not Has(Table, Index.OffsetsStart, (QWord(Index.Count) + 1) * Index.OffsetSize) then
    Exit;
  Index.DataBase := Index.OffsetsStart + (QWord(Index.Count) + 1) * Index.OffsetSize - 1;
  { The offsets must start at 1 and never go backwards: checked once
    here, every item read later is inside the table. }
  Previous := ReadOffset(Table, Index.OffsetsStart, Index.OffsetSize);
  if Previous <> 1 then
    Exit;
  for Item := 1 to Index.Count do
  begin
    Current := ReadOffset(Table, Index.OffsetsStart + QWord(Item) * Index.OffsetSize, Index.OffsetSize);
    if Current < Previous then
      Exit;
    Previous := Current;
  end;
  if not Has(Table, Index.DataBase, Previous) then
    Exit;
  Index.EndOffset := Index.DataBase + Previous;
  Index.Present := True;
  Result := True;
end;

function CffIndexItem(const Index: TCffIndex; Item: LongWord): TFontTable;
var
  First: QWord;
  Last: QWord;
begin
  if not Index.Present or (Item >= Index.Count) then
    Exit(MissingTable);
  First := ReadOffset(Index.Table, Index.OffsetsStart + QWord(Item) * Index.OffsetSize, Index.OffsetSize);
  Last := ReadOffset(Index.Table, Index.OffsetsStart + QWord(Item + 1) * Index.OffsetSize, Index.OffsetSize);
  Result := Index.Table;
  Result.Start := Index.Table.Start + Index.DataBase + First;
  Result.Length := Last - First;
end;

{ A real number: nibbles of digits, a point, an exponent, a minus,
  ending with nibble 15. }
function ReadRealNumber(const Dict: TFontTable; var Position: QWord; out Value: Double): Boolean;
var
  Text: string;
  Nibble: LongWord;
  Bits: LongWord;
  Half: LongInt;
  Code: LongInt;
begin
  Result := False;
  Value := 0;
  Text := '';
  repeat
    if not Has(Dict, Position, 1) then
      Exit;
    Bits := ReadByte(Dict, Position);
    Inc(Position);
    for Half := 0 to 1 do
    begin
      if Half = 0 then
        Nibble := Bits shr 4
      else
        Nibble := Bits and 15;
      case Nibble of
        0..9: Text := Text + Chr(Ord('0') + Nibble);
        10: Text := Text + '.';
        11: Text := Text + 'E';
        12: Text := Text + 'E-';
        14: Text := Text + '-';
        15:
          begin
            Val(Text, Value, Code);
            if Code <> 0 then
              Value := 0;
            Exit(True);
          end;
      end;
    end;
  until Length(Text) > MaximumRealDigits;
end;

function ReadDictNumber(const Dict: TFontTable; var Position: QWord; out Value: Double): Boolean;
var
  First: LongWord;
begin
  Result := False;
  Value := 0;
  if not Has(Dict, Position, 1) then
    Exit;
  First := ReadByte(Dict, Position);
  case First of
    32..246:
      begin
        Value := LongInt(First) - 139;
        Inc(Position);
      end;
    247..250:
      begin
        if not Has(Dict, Position, 2) then
          Exit;
        Value := (LongInt(First) - 247) * 256 + LongInt(ReadByte(Dict, Position + 1)) + 108;
        Inc(Position, 2);
      end;
    251..254:
      begin
        if not Has(Dict, Position, 2) then
          Exit;
        Value := -(LongInt(First) - 251) * 256 - LongInt(ReadByte(Dict, Position + 1)) - 108;
        Inc(Position, 2);
      end;
    28:
      begin
        if not Has(Dict, Position, 3) then
          Exit;
        Value := ReadSigned16(Dict, Position + 1);
        Inc(Position, 3);
      end;
    29:
      begin
        if not Has(Dict, Position, 5) then
          Exit;
        Value := LongInt(ReadUnsigned32(Dict, Position + 1));
        Inc(Position, 5);
      end;
    30:
      begin
        Inc(Position);
        Exit(ReadRealNumber(Dict, Position, Value));
      end;
  else
    Exit;
  end;
  Result := True;
end;

{ CFF2's blend in a DICT: n default values, then n times the region
  count of deltas, then n. Only the defaults stay (the default
  instance of a variable font). }
procedure KeepBlendDefaults(var Operands: TDictOperands);
var
  Count: LongInt;
  Regions: LongInt;
  First: LongInt;
begin
  if Operands.Count < 1 then
    Exit;
  Count := Round(Operands.Values[Operands.Count - 1]);
  if (Count < 1) or (Count >= Operands.Count) then
  begin
    Operands.Count := 0;
    Exit;
  end;
  Regions := (Operands.Count - 1 - Count) div Count;
  First := Operands.Count - 1 - Count * (Regions + 1);
  if First < 0 then
  begin
    Operands.Count := 0;
    Exit;
  end;
  Operands.Count := First + Count;
end;

function FindDictOperands(const Dict: TFontTable; OperatorCode: LongInt; out Operands: TDictOperands): Boolean;
var
  Position: QWord;
  Current: TDictOperands;
  First: LongWord;
  Found: LongInt;
  Value: Double;
begin
  Result := False;
  Operands.Count := 0;
  Current.Count := 0;
  Position := 0;
  while Has(Dict, Position, 1) do
  begin
    First := ReadByte(Dict, Position);
    if First <= 24 then
    begin
      { An operator (28 to 30 and 32 up are numbers). }
      Inc(Position);
      if First = EscapeByte then
      begin
        if not Has(Dict, Position, 1) then
          Exit;
        Found := EscapedOperator + LongInt(ReadByte(Dict, Position));
        Inc(Position);
      end
      else
        Found := First;
      if Found = DictBlendOperator then
      begin
        KeepBlendDefaults(Current);
        Continue;
      end;
      if Found = OperatorCode then
      begin
        Operands := Current;
        Result := True;
      end;
      Current.Count := 0;
    end
    else
    begin
      if not ReadDictNumber(Dict, Position, Value) then
        Exit;
      if Current.Count <= High(Current.Values) then
      begin
        Current.Values[Current.Count] := Value;
        Inc(Current.Count);
      end;
    end;
  end;
end;

function SubroutineBias(Count: LongWord): LongInt;
begin
  if Count < 1240 then
    Result := 107
  else if Count < 33900 then
    Result := 1131
  else
    Result := 32768;
end;

end.
