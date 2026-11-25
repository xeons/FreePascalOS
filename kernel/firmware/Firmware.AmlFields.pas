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
  AML fields: reading and writing bits of operation regions and buffers.

  A field is accessed a unit at a time, units as wide as its access
  type (byte, word, double word, quad word; "any" is a byte), aligned
  in its region. Reading takes the units the field's bits fall in and
  gathers the bits; writing builds each unit from the new bits and,
  for the bits outside the field, what the update rule says: what was
  there (read first), ones, or zeros.

  Where a unit is reached depends on the field: a plain field reads its
  region; a bank field first writes its bank value into the bank
  field; an index field writes the unit's byte offset into its index
  field and then reads or writes its data field; a buffer field reads
  its buffer's bytes. Regions go through AmlHost; a PCI configuration
  region finds its device from the _ADR of the device it is in, and
  the bus and segment from _BBN and _SEG above it.

  A field of up to an integer's width reads as an integer, a longer
  one as a buffer.
}
unit Firmware.AmlFields;

{$mode objfpc}
{$pointermath on}

interface

uses
  Firmware.AmlValues,
  Firmware.AmlNamespace;

function ReadField(Node: PAmlNode; out Value: TAmlValue): Boolean;
function WriteField(Node: PAmlNode; const Value: TAmlValue): Boolean;

implementation

uses
  Runtime.Memory,
  Firmware.AmlHost,
  Firmware.AmlInterpreter;

const
  MaximumFieldBytes = 4096;
  { Fields reached through fields (index and bank fields over index and
    bank fields): each level reaches the one below at least twice, so a
    chain of them is exponential. Firmware uses one or two levels. }
  MaximumFieldNesting = 8;

var
  FieldNesting: Integer = 0;

{ --- Regions ------------------------------------------------------------------ }

{ The PCI address (segment, bus, device, function) of a configuration
  region, found once. }
function PciAddressOf(Region: PAmlNode): QWord;
var
  Scope: PAmlNode;
  Address: QWord;
  Bus: QWord;
  Segment: QWord;
begin
  if Region^.PciAddressKnown then
    Exit(Region^.PciAddress);
  Address := 0;
  Bus := 0;
  Segment := 0;
  Scope := Region^.Parent;
  { The device the region is in, then the bus and segment above it. }
  while (Scope <> nil) and (FindChild(Scope, SegmentOf('_ADR')) = nil) and
        (FindChild(Scope, SegmentOf('_BBN')) = nil) do
    Scope := Scope^.Parent;
  if (Scope <> nil) and (FindChild(Scope, SegmentOf('_ADR')) <> nil) then
    Address := EvaluateInteger(Scope, '_ADR', 0);
  while (Scope <> nil) and (FindChild(Scope, SegmentOf('_BBN')) = nil) and
        (FindChild(Scope, SegmentOf('_SEG')) = nil) do
    Scope := Scope^.Parent;
  if Scope <> nil then
  begin
    Bus := EvaluateInteger(Scope, '_BBN', 0);
    Segment := EvaluateInteger(Scope, '_SEG', 0);
  end;
  Region^.PciAddress := PciConfigurationAddress(Word(Segment), Byte(Bus), Byte(Address shr 16),
    Byte(Address and $FFFF), 0);
  Region^.PciAddressKnown := True;
  Result := Region^.PciAddress;
end;

function RegionAddress(Region: PAmlNode; ByteOffset: QWord): QWord;
begin
  Result := Region^.RegionOffset + ByteOffset;
  if Region^.Space = AmlSpacePciConfiguration then
    Result := PciAddressOf(Region) or (Result and $FFFFFF);
end;

{ Accesses stay inside the region the table declared: a field defined
  past its end would otherwise reach memory or ports the region does not
  name. }
function AccessIsInRegion(Region: PAmlNode; ByteOffset: QWord; Width: Byte): Boolean;
begin
  Result := (ByteOffset <= Region^.RegionLength) and (Width <= Region^.RegionLength - ByteOffset);
end;

function ReadRegion(Region: PAmlNode; ByteOffset: QWord; Width: Byte; out Value: QWord): Boolean;
begin
  Value := 0;
  if (Region = nil) or (Region^.Kind <> NodeRegion) or not AccessIsInRegion(Region, ByteOffset, Width) then
    Exit(False);
  if not (Region^.Space in [AmlSpaceSystemMemory, AmlSpaceSystemIo, AmlSpacePciConfiguration]) then
    { Spaces the kernel has no handler for read as zeros. }
    Exit(True);
  Result := AmlHost.ReadSpace(Region^.Space, RegionAddress(Region, ByteOffset), Width * 8, Value);
end;

function WriteRegion(Region: PAmlNode; ByteOffset: QWord; Width: Byte; Value: QWord): Boolean;
begin
  if (Region = nil) or (Region^.Kind <> NodeRegion) or not AccessIsInRegion(Region, ByteOffset, Width) then
    Exit(False);
  if not (Region^.Space in [AmlSpaceSystemMemory, AmlSpaceSystemIo, AmlSpacePciConfiguration]) then
    Exit(True);
  Result := AmlHost.WriteSpace(Region^.Space, RegionAddress(Region, ByteOffset), Width * 8, Value);
end;

{ --- Units ------------------------------------------------------------------------ }

function UnitWidth(Node: PAmlNode): Byte;
begin
  Result := Node^.AccessBytes;
  if not (Result in [1, 2, 4, 8]) then
    Result := 1;
end;

function ReadUnit(Node: PAmlNode; ByteOffset: QWord; Width: Byte; out Value: QWord): Boolean;
var
  Data: TAmlValue;
  Index: Integer;
begin
  Value := 0;
  case Node^.Kind of
    NodeField:
      Result := ReadRegion(Node^.Region, ByteOffset, Width, Value);
    NodeBankField:
      Result := WriteField(Node^.BankField, MakeInteger(Node^.BankValue)) and
        ReadRegion(Node^.Region, ByteOffset, Width, Value);
    NodeIndexField:
      begin
        Result := WriteField(Node^.IndexField, MakeInteger(ByteOffset)) and ReadField(Node^.DataField, Data);
        if Result then
        begin
          ValueToInteger(Data, True, Value);
          ReleaseValue(Data);
        end;
      end;
    NodeBufferField:
      begin
        Result := (Node^.FieldBytes <> nil) and (ByteOffset + Width <= Node^.FieldBytes^.Length);
        if Result then
          for Index := Width - 1 downto 0 do
            Value := (Value shl 8) or Node^.FieldBytes^.Data[ByteOffset + LongWord(Index)];
      end;
  else
    Result := False;
  end;
end;

function WriteUnit(Node: PAmlNode; ByteOffset: QWord; Width: Byte; Value: QWord): Boolean;
var
  Index: Integer;
begin
  case Node^.Kind of
    NodeField:
      Result := WriteRegion(Node^.Region, ByteOffset, Width, Value);
    NodeBankField:
      Result := WriteField(Node^.BankField, MakeInteger(Node^.BankValue)) and
        WriteRegion(Node^.Region, ByteOffset, Width, Value);
    NodeIndexField:
      Result := WriteField(Node^.IndexField, MakeInteger(ByteOffset)) and
        WriteField(Node^.DataField, MakeInteger(Value));
    NodeBufferField:
      begin
        Result := (Node^.FieldBytes <> nil) and (ByteOffset + Width <= Node^.FieldBytes^.Length);
        if Result then
          for Index := 0 to Width - 1 do
            Node^.FieldBytes^.Data[ByteOffset + LongWord(Index)] := Byte(Value shr (Index * 8));
      end;
  else
    Result := False;
  end;
end;

{ --- Bits ------------------------------------------------------------------------- }

function GetBit(Data: PByte; Bit: QWord): Boolean;
begin
  Result := (Data[Bit div 8] and (1 shl (Bit mod 8))) <> 0;
end;

procedure SetBit(Data: PByte; Bit: QWord; Value: Boolean);
begin
  if Value then
    Data[Bit div 8] := Data[Bit div 8] or (1 shl (Bit mod 8))
  else
    Data[Bit div 8] := Data[Bit div 8] and not (1 shl (Bit mod 8));
end;

{ A field's bits are at most MaximumFieldBytes long and their end does
  not wrap; reaching it must not exhaust the stack (an index field whose
  data field is itself). }
function FieldIsUsable(Node: PAmlNode): Boolean;
begin
  Result := (Node <> nil) and (Node^.BitLength > 0) and (Node^.BitLength <= QWord(MaximumFieldBytes) * 8) and
    (Node^.BitOffset <= High(QWord) - Node^.BitLength) and (FieldNesting < MaximumFieldNesting) and
    not AmlStackExhausted;
end;

function ReadFieldBits(Node: PAmlNode; out Value: TAmlValue): Boolean; forward;

function ReadField(Node: PAmlNode; out Value: TAmlValue): Boolean;
begin
  ZeroMemory(@Value, SizeOf(Value));
  if not FieldIsUsable(Node) then
    Exit(False);
  Inc(FieldNesting);
  Result := ReadFieldBits(Node, Value);
  Dec(FieldNesting);
end;

function ReadFieldBits(Node: PAmlNode; out Value: TAmlValue): Boolean;
var
  Width: Byte;
  UnitBits: QWord;
  Bytes: LongWord;
  Bits: TAmlValue;
  Bit: QWord;
  UnitIndex: QWord;
  CurrentUnit: QWord;
  UnitValue: QWord;
  Number: QWord;
begin
  ZeroMemory(@Value, SizeOf(Value));
  Bytes := LongWord((Node^.BitLength + 7) div 8);
  Bits := MakeBuffer(Bytes);
  if Bits.Kind <> AmlBuffer then
    Exit(False);
  Width := UnitWidth(Node);
  if Node^.Kind = NodeBufferField then
    Width := 1;
  UnitBits := QWord(Width) * 8;
  CurrentUnit := High(QWord);
  UnitValue := 0;
  for Bit := 0 to Node^.BitLength - 1 do
  begin
    UnitIndex := (Node^.BitOffset + Bit) div UnitBits;
    if UnitIndex <> CurrentUnit then
    begin
      if not ReadUnit(Node, UnitIndex * Width, Width, UnitValue) then
      begin
        ReleaseValue(Bits);
        Exit(False);
      end;
      CurrentUnit := UnitIndex;
    end;
    SetBit(Bits.Bytes^.Data, Bit, ((UnitValue shr ((Node^.BitOffset + Bit) mod UnitBits)) and 1) <> 0);
  end;
  if Node^.BitLength <= QWord(AmlIntegerBytes) * 8 then
  begin
    ValueToInteger(Bits, True, Number);
    ReleaseValue(Bits);
    Value := MakeInteger(Number);
  end
  else
    Value := Bits;
  Result := True;
end;

function WriteFieldBits(Node: PAmlNode; const Value: TAmlValue): Boolean; forward;

function WriteField(Node: PAmlNode; const Value: TAmlValue): Boolean;
begin
  if not FieldIsUsable(Node) then
    Exit(False);
  Inc(FieldNesting);
  Result := WriteFieldBits(Node, Value);
  Dec(FieldNesting);
end;

function WriteFieldBits(Node: PAmlNode; const Value: TAmlValue): Boolean;
var
  Source: TAmlValue;
  Width: Byte;
  UnitBits: QWord;
  FirstUnit: QWord;
  LastUnit: QWord;
  UnitIndex: QWord;
  UnitValue: QWord;
  Position: QWord;
  Bit: QWord;
  FieldBit: QWord;
  Covered: QWord;
  FullMask: QWord;
begin
  Source := ValueToBuffer(Value);
  if Source.Kind <> AmlBuffer then
    Exit(False);
  Width := UnitWidth(Node);
  if Node^.Kind = NodeBufferField then
    Width := 1;
  UnitBits := QWord(Width) * 8;
  if UnitBits = 64 then
    FullMask := High(QWord)
  else
    FullMask := (QWord(1) shl UnitBits) - 1;
  FirstUnit := Node^.BitOffset div UnitBits;
  LastUnit := (Node^.BitOffset + Node^.BitLength - 1) div UnitBits;
  Result := True;
  for UnitIndex := FirstUnit to LastUnit do
  begin
    { Which bits of this unit are the field's. }
    Covered := 0;
    for Position := 0 to UnitBits - 1 do
    begin
      Bit := UnitIndex * UnitBits + Position;
      if (Bit >= Node^.BitOffset) and (Bit < Node^.BitOffset + Node^.BitLength) then
        Covered := Covered or (QWord(1) shl Position);
    end;
    UnitValue := 0;
    if Covered <> FullMask then
      case Node^.UpdateRule of
        UpdateWriteAsOnes: UnitValue := FullMask;
        UpdateWriteAsZeros: UnitValue := 0;
      else
        if not ReadUnit(Node, UnitIndex * Width, Width, UnitValue) then
          UnitValue := 0;
      end;
    for Position := 0 to UnitBits - 1 do
      if (Covered and (QWord(1) shl Position)) <> 0 then
      begin
        FieldBit := UnitIndex * UnitBits + Position - Node^.BitOffset;
        { Bits past the source's end are zeros. }
        if (FieldBit < QWord(Source.Bytes^.Length) * 8) and GetBit(Source.Bytes^.Data, FieldBit) then
          UnitValue := UnitValue or (QWord(1) shl Position)
        else
          UnitValue := UnitValue and not (QWord(1) shl Position);
      end;
    if not WriteUnit(Node, UnitIndex * Width, Width, UnitValue and FullMask) then
      Result := False;
  end;
  ReleaseValue(Source);
end;

end.
