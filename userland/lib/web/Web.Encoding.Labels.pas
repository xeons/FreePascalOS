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
  The encodings of the WHATWG Encoding Standard, their names and labels
  (generated from data/encoding-labels.txt), and "get an encoding": a
  label, trimmed of ASCII whitespace and compared without regard to ASCII
  case, to its encoding.
}
unit Web.Encoding.Labels;

{$mode objfpc}
{$H+}

interface

{$I Web.Encoding.Table.inc}

{ Get an encoding: False if the label names none. }
function EncodingForLabel(const LabelText: string; out Encoding: TTextEncoding): Boolean;
function EncodingName(Encoding: TTextEncoding): string; inline;
{ Get an output encoding: UTF-8 for replacement, UTF-16BE and UTF-16LE. }
function OutputEncoding(Encoding: TTextEncoding): TTextEncoding;
function IsSingleByteEncoding(Encoding: TTextEncoding): Boolean; inline;
{ Whether libweb can decode it (the multi-byte CJK encodings not yet). }
function IsDecodableEncoding(Encoding: TTextEncoding): Boolean;

type
  TEncodingNameArray = array of string;

{ The canonical names of the encodings a user may choose to decode a
  document with (a browser's Character Encoding menu): every one libweb
  decodes but replacement and x-user-defined, in the Encoding
  Standard's order (UTF-8 first). }
function SelectableEncodingNames: TEncodingNameArray;

implementation

uses
  SysUtils;

function TrimAsciiWhitespace(const Text: string): string;
var
  First, Last: SizeInt;
begin
  First := 1;
  Last := Length(Text);
  while (First <= Last) and (Text[First] in [#9, #10, #12, #13, ' ']) do
    Inc(First);
  while (Last >= First) and (Text[Last] in [#9, #10, #12, #13, ' ']) do
    Dec(Last);
  Result := Copy(Text, First, Last - First + 1);
end;

function LowerAscii(const Text: string): string;
var
  Index: SizeInt;
begin
  Result := Text;
  UniqueString(Result);
  for Index := 1 to Length(Result) do
    if Result[Index] in ['A'..'Z'] then
      Result[Index] := Chr(Ord(Result[Index]) + 32);
end;

function EncodingForLabel(const LabelText: string; out Encoding: TTextEncoding): Boolean;
var
  Key: string;
  Low, High, Middle, Comparison: Integer;
begin
  Encoding := TextEncodingUtf8;
  Key := LowerAscii(TrimAsciiWhitespace(LabelText));
  Low := 0;
  High := EncodingLabelCount - 1;
  while Low <= High do
  begin
    Middle := (Low + High) div 2;
    Comparison := CompareStr(EncodingLabels[Middle].Name, Key);
    if Comparison = 0 then
    begin
      Encoding := EncodingLabels[Middle].Encoding;
      Exit(True);
    end;
    if Comparison < 0 then
      Low := Middle + 1
    else
      High := Middle - 1;
  end;
  Result := False;
end;

function EncodingName(Encoding: TTextEncoding): string;
begin
  Result := TextEncodingNames[Encoding];
end;

function OutputEncoding(Encoding: TTextEncoding): TTextEncoding;
begin
  if Encoding in [TextEncodingReplacement, TextEncodingUtf16Be, TextEncodingUtf16Le] then
    Result := TextEncodingUtf8
  else
    Result := Encoding;
end;

function IsSingleByteEncoding(Encoding: TTextEncoding): Boolean;
begin
  Result := SingleByteIndexOf[Encoding] >= 0;
end;

function SelectableEncodingNames: TEncodingNameArray;
var
  Encoding: TTextEncoding;
begin
  Result := nil;
  for Encoding := Low(TTextEncoding) to High(TTextEncoding) do
    if IsDecodableEncoding(Encoding) and not (Encoding in [TextEncodingReplacement, TextEncodingXUserDefined]) then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := TextEncodingNames[Encoding];
    end;
end;

function IsDecodableEncoding(Encoding: TTextEncoding): Boolean;
begin
  Result := not (Encoding in [TextEncodingGbk, TextEncodingGb18030, TextEncodingBig5, TextEncodingEucJp,
    TextEncodingIso2022Jp, TextEncodingShiftJis, TextEncodingEucKr]);
end;

end.
