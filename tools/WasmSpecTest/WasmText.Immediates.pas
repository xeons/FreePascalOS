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
  Instruction immediates that are more than an index (core specification
  3.0, section 6.5): memory arguments, vector constants and lanes.

  A memory argument is "memidx? offset=n? align=n?". The offset is a
  64-bit number (memories may be 64-bit); a memory index other than 0
  is encoded by setting bit 6 of the alignment field and writing the
  index between alignment and offset. The lane load and store
  instructions take a memory argument and then a lane index, so there a
  leading number is the memory index only when another number (the
  lane) follows the memory argument.
}
unit WasmText.Immediates;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  WasmText.Lexer,
  WasmText.Tree,
  WasmText.Binary,
  WasmText.Context;

{ Alignment is the natural alignment (log2) the memarg defaults to;
  LaneFollows for the lane instructions. }
procedure ParseMemoryArgument(Context: TModuleContext; NaturalAlignment: Byte; LaneFollows: Boolean;
  Parent: TTextNode; var Position: Integer; Output: TBinaryWriter);
procedure ParseVectorConstant(Context: TModuleContext; Parent: TTextNode; var Position: Integer;
  Output: TBinaryWriter);
procedure ParseLane(Context: TModuleContext; Parent: TTextNode; var Position: Integer; Output: TBinaryWriter);

implementation

uses
  WasmText.Numbers;

const
  MemoryIndexFlag = $40;

function PowerOfTwoExponent(Value: QWord): Integer;
begin
  Result := -1;
  if (Value = 0) or ((Value and (Value - 1)) <> 0) then
    Exit;
  Result := 0;
  while Value > 1 do
  begin
    Value := Value shr 1;
    Inc(Result);
  end;
end;

function IsMemoryArgumentKeyword(Node: TTextNode): Boolean;
begin
  Result := Node.IsAtomOf(ttKeyword) and ((Copy(Node.Text, 1, 7) = 'offset=') or (Copy(Node.Text, 1, 6) = 'align='));
end;

function StartsWithMemoryIndex(Context: TModuleContext; LaneFollows: Boolean; Parent: TTextNode;
  Position: Integer): Boolean;
begin
  Result := (Position < Parent.Count) and Context.IsIndex(Parent[Position]);
  if not Result or not LaneFollows or Parent[Position].IsAtomOf(ttIdentifier) then
    Exit;
  Inc(Position);
  while (Position < Parent.Count) and IsMemoryArgumentKeyword(Parent[Position]) do
    Inc(Position);
  Result := (Position < Parent.Count) and Parent[Position].IsAtomOf(ttNumber);
end;

procedure ParseMemoryArgument(Context: TModuleContext; NaturalAlignment: Byte; LaneFollows: Boolean;
  Parent: TTextNode; var Position: Integer; Output: TBinaryWriter);
var
  Offset, Alignment: QWord;
  AlignmentExponent: Integer;
  MemoryIndex: Cardinal;
  Text: AnsiString;
begin
  Offset := 0;
  MemoryIndex := 0;
  AlignmentExponent := NaturalAlignment;
  if StartsWithMemoryIndex(Context, LaneFollows, Parent, Position) then
  begin
    MemoryIndex := Context.ResolveIndex(isMemory, Parent[Position]);
    Inc(Position);
  end;
  if (Position < Parent.Count) and Parent[Position].IsAtomOf(ttKeyword) and
     (Copy(Parent[Position].Text, 1, 7) = 'offset=') then
  begin
    Text := Copy(Parent[Position].Text, 8, MaxInt);
    Offset := ParseUnsigned(Text, 64);
    Inc(Position);
  end;
  if (Position < Parent.Count) and Parent[Position].IsAtomOf(ttKeyword) and
     (Copy(Parent[Position].Text, 1, 6) = 'align=') then
  begin
    Text := Copy(Parent[Position].Text, 7, MaxInt);
    Alignment := ParseUnsigned(Text, 64);
    AlignmentExponent := PowerOfTwoExponent(Alignment);
    if AlignmentExponent < 0 then
      Context.Fail(Parent[Position], 'alignment must be a power of two');
    Inc(Position);
  end;
  if MemoryIndex <> 0 then
  begin
    Output.WriteUnsigned(Cardinal(AlignmentExponent) or MemoryIndexFlag);
    Output.WriteUnsigned(MemoryIndex);
  end
  else
    Output.WriteUnsigned(AlignmentExponent);
  Output.WriteUnsigned(Offset);
end;

procedure ParseVectorConstant(Context: TModuleContext; Parent: TTextNode; var Position: Integer;
  Output: TBinaryWriter);
var
  Shape: AnsiString;
  LaneCount, LaneBytes, Lane, ByteIndex: Integer;
  Value: QWord;
  Node: TTextNode;
begin
  if Position >= Parent.Count then
    Context.Fail(Parent, 'unexpected end: v128.const needs a shape');
  Node := Parent[Position];
  Shape := Node.Text;
  if not Node.IsAtomOf(ttKeyword) then
    Context.Fail(Node, 'unexpected token: expected a vector shape');
  if Shape = 'i8x16' then begin LaneCount := 16; LaneBytes := 1; end
  else if Shape = 'i16x8' then begin LaneCount := 8; LaneBytes := 2; end
  else if (Shape = 'i32x4') or (Shape = 'f32x4') then begin LaneCount := 4; LaneBytes := 4; end
  else if (Shape = 'i64x2') or (Shape = 'f64x2') then begin LaneCount := 2; LaneBytes := 8; end
  else
  begin
    Context.Fail(Node, 'unexpected token: unknown vector shape ' + Shape);
    Exit;
  end;
  Inc(Position);
  for Lane := 0 to LaneCount - 1 do
  begin
    if (Position >= Parent.Count) or not (Parent[Position].IsAtomOf(ttNumber) or
       Parent[Position].IsAtomOf(ttKeyword)) then
      Context.Fail(Parent, 'wrong number of lane literals');
    Node := Parent[Position];
    if Shape[1] = 'f' then
    begin
      if LaneBytes = 4 then
        Value := ParseFloatBits(Node.Text, fpSingle)
      else
        Value := ParseFloatBits(Node.Text, fpDouble);
    end
    else
      Value := ParseIntegerBits(Node.Text, LaneBytes * 8);
    for ByteIndex := 0 to LaneBytes - 1 do
      Output.WriteByte(Byte((Value shr (8 * ByteIndex)) and $FF));
    Inc(Position);
  end;
  if (Position < Parent.Count) and Parent[Position].IsAtomOf(ttNumber) then
    Context.Fail(Parent[Position], 'wrong number of lane literals');
end;

procedure ParseLane(Context: TModuleContext; Parent: TTextNode; var Position: Integer; Output: TBinaryWriter);
begin
  if (Position >= Parent.Count) or not Parent[Position].IsAtomOf(ttNumber) then
    Context.Fail(Parent, 'unexpected token: expected a lane index');
  Output.WriteByte(Byte(ParseUnsigned(Parent[Position].Text, 8)));
  Inc(Position);
end;

end.
