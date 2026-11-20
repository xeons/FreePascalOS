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
  The HPACK encoder (RFC 7541 sections 5 and 6) of a client:

  - a field in the static or dynamic table as it is goes as an index;
  - Authorization, Proxy-Authorization and short Cookie values (under
    20 bytes, guessable) go "never indexed" (section 7.1.3), with the
    name indexed when it can be;
  - other fields go as literals with incremental indexing, unless the
    entry would take more than half the table (it would only flush it);
  - each string is Huffman coded unless that is longer.

  The table is at most DefaultHeaderTableSize (4096) bytes, less if the
  peer's SETTINGS_HEADER_TABLE_SIZE is smaller; a change is announced
  with a dynamic table size update at the start of the next block (the
  smallest size since the last block first, when it went down and up
  again, section 4.2).

  Plain Pascal (the RTL only), checked on the host by tools/HttpTest.
}
unit Http.HpackEncoder;

{$mode objfpc}
{$H+}

interface

uses
  Http.ByteBuffers,
  Http.HpackDecoder,
  Http.HpackTables;

type
  THpackEncoder = class
  private
    FTable: THpackDynamicTable;
    FUseHuffman: Boolean;
    FPendingUpdate: Boolean;
    FSmallestPending: Integer;
    FWantedSize: Integer;
    function FindDynamic(const Name, Value: string; out NameIndex: Integer): Integer;
    procedure EncodeString(const Text: string; var Output: THttpByteBuffer);
    procedure EncodeField(const Name, Value: string; NeverIndexed: Boolean; var Output: THttpByteBuffer);
  public
    constructor Create;
    destructor Destroy; override;
    { The peer's SETTINGS_HEADER_TABLE_SIZE (the table never grows past
      DefaultHeaderTableSize). }
    procedure SetPeerTableSize(Value: Integer);
    { The table's size as both ends already know it (no update sent). }
    procedure SetAgreedTableSize(Value: Integer);
    { Appends the block for Fields to Output. }
    procedure Encode(constref Fields: THpackHeaderList; var Output: THttpByteBuffer);
    { On unless turned off (RFC 7541 appendix C.3 and C.5 are without). }
    property UseHuffman: Boolean read FUseHuffman write FUseHuffman;
    property Table: THpackDynamicTable read FTable;
  end;

procedure EncodeHpackInteger(Value: LongWord; PrefixBits: Integer; FirstByteFlags: Byte;
  var Output: THttpByteBuffer);

implementation

uses
  Http.HpackHuffman;

const
  ShortCookieLength = 20;

procedure EncodeHpackInteger(Value: LongWord; PrefixBits: Integer; FirstByteFlags: Byte;
  var Output: THttpByteBuffer);
var
  Mask: LongWord;
begin
  Mask := (LongWord(1) shl PrefixBits) - 1;
  if Value < Mask then
  begin
    AppendByte(Output, FirstByteFlags or Byte(Value));
    Exit;
  end;
  AppendByte(Output, FirstByteFlags or Byte(Mask));
  Value := Value - Mask;
  while Value >= 128 do
  begin
    AppendByte(Output, Byte((Value and $7F) or $80));
    Value := Value shr 7;
  end;
  AppendByte(Output, Byte(Value));
end;

constructor THpackEncoder.Create;
begin
  inherited Create;
  FTable := THpackDynamicTable.Create(DefaultHeaderTableSize);
  FUseHuffman := True;
  FWantedSize := DefaultHeaderTableSize;
end;

destructor THpackEncoder.Destroy;
begin
  FTable.Free;
  inherited Destroy;
end;

procedure THpackEncoder.SetPeerTableSize(Value: Integer);
var
  Size: Integer;
begin
  Size := Value;
  if Size > DefaultHeaderTableSize then
    Size := DefaultHeaderTableSize;
  if Size = FWantedSize then
    Exit;
  if not FPendingUpdate or (Size < FSmallestPending) then
    FSmallestPending := Size;
  FPendingUpdate := True;
  FWantedSize := Size;
end;

procedure THpackEncoder.SetAgreedTableSize(Value: Integer);
begin
  FWantedSize := Value;
  FPendingUpdate := False;
  FTable.SetMaximumSize(Value);
end;

function THpackEncoder.FindDynamic(const Name, Value: string; out NameIndex: Integer): Integer;
var
  Position: Integer;
  Entry: THpackEntry;
begin
  NameIndex := 0;
  for Position := 0 to FTable.Count - 1 do
  begin
    Entry := FTable.Entry(Position);
    if Entry.Name = Name then
    begin
      if NameIndex = 0 then
        NameIndex := StaticTableCount + 1 + Position;
      if Entry.Value = Value then
        Exit(StaticTableCount + 1 + Position);
    end;
  end;
  Result := 0;
end;

procedure THpackEncoder.EncodeString(const Text: string; var Output: THttpByteBuffer);
var
  HuffmanLength: Integer;
begin
  HuffmanLength := HuffmanEncodedLength(Text);
  if FUseHuffman and (HuffmanLength <= Length(Text)) and (Text <> '') then
  begin
    EncodeHpackInteger(HuffmanLength, 7, $80, Output);
    HuffmanEncode(Text, Output);
  end
  else
  begin
    EncodeHpackInteger(Length(Text), 7, 0, Output);
    AppendText(Output, Text);
  end;
end;

procedure THpackEncoder.EncodeField(const Name, Value: string; NeverIndexed: Boolean;
  var Output: THttpByteBuffer);
var
  Exact, NameIndex, DynamicNameIndex: Integer;
  Sensitive, Indexing: Boolean;
begin
  Sensitive := NeverIndexed or (Name = 'authorization') or (Name = 'proxy-authorization') or
    ((Name = 'cookie') and (Length(Value) < ShortCookieLength));
  Exact := FindStatic(Name, Value, NameIndex);
  if (Exact = 0) and not Sensitive then
    Exact := FindDynamic(Name, Value, DynamicNameIndex)
  else
    FindDynamic(Name, Value, DynamicNameIndex);
  if NameIndex = 0 then
    NameIndex := DynamicNameIndex;
  if (Exact > 0) and not Sensitive then
  begin
    EncodeHpackInteger(Exact, 7, $80, Output);
    Exit;
  end;
  Indexing := not Sensitive and (EntrySize(Name, Value) <= FTable.MaximumSize div 2);
  if Sensitive then
    EncodeHpackInteger(NameIndex, 4, $10, Output)
  else if Indexing then
    EncodeHpackInteger(NameIndex, 6, $40, Output)
  else
    EncodeHpackInteger(NameIndex, 4, $00, Output);
  if NameIndex = 0 then
    EncodeString(Name, Output);
  EncodeString(Value, Output);
  if Indexing then
    FTable.Add(Name, Value);
end;

procedure THpackEncoder.Encode(constref Fields: THpackHeaderList; var Output: THttpByteBuffer);
var
  Field: THpackHeaderField;
begin
  if FPendingUpdate then
  begin
    if FSmallestPending < FWantedSize then
    begin
      FTable.SetMaximumSize(FSmallestPending);
      EncodeHpackInteger(FSmallestPending, 5, $20, Output);
    end;
    FTable.SetMaximumSize(FWantedSize);
    EncodeHpackInteger(FWantedSize, 5, $20, Output);
    FPendingUpdate := False;
  end;
  for Field in Fields do
    EncodeField(Field.Name, Field.Value, Field.NeverIndexed, Output);
end;

end.
