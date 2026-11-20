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
  The HPACK decoder (RFC 7541 sections 5 and 6): a whole header block
  (HEADERS and its CONTINUATIONs put together) into header fields, the
  dynamic table updated as the block says.

  Checked: integers that overflow 32 bits, index 0 and indexes past the
  tables, strings running past the block, bad Huffman data, table size
  updates anywhere but at the start of a block or above the size this
  end allowed (SETTINGS_HEADER_TABLE_SIZE). Every error is a
  COMPRESSION_ERROR for the connection: the tables are out of step from
  then on. A header list larger than MaximumHeaderListSize (counted as
  section 4.1 counts entries) is decoded to the end but reported, for
  the stream to be refused.

  Plain Pascal (the RTL only), checked on the host by tools/HttpTest.
}
unit Http.HpackDecoder;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Http.HpackTables;

type
  THpackHeaderField = record
    Name: string;
    Value: string;
    { Sent as "never indexed" (to be forwarded the same way). }
    NeverIndexed: Boolean;
  end;

  THpackHeaderList = array of THpackHeaderField;

  THpackDecoder = class
  private
    FTable: THpackDynamicTable;
    FAllowedTableSize: Integer;
    FMaximumHeaderListSize: Integer;
    FErrorText: string;
    FListTooLarge: Boolean;
    function Fail(const Text: string): Boolean;
  public
    constructor Create(AllowedTableSize: Integer = DefaultHeaderTableSize);
    destructor Destroy; override;
    { Appends the block's fields to Headers. False on an error (ErrorText). }
    function Decode(Data: PByte; Count: Integer; var Headers: THpackHeaderList): Boolean;
    { What this end announced as SETTINGS_HEADER_TABLE_SIZE. }
    property AllowedTableSize: Integer read FAllowedTableSize write FAllowedTableSize;
    property MaximumHeaderListSize: Integer read FMaximumHeaderListSize write FMaximumHeaderListSize;
    property Table: THpackDynamicTable read FTable;
    property ErrorText: string read FErrorText;
    { The last block's fields went past MaximumHeaderListSize: those
      past the limit were left out (the stream is to be refused). }
    property ListTooLarge: Boolean read FListTooLarge;
  end;

{ An integer with an N-bit prefix (section 5.1) at Data[Position];
  Position moves past it. False when it runs out or overflows. }
function DecodeHpackInteger(Data: PByte; Count: Integer; var Position: Integer; PrefixBits: Integer;
  out Value: LongWord): Boolean;

implementation

uses
  Http.HpackHuffman;

const
  DefaultMaximumHeaderListSize = 256 * 1024;

function DecodeHpackInteger(Data: PByte; Count: Integer; var Position: Integer; PrefixBits: Integer;
  out Value: LongWord): Boolean;
var
  Mask: LongWord;
  Shift: Integer;
  Next: Byte;
  Total: QWord;
begin
  Value := 0;
  if Position >= Count then
    Exit(False);
  Mask := (LongWord(1) shl PrefixBits) - 1;
  Total := Data[Position] and Mask;
  Inc(Position);
  if Total < Mask then
  begin
    Value := Total;
    Exit(True);
  end;
  Shift := 0;
  repeat
    if (Position >= Count) or (Shift > 28) then
      Exit(False);
    Next := Data[Position];
    Inc(Position);
    Total := Total + (QWord(Next and $7F) shl Shift);
    Inc(Shift, 7);
  until (Next and $80) = 0;
  if Total > High(LongWord) then
    Exit(False);
  Value := LongWord(Total);
  Result := True;
end;

function DecodeString(Data: PByte; Count: Integer; var Position: Integer; out Text: string): Boolean;
var
  Huffman: Boolean;
  Length: LongWord;
begin
  Text := '';
  if Position >= Count then
    Exit(False);
  Huffman := (Data[Position] and $80) <> 0;
  if not DecodeHpackInteger(Data, Count, Position, 7, Length) then
    Exit(False);
  if Length > LongWord(Count - Position) then
    Exit(False);
  if Huffman then
    Result := HuffmanDecode(@Data[Position], Length, Text)
  else
  begin
    SetLength(Text, Length);
    if Length > 0 then
      Move(Data[Position], Text[1], Length);
    Result := True;
  end;
  Inc(Position, Length);
end;

constructor THpackDecoder.Create(AllowedTableSize: Integer);
begin
  inherited Create;
  FAllowedTableSize := AllowedTableSize;
  FMaximumHeaderListSize := DefaultMaximumHeaderListSize;
  FTable := THpackDynamicTable.Create(AllowedTableSize);
end;

destructor THpackDecoder.Destroy;
begin
  FTable.Free;
  inherited Destroy;
end;

function THpackDecoder.Fail(const Text: string): Boolean;
begin
  FErrorText := Text;
  Result := False;
end;

function THpackDecoder.Decode(Data: PByte; Count: Integer; var Headers: THpackHeaderList): Boolean;
var
  Position: Integer;
  First: Byte;
  Index: LongWord;
  PrefixBits: Integer;
  Field: THpackHeaderField;
  Entry: THpackEntry;
  ListSize: Int64;
  FieldSeen: Boolean;
  Indexing: Boolean;

  function LookUp(Which: LongWord; out Found: THpackEntry): Boolean;
  begin
    if (Which >= 1) and (Which <= StaticTableCount) then
    begin
      Found := StaticEntry(Which);
      Exit(True);
    end;
    if (Which > StaticTableCount) and (Which - StaticTableCount <= LongWord(FTable.Count)) then
    begin
      Found := FTable.Entry(Which - StaticTableCount - 1);
      Exit(True);
    end;
    Found := Default(THpackEntry);
    Result := False;
  end;

begin
  Position := 0;
  ListSize := 0;
  FListTooLarge := False;
  FieldSeen := False;
  while Position < Count do
  begin
    First := Data[Position];
    Field := Default(THpackHeaderField);
    if (First and $80) <> 0 then
    begin
      if not DecodeHpackInteger(Data, Count, Position, 7, Index) or (Index = 0) then
        Exit(Fail('bad index'));
      if not LookUp(Index, Entry) then
        Exit(Fail('index past the tables'));
      Field.Name := Entry.Name;
      Field.Value := Entry.Value;
    end
    else if (First and $E0) = $20 then
    begin
      if FieldSeen then
        Exit(Fail('table size update after a field'));
      if not DecodeHpackInteger(Data, Count, Position, 5, Index) or (Index > LongWord(FAllowedTableSize)) then
        Exit(Fail('table size update above the allowed size'));
      FTable.SetMaximumSize(Index);
      Continue;
    end
    else
    begin
      Indexing := (First and $C0) = $40;
      if Indexing then
        PrefixBits := 6
      else
        PrefixBits := 4;
      Field.NeverIndexed := (First and $F0) = $10;
      if not DecodeHpackInteger(Data, Count, Position, PrefixBits, Index) then
        Exit(Fail('bad literal'));
      if Index = 0 then
      begin
        if not DecodeString(Data, Count, Position, Field.Name) then
          Exit(Fail('bad name'));
      end
      else
      begin
        if not LookUp(Index, Entry) then
          Exit(Fail('name index past the tables'));
        Field.Name := Entry.Name;
      end;
      if not DecodeString(Data, Count, Position, Field.Value) then
        Exit(Fail('bad value'));
      if Indexing then
        FTable.Add(Field.Name, Field.Value);
    end;
    FieldSeen := True;
    ListSize := ListSize + EntrySize(Field.Name, Field.Value);
    if ListSize > FMaximumHeaderListSize then
    begin
      { The rest is still decoded, to keep the table in step. }
      FListTooLarge := True;
      Continue;
    end;
    SetLength(Headers, Length(Headers) + 1);
    Headers[High(Headers)] := Field;
  end;
  Result := True;
end;

end.
