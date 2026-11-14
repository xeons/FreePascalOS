{
  Table driven CRC-32 checksums.

    Crc32   The common IEEE 802.3 polynomial, used by GPT, zip and PNG.
    Crc32c  The Castagnoli polynomial, used by ext4 metadata checksums.
    Crc16   The reflected 0x8005 polynomial (CRC-16/ARC), used by ext4
            group descriptors on file systems without metadata_csum.

  Both use the reflected (least significant bit first) form. To checksum
  data in pieces, pass the previous result as the starting value.
}
unit Runtime.Checksums;

{$mode objfpc}
{$pointermath on}

interface

const
  Crc32InitialValue = LongWord($FFFFFFFF);

procedure InitializeChecksums;

{ Returns the finished CRC (already inverted) of Data. }
function Crc32(Data: Pointer; ByteCount: PtrUInt): LongWord;

{ Continues a raw (uninverted) CRC-32C computation. Start with
  Crc32InitialValue and invert the final result yourself if the format
  requires it (ext4 stores the raw value). }
function Crc32cUpdate(Crc: LongWord; Data: Pointer; ByteCount: PtrUInt): LongWord;

{ Continues a CRC-16 computation (no inversion at either end). }
function Crc16Update(Crc: Word; Data: Pointer; ByteCount: PtrUInt): Word;

implementation

const
  Crc32Polynomial = LongWord($EDB88320);
  Crc32cPolynomial = LongWord($82F63B78);
  Crc16Polynomial = Word($A001);

var
  Crc32Table: array[0..255] of LongWord;
  Crc32cTable: array[0..255] of LongWord;

procedure BuildTable(var Table: array of LongWord; Polynomial: LongWord);
var
  TableIndex: Integer;
  Bit: Integer;
  Value: LongWord;
begin
  for TableIndex := 0 to 255 do
  begin
    Value := LongWord(TableIndex);
    for Bit := 1 to 8 do
    begin
      if (Value and 1) <> 0 then
        Value := (Value shr 1) xor Polynomial
      else
        Value := Value shr 1;
    end;
    Table[TableIndex] := Value;
  end;
end;

procedure InitializeChecksums;
begin
  BuildTable(Crc32Table, Crc32Polynomial);
  BuildTable(Crc32cTable, Crc32cPolynomial);
end;

function UpdateWithTable(const Table: array of LongWord; Crc: LongWord; Data: PByte;
  ByteCount: PtrUInt): LongWord;
var
  Index: PtrUInt;
begin
  Index := 0;
  while Index < ByteCount do
  begin
    Crc := Table[(Crc xor Data[Index]) and $FF] xor (Crc shr 8);
    Inc(Index);
  end;
  Result := Crc;
end;

function Crc32(Data: Pointer; ByteCount: PtrUInt): LongWord;
begin
  Result := not UpdateWithTable(Crc32Table, Crc32InitialValue, PByte(Data), ByteCount);
end;

function Crc32cUpdate(Crc: LongWord; Data: Pointer; ByteCount: PtrUInt): LongWord;
begin
  Result := UpdateWithTable(Crc32cTable, Crc, PByte(Data), ByteCount);
end;

function Crc16Update(Crc: Word; Data: Pointer; ByteCount: PtrUInt): Word;
var
  Bytes: PByte;
  Index: PtrUInt;
  Bit: Integer;
begin
  Bytes := PByte(Data);
  Index := 0;
  while Index < ByteCount do
  begin
    Crc := Crc xor Bytes[Index];
    for Bit := 1 to 8 do
    begin
      if (Crc and 1) <> 0 then
        Crc := (Crc shr 1) xor Crc16Polynomial
      else
        Crc := Crc shr 1;
    end;
    Inc(Index);
  end;
  Result := Crc;
end;

end.
