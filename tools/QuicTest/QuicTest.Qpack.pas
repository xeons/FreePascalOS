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
  QPACK: HPACK's Huffman code against RFC 7541 appendix C's strings,
  the decoder through RFC 9204 appendix B's examples (B.1 to B.5: the
  static table, dynamic inserts, a blocked section, duplication,
  eviction, the decoder stream's acknowledgments), malformed input, and
  the encoder's sections decoded again.
}
unit QuicTest.Qpack;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

procedure RunQpackTests;

implementation

uses
  SysUtils,
  TestChecks,
  Qpack.Decoder,
  Qpack.Encoder,
  Qpack.StaticTable,
  Http.ByteBuffers,
  Http.HpackHuffman;

procedure CheckHuffman(const Text, Hex: string);
var
  Encoded: THttpByteBuffer;
  Decoded: string;
  Expected: TByteArray;
begin
  Encoded := Default(THttpByteBuffer);
  HuffmanEncode(Text, Encoded);
  Check(Encoded.Length = HuffmanEncodedLength(Text), 'Huffman length of "' + Text + '"');
  CheckBytes(@Encoded.Data[0], Encoded.Length, Hex, 'Huffman encodes "' + Text + '"');
  Expected := HexToBytes(Hex);
  Check(HuffmanDecode(@Expected[0], Length(Expected), Decoded) and (Decoded = Text),
    'Huffman decodes "' + Text + '"');
end;

procedure TestHuffman;
var
  Bytes: TByteArray;
  Text, All: string;
  Encoded: THttpByteBuffer;
  Index: Integer;
begin
  CheckHuffman('www.example.com', 'f1e3c2e5f23a6ba0ab90f4ff');
  CheckHuffman('no-cache', 'a8eb10649cbf');
  CheckHuffman('custom-key', '25a849e95ba97d7f');
  CheckHuffman('custom-value', '25a849e95bb8e8b4bf');
  CheckHuffman('302', '6402');
  CheckHuffman('private', 'aec3771a4b');
  CheckHuffman('Mon, 21 Oct 2013 20:13:21 GMT', 'd07abe941054d444a8200595040b8166e082a62d1bff');
  CheckHuffman('https://www.example.com', '9d29ad171863c78f0b97c8e9ae82ae43d3');
  { Every byte value, through and back. }
  All := '';
  for Index := 0 to 255 do
    All := All + Chr(Index);
  Encoded := Default(THttpByteBuffer);
  HuffmanEncode(All, Encoded);
  Check(HuffmanDecode(@Encoded.Data[0], Encoded.Length, Text) and (Text = All), 'Huffman: all 256 byte values');
  { Padding longer than seven bits, padding of zeros, EOS inside. }
  Bytes := HexToBytes('f1e3c2e5f23a6ba0ab90f4ffff');
  Check(not HuffmanDecode(@Bytes[0], Length(Bytes), Text), 'Huffman: eight bits of padding refused');
  Bytes := HexToBytes('18');
  Check(not HuffmanDecode(@Bytes[0], Length(Bytes), Text), 'Huffman: zero padding refused');
  Bytes := HexToBytes('fffffffc');
  Check(not HuffmanDecode(@Bytes[0], Length(Bytes), Text), 'Huffman: EOS refused');
end;

function FieldsText(constref Fields: TQpackFieldList): string;
var
  Index: Integer;
begin
  Result := '';
  for Index := 0 to High(Fields) do
  begin
    if Index > 0 then
      Result := Result + ' ';
    Result := Result + Fields[Index].Name + '=' + Fields[Index].Value;
  end;
end;

function DecodeHex(Decoder: TQpackDecoder; StreamId: QWord; const Hex: string; out Fields: TQpackFieldList):
  TQpackDecodeResult;
var
  Bytes: TByteArray;
  Error: QWord;
begin
  Bytes := HexToBytes(Hex);
  Result := Decoder.DecodeFieldSection(StreamId, @Bytes[0], Length(Bytes), Fields, Error);
end;

procedure FeedEncoderStream(Decoder: TQpackDecoder; const Hex: string; const Name: string);
var
  Bytes: TByteArray;
  Index: Integer;
  Error: QWord;
begin
  Bytes := HexToBytes(Hex);
  { One byte at a time: instructions straddle the pieces. }
  Error := 0;
  for Index := 0 to High(Bytes) do
    if Error = 0 then
      Error := Decoder.ProcessEncoderStream(@Bytes[Index], 1);
  Check(Error = 0, Name + ': encoder stream accepted');
end;

function DecoderStreamHex(Decoder: TQpackDecoder): string;
var
  Bytes: TBytes;
begin
  Bytes := Decoder.TakeDecoderStreamBytes;
  if Length(Bytes) = 0 then
    Exit('');
  Result := BytesToHex(@Bytes[0], Length(Bytes));
end;

procedure TestAppendixB;
var
  Decoder: TQpackDecoder;
  Fields: TQpackFieldList;
  Field: TQpackField;
begin
  Decoder := TQpackDecoder.Create(220, 10);
  try
    { B.1: a literal with a static name reference. }
    Check((DecodeHex(Decoder, 0, '0000510b2f696e6465782e68746d6c', Fields) = DecodeDone) and
      (FieldsText(Fields) = ':path=/index.html'), 'B.1 literal field line with name reference');
    Check(DecoderStreamHex(Decoder) = '', 'B.1 nothing on the decoder stream');

    { B.2: the section arrives before the inserts: blocked, then decoded. }
    Check(DecodeHex(Decoder, 4, '03811011', Fields) = DecodeBlocked, 'B.2 blocked before the inserts');
    FeedEncoderStream(Decoder, '3fbd01c00f7777772e6578616d706c652e636f6dc10c2f73616d706c652f70617468', 'B.2');
    Check((Decoder.Table.Capacity = 220) and (Decoder.InsertCount = 2) and (Decoder.Table.Size = 106),
      'B.2 dynamic table: capacity 220, 2 entries, size 106');
    Check((DecodeHex(Decoder, 4, '03811011', Fields) = DecodeDone) and
      (FieldsText(Fields) = ':authority=www.example.com :path=/sample/path'), 'B.2 post-base indexed field lines');
    Check(DecoderStreamHex(Decoder) = '84', 'B.2 Section Acknowledgment (stream 4)');

    { B.3: a speculative insert. }
    FeedEncoderStream(Decoder, '4a637573746f6d2d6b65790c637573746f6d2d76616c7565', 'B.3');
    Check((Decoder.InsertCount = 3) and (Decoder.Table.Size = 160), 'B.3 size 160');
    Check(DecoderStreamHex(Decoder) = '01', 'B.3 Insert Count Increment (1)');

    { B.4: duplicate, relative indexes from a base. }
    FeedEncoderStream(Decoder, '02', 'B.4');
    Check((Decoder.InsertCount = 4) and (Decoder.Table.Size = 217), 'B.4 duplicate: size 217');
    Check(Decoder.Table.Get(3, Field) and (Field.Name = ':authority') and (Field.Value = 'www.example.com'),
      'B.4 the duplicate is entry 3');
    Check((DecodeHex(Decoder, 8, '050080c181', Fields) = DecodeDone) and
      (FieldsText(Fields) = ':authority=www.example.com :path=/ custom-key=custom-value'),
      'B.4 indexed dynamic and static field lines');
    Decoder.TakeDecoderStreamBytes;
    Decoder.CancelStream(8);
    Check(DecoderStreamHex(Decoder) = '48', 'B.4 Stream Cancellation (stream 8)');

    { B.5: an insert that evicts the oldest entry. }
    FeedEncoderStream(Decoder, '810d637573746f6d2d76616c756532', 'B.5');
    Check((Decoder.InsertCount = 5) and (Decoder.Table.Size = 215), 'B.5 eviction: size 215');
    Check(not Decoder.Table.Get(0, Field), 'B.5 entry 0 evicted');
    Check(Decoder.Table.Get(4, Field) and (Field.Name = 'custom-key') and (Field.Value = 'custom-value2'),
      'B.5 entry 4 named after entry 2');
    Check(DecoderStreamHex(Decoder) = '01', 'B.5 Insert Count Increment (1)');

    { Malformed input. }
    Check(DecodeHex(Decoder, 12, '0000ff', Fields) = DecodeFailed, 'a static index beyond the table');
    Check(DecodeHex(Decoder, 12, '00008a', Fields) = DecodeFailed, 'a dynamic reference with RIC 0');
    Check(DecodeHex(Decoder, 12, '1f00', Fields) = DecodeFailed, 'a Required Insert Count beyond the range');
    Check(Decoder.ProcessEncoderStream(PByte(PChar(#$3f#$e1#$1f)), 3) = QpackEncoderStreamError,
      'a capacity above the maximum');
  finally
    Decoder.Free;
  end;
end;

procedure TestEncoder;
var
  Fields, Decoded: TQpackFieldList;
  Encoded: TBytes;
  Decoder: TQpackDecoder;
  Error: QWord;
begin
  Fields := nil;
  AddField(Fields, ':method', 'GET');
  AddField(Fields, ':scheme', 'https');
  AddField(Fields, ':authority', 'example.org');
  AddField(Fields, ':path', '/a/b?c=d');
  AddField(Fields, 'User-Agent', 'h3get/1.0');
  AddField(Fields, 'x-custom', 'some value with spaces');
  AddField(Fields, 'accept', '*/*');
  Encoded := EncodeFieldSection(Fields);
  Check((Encoded[0] = 0) and (Encoded[1] = 0) and (Encoded[2] = $C0 or 17), 'encoder: :method GET is static 17');
  Decoder := TQpackDecoder.Create(0, 0);
  try
    Check(Decoder.DecodeFieldSection(0, @Encoded[0], Length(Encoded), Decoded, Error) = DecodeDone,
      'encoder output decodes');
    Check(FieldsText(Decoded) = ':method=GET :scheme=https :authority=example.org :path=/a/b?c=d ' +
      'user-agent=h3get/1.0 x-custom=some value with spaces accept=*/*', 'encoder round trip (names in lower case)');
  finally
    Decoder.Free;
  end;
end;

procedure RunQpackTests;
begin
  TestHuffman;
  TestAppendixB;
  TestEncoder;
end;

end.
