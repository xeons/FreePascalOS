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
  HPACK against RFC 7541 appendix C: the integer examples (C.1), the
  single fields (C.2), the request sequences without and with Huffman
  coding (C.3, C.4) and the response sequences with a 256-byte table
  and evictions (C.5, C.6), each decoded (fields and table size
  checked) and encoded again byte for byte; then malformed blocks.
}
unit HttpTest.Hpack;

{$mode objfpc}
{$H+}

interface

procedure TestHpack;

implementation

uses
  SysUtils,
  TestChecks,
  Http.ByteBuffers,
  Http.HpackDecoder,
  Http.HpackEncoder,
  Http.HpackHuffman,
  Http.HpackTables;

type
  TFieldTexts = array of string;

{ "name: value" pairs into a field list. }
function MakeFields(const Texts: array of string): THpackHeaderList;
var
  Index, Separator: Integer;
begin
  Result := nil;
  SetLength(Result, Length(Texts));
  for Index := 0 to High(Texts) do
  begin
    Separator := Pos(': ', Copy(Texts[Index], 2, MaxInt)) + 1;
    Result[Index].Name := Copy(Texts[Index], 1, Separator - 1);
    Result[Index].Value := Copy(Texts[Index], Separator + 2, MaxInt);
  end;
end;

function FieldsText(constref Fields: THpackHeaderList): string;
var
  Field: THpackHeaderField;
begin
  Result := '';
  for Field in Fields do
    Result := Result + Field.Name + ': ' + Field.Value + #10;
end;

function HexOf(constref Buffer: THttpByteBuffer): string;
begin
  if Buffer.Length = 0 then
    Exit('');
  Result := BytesToHex(@Buffer.Data[0], Buffer.Length);
end;

procedure CheckDecode(Decoder: THpackDecoder; const Hex: string; const Expected: array of string;
  ExpectedSize: Integer; const Name: string);
var
  Bytes: TByteArray;
  Fields: THpackHeaderList;
begin
  Bytes := HexToBytes(Hex);
  Fields := nil;
  Check(Decoder.Decode(@Bytes[0], Length(Bytes), Fields), Name + ': decodes');
  Check(FieldsText(Fields) = FieldsText(MakeFields(Expected)), Name + ': the fields');
  Check(Decoder.Table.Size = ExpectedSize, Name + ': the table size');
end;

procedure CheckEncode(Encoder: THpackEncoder; const Fields: array of string; const Hex: string; const Name: string);
var
  Output: THttpByteBuffer;
begin
  Output := Default(THttpByteBuffer);
  Encoder.Encode(MakeFields(Fields), Output);
  Check(HexOf(Output) = LowerCase(Hex), Name + ': encoded as the RFC does');
  if HexOf(Output) <> LowerCase(Hex) then
    WriteLn('     got ', HexOf(Output));
end;

procedure TestIntegers;
var
  Output: THttpByteBuffer;
  Position: Integer;
  Value: LongWord;
  Bytes: TByteArray;
begin
  Output := Default(THttpByteBuffer);
  EncodeHpackInteger(10, 5, 0, Output);
  Check(HexOf(Output) = '0a', 'C.1.1: 10 in a 5-bit prefix');
  ClearBuffer(Output);
  EncodeHpackInteger(1337, 5, 0, Output);
  Check(HexOf(Output) = '1f9a0a', 'C.1.2: 1337 in a 5-bit prefix');
  ClearBuffer(Output);
  EncodeHpackInteger(42, 8, 0, Output);
  Check(HexOf(Output) = '2a', 'C.1.3: 42 at an octet boundary');
  Bytes := HexToBytes('1f9a0a');
  Position := 0;
  Check(DecodeHpackInteger(@Bytes[0], 3, Position, 5, Value) and (Value = 1337) and (Position = 3),
    'C.1.2 decoded');
  Bytes := HexToBytes('1fffffffff0f');
  Position := 0;
  Check(not DecodeHpackInteger(@Bytes[0], Length(Bytes), Position, 5, Value), 'an integer past 32 bits refused');
  Bytes := HexToBytes('1f9a');
  Position := 0;
  Check(not DecodeHpackInteger(@Bytes[0], Length(Bytes), Position, 5, Value), 'a cut integer refused');
end;

procedure TestSingleFields;
var
  Decoder: THpackDecoder;
  Bytes: TByteArray;
  Fields: THpackHeaderList;
begin
  Decoder := THpackDecoder.Create;
  try
    CheckDecode(Decoder, '400a637573746f6d2d6b65790d637573746f6d2d686561646572', ['custom-key: custom-header'], 55,
      'C.2.1 literal with indexing');
  finally
    Decoder.Free;
  end;
  Decoder := THpackDecoder.Create;
  try
    CheckDecode(Decoder, '040c2f73616d706c652f70617468', [':path: /sample/path'], 0, 'C.2.2 literal without indexing');
    Bytes := HexToBytes('100870617373776f726406736563726574');
    Fields := nil;
    Check(Decoder.Decode(@Bytes[0], Length(Bytes), Fields) and (Length(Fields) = 1) and Fields[0].NeverIndexed and
      (Fields[0].Name = 'password') and (Fields[0].Value = 'secret') and (Decoder.Table.Size = 0),
      'C.2.3 literal never indexed');
    CheckDecode(Decoder, '82', [':method: GET'], 0, 'C.2.4 indexed');
  finally
    Decoder.Free;
  end;
end;

procedure TestRequests(UseHuffman: Boolean);
const
  First: array[0..3] of string = (':method: GET', ':scheme: http', ':path: /', ':authority: www.example.com');
  Second: array[0..4] of string = (':method: GET', ':scheme: http', ':path: /', ':authority: www.example.com',
    'cache-control: no-cache');
  Third: array[0..4] of string = (':method: GET', ':scheme: https', ':path: /index.html',
    ':authority: www.example.com', 'custom-key: custom-value');
var
  Decoder: THpackDecoder;
  Encoder: THpackEncoder;
  Section: string;
  Blocks: array[0..2] of string;
begin
  if UseHuffman then
  begin
    Section := 'C.4';
    Blocks[0] := '828684418cf1e3c2e5f23a6ba0ab90f4ff';
    Blocks[1] := '828684be5886a8eb10649cbf';
    Blocks[2] := '828785bf408825a849e95ba97d7f8925a849e95bb8e8b4bf';
  end
  else
  begin
    Section := 'C.3';
    Blocks[0] := '828684410f7777772e6578616d706c652e636f6d';
    Blocks[1] := '828684be58086e6f2d6361636865';
    Blocks[2] := '828785bf400a637573746f6d2d6b65790c637573746f6d2d76616c7565';
  end;
  Decoder := THpackDecoder.Create;
  Encoder := THpackEncoder.Create;
  try
    Encoder.UseHuffman := UseHuffman;
    CheckDecode(Decoder, Blocks[0], First, 57, Section + '.1');
    CheckDecode(Decoder, Blocks[1], Second, 110, Section + '.2');
    CheckDecode(Decoder, Blocks[2], Third, 164, Section + '.3');
    CheckEncode(Encoder, First, Blocks[0], Section + '.1');
    CheckEncode(Encoder, Second, Blocks[1], Section + '.2');
    CheckEncode(Encoder, Third, Blocks[2], Section + '.3');
  finally
    Encoder.Free;
    Decoder.Free;
  end;
end;

procedure TestResponses(UseHuffman: Boolean);
const
  First: array[0..3] of string = (':status: 302', 'cache-control: private',
    'date: Mon, 21 Oct 2013 20:13:21 GMT', 'location: https://www.example.com');
  Second: array[0..3] of string = (':status: 307', 'cache-control: private',
    'date: Mon, 21 Oct 2013 20:13:21 GMT', 'location: https://www.example.com');
  Third: array[0..5] of string = (':status: 200', 'cache-control: private',
    'date: Mon, 21 Oct 2013 20:13:22 GMT', 'location: https://www.example.com', 'content-encoding: gzip',
    'set-cookie: foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1');
var
  Decoder: THpackDecoder;
  Encoder: THpackEncoder;
  Section: string;
  Blocks: array[0..2] of string;
begin
  if UseHuffman then
  begin
    Section := 'C.6';
    Blocks[0] := '488264025885aec3771a4b6196d07abe941054d444a8200595040b8166e082a62d1bff6e919d29ad171863c78f0b97c8e9ae82ae43d3';
    Blocks[1] := '4883640effc1c0bf';
    Blocks[2] := '88c16196d07abe941054d444a8200595040b8166e084a62d1bffc05a839bd9ab77ad94e7821dd7f2e6c7b335dfdfcd5b3960d5af' +
      '27087f3672c1ab270fb5291f9587316065c003ed4ee5b1063d5007';
  end
  else
  begin
    Section := 'C.5';
    Blocks[0] := '4803333032580770726976617465611d4d6f6e2c203231204f637420323031332032303a31333a323120474d54' +
      '6e1768747470733a2f2f7777772e6578616d706c652e636f6d';
    Blocks[1] := '4803333037c1c0bf';
    Blocks[2] := '88c1611d4d6f6e2c203231204f637420323031332032303a31333a323220474d54c05a04677a69707738666f6f3d41' +
      '53444a4b48514b425a584f5157454f50495541585157454f49553b206d61782d6167653d333630303b2076657273696f6e3d31';
  end;
  Decoder := THpackDecoder.Create(256);
  Encoder := THpackEncoder.Create;
  try
    Encoder.UseHuffman := UseHuffman;
    Encoder.SetAgreedTableSize(256);
    CheckDecode(Decoder, Blocks[0], First, 222, Section + '.1');
    CheckDecode(Decoder, Blocks[1], Second, 222, Section + '.2');
    CheckDecode(Decoder, Blocks[2], Third, 215, Section + '.3');
    CheckEncode(Encoder, First, Blocks[0], Section + '.1');
    CheckEncode(Encoder, Second, Blocks[1], Section + '.2');
    CheckEncode(Encoder, Third, Blocks[2], Section + '.3');
  finally
    Encoder.Free;
    Decoder.Free;
  end;
end;

function DecodeHex(const Hex: string; AllowedSize: Integer = DefaultHeaderTableSize): Boolean;
var
  Decoder: THpackDecoder;
  Bytes: TByteArray;
  Fields: THpackHeaderList;
begin
  Decoder := THpackDecoder.Create(AllowedSize);
  try
    Bytes := HexToBytes(Hex);
    Fields := nil;
    Result := Decoder.Decode(@Bytes[0], Length(Bytes), Fields);
  finally
    Decoder.Free;
  end;
end;

procedure TestMalformed;
var
  Text: string;
  Bytes: TByteArray;
  Output: THttpByteBuffer;
  Decoder: THpackDecoder;
  Encoder: THpackEncoder;
  Fields: THpackHeaderList;
  Index: Integer;
  AllBytes: string;
begin
  Check(not DecodeHex('80'), 'index 0 refused');
  Check(not DecodeHex('be'), 'an index past the tables refused');
  Check(not DecodeHex('400a6375'), 'a string past the block refused');
  Check(not DecodeHex('823f'), 'a table size update after a field refused');
  Check(DecodeHex('3fe10182', 4096) and not DecodeHex('3fe21f82', 4096), 'a table size update above the allowed size refused');
  Check(not DecodeHex('418cf1e3c2e5f23a6ba0ab90f4'), 'a Huffman string longer than the block refused');
  Check(not DecodeHex('4182ffff'), 'Huffman padding longer than seven bits refused');
  Bytes := HexToBytes('1e');
  Check(not HuffmanDecode(@Bytes[0], 1, Text), 'Huffman padding that is not all ones refused');
  Bytes := HexToBytes('ffffffff');
  Check(not HuffmanDecode(@Bytes[0], 4, Text), 'EOS in Huffman data refused');
  { Every byte through the Huffman coder and back. }
  AllBytes := '';
  for Index := 0 to 255 do
    AllBytes := AllBytes + Chr(Index);
  Output := Default(THttpByteBuffer);
  HuffmanEncode(AllBytes, Output);
  Check(HuffmanDecode(@Output.Data[0], Output.Length, Text) and (Text = AllBytes), 'Huffman: every byte round trips');
  { A small table: the encoder sends size updates, the decoder obeys. }
  Encoder := THpackEncoder.Create;
  Decoder := THpackDecoder.Create;
  try
    Encoder.SetPeerTableSize(0);
    Encoder.SetPeerTableSize(100);
    ClearBuffer(Output);
    Encoder.Encode(MakeFields(['x-a: 1', 'authorization: secret', 'cookie: a=b']), Output);
    Check(Copy(HexOf(Output), 1, 6) = '203f45', 'size updates: the smallest first, then the new size');
    Fields := nil;
    Check(Decoder.Decode(@Output.Data[0], Output.Length, Fields) and (Length(Fields) = 3) and
      Fields[1].NeverIndexed and Fields[2].NeverIndexed and (Decoder.Table.MaximumSize = 100) and
      (Decoder.Table.Count = 1), 'size updates and never indexed fields decoded');
  finally
    Decoder.Free;
    Encoder.Free;
  end;
  Decoder := THpackDecoder.Create;
  try
    Decoder.MaximumHeaderListSize := 40;
    Bytes := HexToBytes('400a637573746f6d2d6b65790d637573746f6d2d68656164657282');
    Fields := nil;
    Check(Decoder.Decode(@Bytes[0], Length(Bytes), Fields) and Decoder.ListTooLarge and
      (Decoder.Table.Size = 55), 'a list too large is reported, the table kept in step');
  finally
    Decoder.Free;
  end;
end;

{ Thousands of blocks through one encoder and decoder: the memory in
  use stays where it was after the first ones (the dynamic tables are
  bounded, the buffers reused). }
procedure TestMemoryBound;
var
  Encoder: THpackEncoder;
  Decoder: THpackDecoder;
  Output: THttpByteBuffer;
  Fields, Decoded: THpackHeaderList;
  Round: Integer;
  Before, After: PtrUInt;
begin
  Encoder := THpackEncoder.Create;
  Decoder := THpackDecoder.Create;
  Output := Default(THttpByteBuffer);
  try
    Before := 0;
    for Round := 1 to 5000 do
    begin
      Fields := MakeFields([':method: GET', ':path: /item/' + IntToStr(Round), 'x-round: ' + IntToStr(Round * 7919),
        'user-agent: FreePascalOS-libhttp/1.0']);
      ClearBuffer(Output);
      Encoder.Encode(Fields, Output);
      Decoded := nil;
      Decoder.Decode(@Output.Data[0], Output.Length, Decoded);
      if Round = 100 then
        Before := GetFPCHeapStatus.CurrHeapUsed;
    end;
    After := GetFPCHeapStatus.CurrHeapUsed;
    Check((Encoder.Table.Size <= DefaultHeaderTableSize) and (Decoder.Table.Size <= DefaultHeaderTableSize),
      'HPACK: the dynamic tables stay within 4096 bytes');
    Check(After <= Before + 16384, 'HPACK: 5000 blocks in constant memory (' + IntToStr(Int64(After) - Int64(Before)) +
      ' bytes more after the first 100)');
  finally
    Decoder.Free;
    Encoder.Free;
  end;
end;

procedure TestHpack;
begin
  TestMemoryBound;
  TestIntegers;
  TestSingleFields;
  TestRequests(False);
  TestRequests(True);
  TestResponses(False);
  TestResponses(True);
  TestMalformed;
end;

end.
