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
  Decoding fetched text to UTF-8:

  - style sheets (CSS Syntax section 3.2, "determine the fallback
    encoding"): a byte order mark, else the Content-Type charset, else an
    @charset "..." rule exactly at the start (UTF-16 labels meaning
    UTF-8), else the referring document's encoding, else UTF-8;
  - classic scripts (HTML "fetch a classic script"): a byte order mark,
    else the Content-Type charset, else the document's encoding;
    module scripts and JSON are always UTF-8 (a BOM still wins);
  - plain text documents use the HTML sniffing of the parser instead.

  Encodings without a decoder yet (the CJK ones) fall back to
  windows-1252 as the parser does.
}
unit Web.Loading.TextDecoding;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Web.Encoding.Labels;

function DecodeStyleSheetBytes(const Bytes, ContentCharset: string; DocumentEncoding: TTextEncoding): string;
function DecodeClassicScriptBytes(const Bytes, ContentCharset: string; DocumentEncoding: TTextEncoding): string;
function DecodeUtf8Bytes(const Bytes: string): string;
{ Bytes in Encoding (a BOM wins), never failing. }
function DecodeWithEncoding(const Bytes: string; Encoding: TTextEncoding): string;

implementation

uses
  Web.Encoding.Sniffing,
  Web.Encoding.DecoderFactory;

function DecodeWithEncoding(const Bytes: string; Encoding: TTextEncoding): string;
var
  Bom: TTextEncoding;
  MarkLength: Integer;
  Body: string;
begin
  Body := Bytes;
  if SniffByteOrderMark(PByte(PChar(Body)), Length(Body), Bom, MarkLength) then
  begin
    Encoding := Bom;
    Delete(Body, 1, MarkLength);
  end;
  if not IsDecodableEncoding(Encoding) then
    Encoding := TextEncodingWindows1252;
  Result := DecodeBytes(Body, Encoding);
end;

function CharsetEncoding(const Charset: string; out Encoding: TTextEncoding): Boolean;
begin
  Result := (Charset <> '') and EncodingForLabel(Charset, Encoding);
end;

function DecodeStyleSheetBytes(const Bytes, ContentCharset: string; DocumentEncoding: TTextEncoding): string;
const
  CharsetStart = '@charset "';
var
  Encoding: TTextEncoding;
  Closing: Integer;
  LabelText: string;
begin
  if CharsetEncoding(ContentCharset, Encoding) then
    Exit(DecodeWithEncoding(Bytes, Encoding));
  if Copy(Bytes, 1, Length(CharsetStart)) = CharsetStart then
  begin
    Closing := Pos('";', Copy(Bytes, 1, 1024));
    if Closing > Length(CharsetStart) then
    begin
      LabelText := Copy(Bytes, Length(CharsetStart) + 1, Closing - Length(CharsetStart) - 1);
      if EncodingForLabel(LabelText, Encoding) then
      begin
        if Encoding in [TextEncodingUtf16Be, TextEncodingUtf16Le] then
          Encoding := TextEncodingUtf8;
        Exit(DecodeWithEncoding(Bytes, Encoding));
      end;
    end;
  end;
  Result := DecodeWithEncoding(Bytes, DocumentEncoding);
end;

function DecodeClassicScriptBytes(const Bytes, ContentCharset: string; DocumentEncoding: TTextEncoding): string;
var
  Encoding: TTextEncoding;
begin
  if not CharsetEncoding(ContentCharset, Encoding) then
    Encoding := DocumentEncoding;
  Result := DecodeWithEncoding(Bytes, Encoding);
end;

function DecodeUtf8Bytes(const Bytes: string): string;
begin
  Result := DecodeWithEncoding(Bytes, TextEncodingUtf8);
end;

end.
