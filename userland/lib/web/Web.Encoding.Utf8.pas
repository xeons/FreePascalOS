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
  UTF-8 text, as the DOM keeps it, and its UTF-16 view (what JavaScript
  and the DOM APIs count in):

  - the UTF-8 encoder ("UTF-8 encode": lone surrogates become U+FFFD);
  - UTF-16 to UTF-8 keeping lone surrogates (generalized UTF-8, "WTF-8":
    a surrogate as the three bytes ED A0..BF xx), which is how DOM text
    set from JavaScript keeps a lone surrogate; the HTML parser never
    makes one;
  - UTF-8 to UTF-16, UTF-16 lengths and the conversion of UTF-16 offsets
    to byte offsets. These scan the text, but ASCII text (the common
    case; nodes remember it) needs none: there the offsets are the same.
}
unit Web.Encoding.Utf8;

{$mode objfpc}
{$H+}

interface

{ UTF-8 encode: a lone surrogate becomes U+FFFD. }
function EncodeUtf8(const Text: UnicodeString): string;
{ UTF-16 to generalized UTF-8: lone surrogates are kept. }
function Utf16ToUtf8(const Text: UnicodeString): string;
function Utf8ToUtf16(const Text: string): UnicodeString;
function EncodeCodePoint(CodePoint: LongWord): string;
{ The code point at Index (1 based), which moves past it; malformed bytes
  read as U+FFFD one at a time. }
function NextCodePoint(const Text: string; var Index: SizeInt): LongWord;
function IsAsciiText(const Text: string): Boolean;
function IsAsciiBytes(Text: PChar; Count: SizeInt): Boolean;
{ The length in UTF-16 code units. }
function Utf16Length(const Text: string): SizeInt;
{ The byte offset (0 based) of a UTF-16 offset; an offset inside a
  surrogate pair gives the start of the pair. Past the end: the length. }
function Utf16OffsetToByteOffset(const Text: string; Offset: SizeInt): SizeInt;
function ByteOffsetToUtf16Offset(const Text: string; ByteOffset: SizeInt): SizeInt;

implementation

procedure AppendCodePoint(var Output: string; var Used: SizeInt; CodePoint: LongWord);
begin
  if Used + 4 > Length(Output) then
    SetLength(Output, (Length(Output) + 4) * 2);
  if CodePoint < $80 then
  begin
    Output[Used + 1] := Chr(CodePoint);
    Inc(Used);
  end
  else if CodePoint < $800 then
  begin
    Output[Used + 1] := Chr($C0 or (CodePoint shr 6));
    Output[Used + 2] := Chr($80 or (CodePoint and $3F));
    Inc(Used, 2);
  end
  else if CodePoint < $10000 then
  begin
    Output[Used + 1] := Chr($E0 or (CodePoint shr 12));
    Output[Used + 2] := Chr($80 or ((CodePoint shr 6) and $3F));
    Output[Used + 3] := Chr($80 or (CodePoint and $3F));
    Inc(Used, 3);
  end
  else
  begin
    Output[Used + 1] := Chr($F0 or (CodePoint shr 18));
    Output[Used + 2] := Chr($80 or ((CodePoint shr 12) and $3F));
    Output[Used + 3] := Chr($80 or ((CodePoint shr 6) and $3F));
    Output[Used + 4] := Chr($80 or (CodePoint and $3F));
    Inc(Used, 4);
  end;
end;

function ConvertUtf16(const Text: UnicodeString; KeepLoneSurrogates: Boolean): string;
var
  Index, Used: SizeInt;
  Unit1, Unit2: LongWord;
begin
  Result := '';
  SetLength(Result, Length(Text));
  Used := 0;
  Index := 1;
  while Index <= Length(Text) do
  begin
    Unit1 := Ord(Text[Index]);
    Inc(Index);
    if (Unit1 >= $D800) and (Unit1 <= $DBFF) and (Index <= Length(Text)) then
    begin
      Unit2 := Ord(Text[Index]);
      if (Unit2 >= $DC00) and (Unit2 <= $DFFF) then
      begin
        Inc(Index);
        AppendCodePoint(Result, Used, $10000 + ((Unit1 - $D800) shl 10) + (Unit2 - $DC00));
        Continue;
      end;
    end;
    if (Unit1 >= $D800) and (Unit1 <= $DFFF) and not KeepLoneSurrogates then
      Unit1 := $FFFD;
    AppendCodePoint(Result, Used, Unit1);
  end;
  SetLength(Result, Used);
end;

function EncodeUtf8(const Text: UnicodeString): string;
begin
  Result := ConvertUtf16(Text, False);
end;

function Utf16ToUtf8(const Text: UnicodeString): string;
begin
  Result := ConvertUtf16(Text, True);
end;

function EncodeCodePoint(CodePoint: LongWord): string;
var
  Used: SizeInt;
begin
  Result := '';
  Used := 0;
  AppendCodePoint(Result, Used, CodePoint);
  SetLength(Result, Used);
end;

function NextCodePoint(const Text: string; var Index: SizeInt): LongWord;
var
  Lead: Byte;
  Needed, Seen: Integer;
  Value: LongWord;
begin
  Lead := Ord(Text[Index]);
  Inc(Index);
  if Lead < $80 then
    Exit(Lead);
  case Lead of
    $C2..$DF:
      begin
        Needed := 1;
        Value := Lead and $1F;
      end;
    $E0..$EF:
      begin
        Needed := 2;
        Value := Lead and $0F;
      end;
    $F0..$F4:
      begin
        Needed := 3;
        Value := Lead and $07;
      end;
  else
    Exit($FFFD);
  end;
  Seen := 0;
  while (Seen < Needed) and (Index <= Length(Text)) and ((Ord(Text[Index]) and $C0) = $80) do
  begin
    Value := (Value shl 6) or (Ord(Text[Index]) and $3F);
    Inc(Index);
    Inc(Seen);
  end;
  if Seen < Needed then
    Exit($FFFD);
  Result := Value;
end;

function IsAsciiBytes(Text: PChar; Count: SizeInt): Boolean;
var
  Index: SizeInt;
begin
  for Index := 1 to Count do
    if Ord(Text[Index - 1]) >= $80 then
      Exit(False);
  Result := True;
end;

function IsAsciiText(const Text: string): Boolean;
begin
  Result := IsAsciiBytes(PChar(Text), Length(Text));
end;

function Utf8ToUtf16(const Text: string): UnicodeString;
var
  Index, Used: SizeInt;
  CodePoint: LongWord;
begin
  Result := '';
  SetLength(Result, Length(Text));
  Used := 0;
  Index := 1;
  while Index <= Length(Text) do
  begin
    CodePoint := NextCodePoint(Text, Index);
    if CodePoint >= $10000 then
    begin
      Dec(CodePoint, $10000);
      Result[Used + 1] := WideChar($D800 + (CodePoint shr 10));
      Result[Used + 2] := WideChar($DC00 + (CodePoint and $3FF));
      Inc(Used, 2);
    end
    else
    begin
      Result[Used + 1] := WideChar(CodePoint);
      Inc(Used);
    end;
  end;
  SetLength(Result, Used);
end;

function Utf16Length(const Text: string): SizeInt;
var
  Index: SizeInt;
  Value: Byte;
begin
  Result := 0;
  for Index := 1 to Length(Text) do
  begin
    Value := Ord(Text[Index]);
    { Each code point counts at its first byte; four byte sequences
      (outside the BMP) are two code units. }
    if (Value and $C0) <> $80 then
    begin
      Inc(Result);
      if Value >= $F0 then
        Inc(Result);
    end;
  end;
end;

function Utf16OffsetToByteOffset(const Text: string; Offset: SizeInt): SizeInt;
var
  Index, Units: SizeInt;
  Value: Byte;
begin
  Units := 0;
  Index := 1;
  while Index <= Length(Text) do
  begin
    Value := Ord(Text[Index]);
    if (Value and $C0) <> $80 then
    begin
      if Value >= $F0 then
      begin
        if Units + 2 > Offset then
          Exit(Index - 1);
        Inc(Units, 2);
      end
      else
      begin
        if Units >= Offset then
          Exit(Index - 1);
        Inc(Units);
      end;
    end;
    Inc(Index);
  end;
  Result := Length(Text);
end;

function ByteOffsetToUtf16Offset(const Text: string; ByteOffset: SizeInt): SizeInt;
var
  Index: SizeInt;
  Value: Byte;
begin
  Result := 0;
  Index := 1;
  while (Index <= Length(Text)) and (Index <= ByteOffset) do
  begin
    Value := Ord(Text[Index]);
    if (Value and $C0) <> $80 then
    begin
      Inc(Result);
      if Value >= $F0 then
        Inc(Result);
    end;
    Inc(Index);
  end;
end;

end.
