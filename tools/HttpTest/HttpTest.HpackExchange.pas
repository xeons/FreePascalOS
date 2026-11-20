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
  HPACK against another implementation (libnghttp2, through
  check-hpack-with-nghttp2.py): "HttpTest hpack-export FILE" writes the
  header blocks libhttp's encoder makes for a sequence of header lists
  (with evictions) and every byte Huffman coded; the script decodes
  them with nghttp2's inflater and writes blocks of its own deflater;
  "HttpTest hpack-import FILE" decodes those. The file has lines

    BLOCK hex   FIELD name-hex value-hex ...   END   HUFFMAN hex
}
unit HttpTest.HpackExchange;

{$mode objfpc}
{$H+}

interface

procedure ExportHpack(const FileName: string);
procedure ImportHpack(const FileName: string);
{ The header lists both sides encode. }
function HeaderListCount: Integer;

implementation

uses
  Classes,
  SysUtils,
  TestChecks,
  Http.ByteBuffers,
  Http.HpackDecoder,
  Http.HpackEncoder,
  Http.HpackHuffman;

function HeaderListCount: Integer;
begin
  Result := 6;
end;

function TextHex(const Text: string): string;
begin
  if Text = '' then
    Exit('-');
  Result := LowerCase(BytesToHex(PByte(PChar(Text)), Length(Text)));
end;

function HexText(const Hex: string): string;
var
  Bytes: TByteArray;
begin
  if Hex = '-' then
    Exit('');
  Bytes := HexToBytes(Hex);
  SetString(Result, PChar(@Bytes[0]), Length(Bytes));
end;

procedure AddField(var List: THpackHeaderList; const Name, Value: string);
begin
  SetLength(List, Length(List) + 1);
  List[High(List)].Name := Name;
  List[High(List)].Value := Value;
end;

{ List Index of the sequence (the same lists the script makes). }
function HeaderList(Index: Integer): THpackHeaderList;
var
  Number: Integer;
begin
  Result := nil;
  AddField(Result, ':method', 'GET');
  AddField(Result, ':scheme', 'https');
  AddField(Result, ':authority', 'www.example.com');
  AddField(Result, ':path', '/page/' + IntToStr(Index) + '?q=' + StringOfChar('z', Index * 7));
  AddField(Result, 'user-agent', 'FreePascalOS-libhttp/1.0');
  AddField(Result, 'accept-encoding', 'gzip, deflate');
  AddField(Result, 'cookie', 'a=b');
  AddField(Result, 'cookie', 'session=' + StringOfChar('s', 40));
  if Index = 3 then
    for Number := 1 to 60 do
      AddField(Result, 'x-filler-' + IntToStr(Number), StringOfChar(Chr(Ord('a') + Number mod 26), 90));
  AddField(Result, 'x-binary', #1#127#200#255'end');
end;

procedure ExportHpack(const FileName: string);
var
  Lines: TStringList;
  Encoder: THpackEncoder;
  Output: THttpByteBuffer;
  Index: Integer;
  List: THpackHeaderList;
  Field: THpackHeaderField;
  AllBytes: string;
begin
  Lines := TStringList.Create;
  Encoder := THpackEncoder.Create;
  try
    for Index := 0 to HeaderListCount - 1 do
    begin
      List := HeaderList(Index);
      Output := Default(THttpByteBuffer);
      Encoder.Encode(List, Output);
      Lines.Add('BLOCK ' + LowerCase(BytesToHex(@Output.Data[0], Output.Length)));
      for Field in List do
        Lines.Add('FIELD ' + TextHex(Field.Name) + ' ' + TextHex(Field.Value));
      Lines.Add('END');
    end;
    AllBytes := '';
    for Index := 0 to 255 do
      AllBytes := AllBytes + Chr(Index);
    Output := Default(THttpByteBuffer);
    HuffmanEncode(AllBytes, Output);
    Lines.Add('HUFFMAN ' + LowerCase(BytesToHex(@Output.Data[0], Output.Length)));
    Lines.SaveToFile(FileName);
  finally
    Encoder.Free;
    Lines.Free;
  end;
end;

procedure ImportHpack(const FileName: string);
var
  Lines: TStringList;
  Decoder: THpackDecoder;
  Line: string;
  Parts: TStringArray;
  Block: TByteArray;
  Expected, Decoded: THpackHeaderList;
  Index, Blocks, Matching: Integer;
  Same: Boolean;
begin
  Lines := TStringList.Create;
  Decoder := THpackDecoder.Create;
  try
    Lines.LoadFromFile(FileName);
    Blocks := 0;
    Matching := 0;
    Expected := nil;
    Block := nil;
    for Line in Lines do
    begin
      Parts := Line.Split([' ']);
      if Length(Parts) = 0 then
        Continue;
      if Parts[0] = 'BLOCK' then
      begin
        Block := HexToBytes(Parts[1]);
        Expected := nil;
      end
      else if Parts[0] = 'FIELD' then
        AddField(Expected, HexText(Parts[1]), HexText(Parts[2]))
      else if Parts[0] = 'END' then
      begin
        Inc(Blocks);
        Decoded := nil;
        Same := Decoder.Decode(@Block[0], Length(Block), Decoded) and (Length(Decoded) = Length(Expected));
        if Same then
          for Index := 0 to High(Expected) do
            if (Decoded[Index].Name <> Expected[Index].Name) or (Decoded[Index].Value <> Expected[Index].Value) then
              Same := False;
        if Same then
          Inc(Matching);
      end;
    end;
    Check((Blocks = HeaderListCount) and (Matching = Blocks), 'HPACK: libnghttp2''s blocks decoded (' +
      IntToStr(Matching) + ' of ' + IntToStr(Blocks) + ')');
  finally
    Decoder.Free;
    Lines.Free;
  end;
end;

end.
