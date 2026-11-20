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
  The Encoding Standard parts of libweb: labels, the decoders (whole and
  in pieces, with the standard's error handling), the BOM sniff, the meta
  prescan, the HTML encoding sniffing algorithm, the parser's encoding
  changes, the UTF-8 encoder and the UTF-16 offset helpers.
}
unit WebTest.Encoding;

{$mode objfpc}
{$H+}

interface

procedure RunEncodingTests;

implementation

uses
  SysUtils,
  TestChecks,
  Web.TextBuffers,
  Web.Encoding.Labels,
  Web.Encoding.Decoders,
  Web.Encoding.DecoderFactory,
  Web.Encoding.Sniffing,
  Web.Encoding.Utf8,
  Web.Atoms,
  Web.Dom,
  Web.Html.Parser;

function Hex(const Bytes: string): string;
var
  Index: Integer;
begin
  Result := '';
  for Index := 1 to Length(Bytes) do
    Result := Result + IntToHex(Ord(Bytes[Index]), 2);
end;

procedure CheckLabel(const LabelText: string; Expected: TTextEncoding);
var
  Encoding: TTextEncoding;
begin
  Check(EncodingForLabel(LabelText, Encoding) and (Encoding = Expected),
    'label "' + LabelText + '" is ' + EncodingName(Expected));
end;

procedure CheckDecode(Encoding: TTextEncoding; const Bytes, Expected, Name: string);
var
  Actual: string;
begin
  Actual := DecodeBytes(Bytes, Encoding);
  Check(Actual = Expected, Name + ' (' + Hex(Actual) + ')');
end;

{ Decoding one byte at a time gives what decoding all at once does. }
procedure CheckDecodeInPieces(Encoding: TTextEncoding; const Bytes, Name: string);
var
  Decoder: TTextDecoder;
  Output: TTextBuffer;
  Index: Integer;
  Whole: string;
begin
  Whole := DecodeBytes(Bytes, Encoding);
  Decoder := CreateDecoder(Encoding);
  Output := TTextBuffer.Create;
  try
    for Index := 1 to Length(Bytes) do
      Decoder.Decode(PByte(@Bytes[Index]), 1, Output, False);
    Decoder.Decode(nil, 0, Output, True);
    Check(Output.Text = Whole, Name + ' in one byte pieces');
  finally
    Output.Free;
    Decoder.Free;
  end;
end;

procedure TestLabels;
var
  Encoding: TTextEncoding;
begin
  CheckLabel('utf-8', TextEncodingUtf8);
  CheckLabel(' UTF8 ', TextEncodingUtf8);
  CheckLabel('unicode-1-1-utf-8', TextEncodingUtf8);
  CheckLabel('latin1', TextEncodingWindows1252);
  CheckLabel('ISO-8859-1', TextEncodingWindows1252);
  CheckLabel('us-ascii', TextEncodingWindows1252);
  CheckLabel('iso-8859-9', TextEncodingWindows1254);
  CheckLabel('unicode', TextEncodingUtf16Le);
  CheckLabel('utf-16', TextEncodingUtf16Le);
  CheckLabel('UTF-16BE', TextEncodingUtf16Be);
  CheckLabel('x-sjis', TextEncodingShiftJis);
  CheckLabel('gb2312', TextEncodingGbk);
  CheckLabel('iso-2022-kr', TextEncodingReplacement);
  CheckLabel('koi8-ru', TextEncodingKoi8U);
  CheckLabel('x-mac-ukrainian', TextEncodingXMacCyrillic);
  CheckLabel('logical', TextEncodingIso8859_8I);
  CheckLabel('tis-620', TextEncodingWindows874);
  Check(EncodingForLabel(#9'x-user-defined'#10, Encoding) and (Encoding = TextEncodingXUserDefined),
    'labels are trimmed of tabs and line feeds');
  Check(not EncodingForLabel('bogus', Encoding), 'label "bogus" is no encoding');
  Check(not EncodingForLabel('utf-7', Encoding), 'label "utf-7" is no encoding');
  Check(not EncodingForLabel('', Encoding), 'the empty label is no encoding');
  Check(EncodingName(TextEncodingShiftJis) = 'Shift_JIS', 'the name of Shift_JIS');
  Check(OutputEncoding(TextEncodingUtf16Le) = TextEncodingUtf8, 'UTF-16LE outputs as UTF-8');
  Check(OutputEncoding(TextEncodingReplacement) = TextEncodingUtf8, 'replacement outputs as UTF-8');
  Check(OutputEncoding(TextEncodingKoi8R) = TextEncodingKoi8R, 'KOI8-R outputs as itself');
end;

const
  Replacement = #$EF#$BF#$BD;

procedure TestUtf8Decoder;
begin
  CheckDecode(TextEncodingUtf8, 'abc', 'abc', 'UTF-8 ASCII');
  CheckDecode(TextEncodingUtf8, #$C3#$A9#$E2#$82#$AC#$F0#$9F#$98#$80, #$C3#$A9#$E2#$82#$AC#$F0#$9F#$98#$80,
    'UTF-8 two, three and four byte sequences');
  CheckDecode(TextEncodingUtf8, #$80, Replacement, 'UTF-8 lone continuation byte');
  CheckDecode(TextEncodingUtf8, 'a'#$C3, 'a' + Replacement, 'UTF-8 truncated at the end');
  CheckDecode(TextEncodingUtf8, #$F0#$9F#$98'A', Replacement + 'A', 'UTF-8 truncated, then ASCII');
  CheckDecode(TextEncodingUtf8, #$C0#$AF, Replacement + Replacement, 'UTF-8 overlong two bytes');
  CheckDecode(TextEncodingUtf8, #$E0#$80#$AF, Replacement + Replacement + Replacement, 'UTF-8 overlong three bytes');
  CheckDecode(TextEncodingUtf8, #$ED#$A0#$80, Replacement + Replacement + Replacement, 'UTF-8 surrogate');
  CheckDecode(TextEncodingUtf8, #$F4#$90#$80#$80, Replacement + Replacement + Replacement + Replacement,
    'UTF-8 beyond U+10FFFF');
  CheckDecode(TextEncodingUtf8, #$F8#$88#$80#$80#$80, Replacement + Replacement + Replacement + Replacement +
    Replacement, 'UTF-8 five byte form');
  CheckDecode(TextEncodingUtf8, #$E2#$82'x', Replacement + 'x', 'UTF-8 broken sequence, maximal subpart');
  CheckDecodeInPieces(TextEncodingUtf8, 'a'#$C3#$A9#$E2#$82#$AC#$80#$F0#$9F#$98#$80'z'#$E2#$82, 'UTF-8');
end;

procedure TestUtf16Decoders;
begin
  CheckDecode(TextEncodingUtf16Le, 'A'#0#$E9#0, 'A'#$C3#$A9, 'UTF-16LE BMP');
  CheckDecode(TextEncodingUtf16Le, #$3D#$D8#$00#$DE, #$F0#$9F#$98#$80, 'UTF-16LE surrogate pair');
  CheckDecode(TextEncodingUtf16Le, #$00#$D8'A'#0, Replacement + 'A', 'UTF-16LE lone lead surrogate');
  CheckDecode(TextEncodingUtf16Le, #$00#$DC'A'#0, Replacement + 'A', 'UTF-16LE lone trail surrogate');
  CheckDecode(TextEncodingUtf16Le, 'A'#0'B', 'A' + Replacement, 'UTF-16LE odd byte at the end');
  CheckDecode(TextEncodingUtf16Le, #$00#$D8, Replacement, 'UTF-16LE lead surrogate at the end');
  CheckDecode(TextEncodingUtf16Be, #0'A'#$D8#$3D#$DE#$00, 'A'#$F0#$9F#$98#$80, 'UTF-16BE');
  CheckDecode(TextEncodingUtf16Be, #$D8#$00#$D8#$00#$DC#$00, Replacement + #$F0#$90#$80#$80,
    'UTF-16BE two leads, then a pair');
  CheckDecodeInPieces(TextEncodingUtf16Le, 'A'#0#$3D#$D8#$00#$DE#$00#$D8'x'#0'q', 'UTF-16LE');
end;

procedure TestSingleByteDecoders;
begin
  CheckDecode(TextEncodingWindows1252, #$80#$81#$9F#$E9, #$E2#$82#$AC#$C2#$81#$C5#$B8#$C3#$A9,
    'windows-1252: euro, U+0081, Y diaeresis, e acute');
  CheckDecode(TextEncodingIso8859_2, #$A1, #$C4#$84, 'ISO-8859-2: A ogonek');
  CheckDecode(TextEncodingIso8859_3, #$A5, Replacement, 'ISO-8859-3: a byte it does not define');
  CheckDecode(TextEncodingKoi8U, #$AE#$BE, #$D1#$9E#$D0#$8E, 'KOI8-U: short u (the KOI8-RU bytes)');
  CheckDecode(TextEncodingKoi8R, #$C1, #$D0#$B0, 'KOI8-R: a');
  CheckDecode(TextEncodingIbm866, #$80, #$D0#$90, 'IBM866: A');
  CheckDecode(TextEncodingWindows1251, #$C0, #$D0#$90, 'windows-1251: A');
  CheckDecode(TextEncodingWindows1255, #$CA, #$D6#$BA, 'windows-1255: holam haser for vav');
  CheckDecode(TextEncodingWindows874, #$DB, Replacement, 'windows-874: a byte it does not define');
  CheckDecode(TextEncodingMacintosh, #$DB, #$E2#$82#$AC, 'macintosh: euro');
  CheckDecode(TextEncodingXMacCyrillic, #$A2, #$D2#$90, 'x-mac-cyrillic: ghe with upturn');
  CheckDecode(TextEncodingIso8859_8I, #$E0, #$D7#$90, 'ISO-8859-8-I uses the ISO-8859-8 index');
  CheckDecode(TextEncodingXUserDefined, 'a'#$80#$FF, 'a'#$EF#$9E#$80#$EF#$9F#$BF, 'x-user-defined');
  CheckDecode(TextEncodingReplacement, 'abc', Replacement, 'replacement: one U+FFFD');
  CheckDecode(TextEncodingReplacement, '', '', 'replacement: nothing for nothing');
  Check(CreateDecoder(TextEncodingShiftJis) = nil, 'no Shift_JIS decoder yet');
  Check(not IsDecodableEncoding(TextEncodingGb18030), 'gb18030 is not decodable yet');
  Check(IsDecodableEncoding(TextEncodingWindows1250), 'windows-1250 is decodable');
end;

procedure TestSniffing;
var
  Encoding: TTextEncoding;
  MarkLength: Integer;
  Confidence: TEncodingConfidence;
  Text, Long: string;

  function Prescan(const Bytes: string; out Found: TTextEncoding): Boolean;
  begin
    Result := PrescanForEncoding(PByte(PChar(Bytes)), Length(Bytes), Found);
  end;

  function Sniff(const Bytes, Transport: string; out SniffConfidence: TEncodingConfidence): TTextEncoding;
  var
    BomLength: Integer;
  begin
    Result := SniffHtmlEncoding(PByte(PChar(Bytes)), Length(Bytes), Transport, SniffConfidence, BomLength);
  end;

begin
  Text := #$EF#$BB#$BF'x';
  Check(SniffByteOrderMark(PByte(PChar(Text)), Length(Text), Encoding, MarkLength) and
    (Encoding = TextEncodingUtf8) and (MarkLength = 3), 'BOM: UTF-8');
  Text := #$FE#$FF;
  Check(SniffByteOrderMark(PByte(PChar(Text)), Length(Text), Encoding, MarkLength) and
    (Encoding = TextEncodingUtf16Be) and (MarkLength = 2), 'BOM: UTF-16BE');
  Text := #$FF#$FE'a'#0;
  Check(SniffByteOrderMark(PByte(PChar(Text)), Length(Text), Encoding, MarkLength) and
    (Encoding = TextEncodingUtf16Le), 'BOM: UTF-16LE');
  Text := 'abc';
  Check(not SniffByteOrderMark(PByte(PChar(Text)), Length(Text), Encoding, MarkLength), 'no BOM');

  Check(Prescan('<meta charset="koi8-r">', Encoding) and (Encoding = TextEncodingKoi8R), 'prescan: meta charset');
  Check(Prescan('<META CHARSET=KOI8-R>', Encoding) and (Encoding = TextEncodingKoi8R), 'prescan: upper case');
  Check(Prescan('<meta http-equiv="Content-Type" content="text/html; charset=iso-8859-2">', Encoding) and
    (Encoding = TextEncodingIso8859_2), 'prescan: Content-Type pragma');
  Check(Prescan('<meta content="text/html; charset=utf-16" http-equiv=content-type>', Encoding) and
    (Encoding = TextEncodingUtf8), 'prescan: UTF-16 means UTF-8');
  Check(Prescan('<meta charset=x-user-defined>', Encoding) and (Encoding = TextEncodingWindows1252),
    'prescan: x-user-defined means windows-1252');
  Check(Prescan('<!-- <meta charset=koi8-r> --><meta charset=windows-1251>', Encoding) and
    (Encoding = TextEncodingWindows1251), 'prescan: skips comments');
  Check(Prescan('<!--><meta charset=windows-1251>', Encoding) and (Encoding = TextEncodingWindows1251),
    'prescan: <!--> is a whole comment');
  Check(not Prescan('<meta content="text/html; charset=koi8-r">', Encoding), 'prescan: content without the pragma');
  Check(not Prescan('<meta charset=bogus>', Encoding), 'prescan: unknown charset');
  Check(Prescan('<title a="<meta charset=koi8-r>"><meta charset=iso-8859-5>', Encoding) and
    (Encoding = TextEncodingIso8859_5), 'prescan: skips the attributes of other tags');
  Check(Prescan('<meta name=x charset=gbk charset=koi8-r>', Encoding) and (Encoding = TextEncodingGbk),
    'prescan: the first of duplicate attributes');
  Check(Prescan('<meta/charset=koi8-r>', Encoding) and (Encoding = TextEncodingKoi8R), 'prescan: <meta/');
  Long := '<!-- ' + StringOfChar('x', 1100) + ' --><meta charset=koi8-r>';
  Check(not Prescan(Long, Encoding), 'prescan: only the first 1024 bytes');

  Check(ExtractEncodingFromContent('text/html;charset="utf-8"', Encoding) and (Encoding = TextEncodingUtf8),
    'content: quoted charset');
  Check(ExtractEncodingFromContent('text/html; CHARSET = ''koi8-r''', Encoding) and
    (Encoding = TextEncodingKoi8R), 'content: spaces and single quotes');
  Check(ExtractEncodingFromContent('charset=windows-1251;x', Encoding) and (Encoding = TextEncodingWindows1251),
    'content: up to the semicolon');
  Check(not ExtractEncodingFromContent('text/html; charset=', Encoding), 'content: empty charset');
  Check(not ExtractEncodingFromContent('charset="koi8-r', Encoding), 'content: unmatched quote');
  Check(ExtractEncodingFromContent('charsetx; charset=koi8-r', Encoding) and (Encoding = TextEncodingKoi8R),
    'content: looks for the next charset');

  Check((Sniff('<meta charset=koi8-r>', 'iso-8859-2', Confidence) = TextEncodingIso8859_2) and
    (Confidence = ConfidenceCertain), 'sniffing: the transport charset wins over meta');
  Check((Sniff(#$EF#$BB#$BF'<meta charset=koi8-r>', 'iso-8859-2', Confidence) = TextEncodingUtf8) and
    (Confidence = ConfidenceCertain), 'sniffing: the BOM wins over everything');
  Check((Sniff('<meta charset=koi8-r>', '', Confidence) = TextEncodingKoi8R) and
    (Confidence = ConfidenceTentative), 'sniffing: meta is tentative');
  Check((Sniff('<p>plain', '', Confidence) = TextEncodingWindows1252) and (Confidence = ConfidenceTentative),
    'sniffing: windows-1252 by default');
  Check(Sniff('x', 'bogus', Confidence) = TextEncodingWindows1252, 'sniffing: an unknown transport label is ignored');
end;

procedure TestParserEncodings;
var
  Document: TDocument;
  Parser: THtmlParser;
  Bytes: string;
begin
  { The prescan finds koi8-r: the Cyrillic bytes decode as such. }
  Document := ParseHtmlDocument('<meta charset=koi8-r><p>'#$C1#$C2);
  try
    Check(Document.Body.TextContent = #$D0#$B0#$D0#$B1, 'parser: decodes with the prescanned encoding');
    Check(Document.CharacterSet = 'KOI8-R', 'parser: characterSet');
  finally
    Document.Release;
  end;
  { A meta past the first 1024 bytes after non-ASCII text: a restart. }
  Bytes := '<p>'#$E9 + StringOfChar(' ', 1100) + '<meta charset=koi8-r><p>'#$C1;
  Document := ParseHtmlDocument(Bytes);
  try
    Check(Pos(#$D0#$B0, Document.Body.TextContent) > 0, 'parser: a late meta restarts with its encoding');
    Check(Document.CharacterSet = 'KOI8-R', 'parser: characterSet after the restart');
  finally
    Document.Release;
  end;
  { A late meta after ASCII only: the decoder just changes. }
  Bytes := '<p>' + StringOfChar(' ', 1100) + '<meta charset=windows-1251><p>'#$C0;
  Document := ParseHtmlDocument(Bytes);
  try
    Check(Pos(#$D0#$90, Document.Body.TextContent) > 0, 'parser: a late meta after ASCII changes the decoder');
  finally
    Document.Release;
  end;
  { UTF-16 with a BOM. }
  Document := ParseHtmlDocument(#$FF#$FE'<'#0'p'#0'>'#0#$AC#$20);
  try
    Check(Document.Body.TextContent = #$E2#$82#$AC, 'parser: UTF-16LE with a BOM');
  finally
    Document.Release;
  end;
  { The transport charset is certain: a meta does not change it. }
  Document := ParseHtmlDocument('<meta charset=koi8-r><p>'#$E9, 'windows-1252');
  try
    Check(Document.Body.TextContent = #$C3#$A9, 'parser: the transport charset is kept');
  finally
    Document.Release;
  end;
  { Text split inside a multi-byte sequence and around CR LF. }
  Document := TDocument.CreateDocument(True);
  try
    Parser := THtmlParser.Create(Document);
    try
      Parser.SetEncoding(TextEncodingUtf8, ConfidenceCertain);
      Parser.WriteByteString('<p>a'#$E2#$82);
      Parser.WriteByteString(#$AC'b'#13);
      Parser.WriteByteString(#10'c'#13);
      Parser.WriteByteString('d');
      Parser.Finish;
    finally
      Parser.Free;
    end;
    Check(Document.Body.TextContent = 'a'#$E2#$82#$AC'b'#10'c'#10'd', 'parser: pieces split in sequences and CR LF');
  finally
    Document.Release;
  end;
end;

procedure TestUtf8Helpers;
var
  Text: string;
begin
  Check(EncodeUtf8(UnicodeString(#$D83D#$DE00)) = #$F0#$9F#$98#$80, 'UTF-8 encode: a surrogate pair');
  Check(EncodeUtf8(UnicodeString(#$D83D'x')) = Replacement + 'x', 'UTF-8 encode: a lone surrogate is U+FFFD');
  Check(Utf16ToUtf8(UnicodeString(#$D83D)) = #$ED#$A0#$BD, 'generalized UTF-8 keeps a lone surrogate');
  Check(Utf8ToUtf16(#$ED#$A0#$BD) = UnicodeString(#$D83D), 'and gives it back');
  Text := 'a'#$C3#$A9#$F0#$9F#$98#$80'b';
  Check(Utf16Length(Text) = 5, 'UTF-16 length of a, e acute, an emoji and b');
  Check(Utf16OffsetToByteOffset(Text, 0) = 0, 'UTF-16 offset 0');
  Check(Utf16OffsetToByteOffset(Text, 2) = 3, 'UTF-16 offset 2 is byte 3');
  Check(Utf16OffsetToByteOffset(Text, 4) = 7, 'UTF-16 offset 4 is byte 7');
  Check(Utf16OffsetToByteOffset(Text, 9) = Length(Text), 'UTF-16 offset past the end');
  Check(ByteOffsetToUtf16Offset(Text, 7) = 4, 'byte 7 is UTF-16 offset 4');
  Check(Utf8ToUtf16(Text) = UnicodeString('a'#$E9#$D83D#$DE00'b'), 'UTF-8 to UTF-16');
  Check(IsAsciiText('abc') and not IsAsciiText(Text), 'ASCII detection');
end;

procedure RunEncodingTests;
begin
  TestLabels;
  TestUtf8Decoder;
  TestUtf16Decoders;
  TestSingleByteDecoders;
  TestSniffing;
  TestParserEncodings;
  TestUtf8Helpers;
end;

end.
