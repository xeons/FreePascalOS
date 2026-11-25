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
  UnicodeTest

  The kernel's UTF-8 and UTF-16 conversions for file names
  (Runtime.Unicode) on the host: well-formed text of every length
  decodes; overlong forms, surrogates, code points past U+10FFFF, stray
  and missing continuation bytes decode to the replacement character;
  Utf8ToUtf16 never writes a lone surrogate, and pairs only for code
  points from U+10000; UTF-16 back to UTF-8 round trips, and lone
  surrogates become the replacement character.

  Prints every failed check and exits with 1 if there was one.
}
program UnicodeTest;

{$mode objfpc}

uses
  SysUtils,
  Runtime.Unicode;

var
  Failures: Integer = 0;

procedure Check(Condition: Boolean; const What: string);
begin
  if not Condition then
  begin
    WriteLn('FAIL: ', What);
    Inc(Failures);
  end;
end;

{ The code points DecodeUtf8 finds in Text, one after another. }
function DecodeAll(const Text: RawByteString): string;
var
  Position: PtrUInt;
begin
  Result := '';
  Position := 0;
  while Position < PtrUInt(Length(Text)) do
  begin
    if Result <> '' then
      Result := Result + ' ';
    Result := Result + IntToHex(DecodeUtf8(PChar(Text), Position), 1);
  end;
end;

procedure TestWellFormed;
begin
  Check(DecodeAll('A') = '41', 'ASCII');
  Check(DecodeAll(#$C3#$A9) = 'E9', 'two bytes (U+00E9)');
  Check(DecodeAll(#$C2#$80) = '80', 'the smallest two byte form');
  Check(DecodeAll(#$E2#$82#$AC) = '20AC', 'three bytes (U+20AC)');
  Check(DecodeAll(#$E0#$A0#$80) = '800', 'the smallest three byte form');
  Check(DecodeAll(#$ED#$9F#$BF) = 'D7FF', 'the last code point before the surrogates');
  Check(DecodeAll(#$EE#$80#$80) = 'E000', 'the first code point after the surrogates');
  Check(DecodeAll(#$F0#$9F#$98#$80) = '1F600', 'four bytes (U+1F600)');
  Check(DecodeAll(#$F4#$8F#$BF#$BF) = '10FFFF', 'the last code point');
end;

procedure TestMalformed;
begin
  Check(DecodeAll(#$C0#$AF) = 'FFFD', 'an overlong "/" in two bytes');
  Check(DecodeAll(#$C1#$BF) = 'FFFD', 'an overlong two byte form');
  Check(DecodeAll(#$E0#$80#$AF) = 'FFFD', 'an overlong "/" in three bytes');
  Check(DecodeAll(#$F0#$80#$80#$AF) = 'FFFD', 'an overlong "/" in four bytes');
  Check(DecodeAll(#$F0#$8F#$BF#$BF) = 'FFFD', 'an overlong U+FFFF in four bytes');
  Check(DecodeAll(#$ED#$A0#$80) = 'FFFD', 'a high surrogate');
  Check(DecodeAll(#$ED#$BF#$BF) = 'FFFD', 'a low surrogate');
  Check(DecodeAll(#$F4#$90#$80#$80) = 'FFFD', 'U+110000');
  Check(DecodeAll(#$F7#$BF#$BF#$BF) = 'FFFD', 'past U+10FFFF');
  Check(DecodeAll(#$F8#$88#$80#$80#$80) = 'FFFD FFFD FFFD FFFD FFFD', 'a five byte lead');
  Check(DecodeAll(#$80'A') = 'FFFD 41', 'a stray continuation byte');
  Check(DecodeAll(#$C3'A') = 'FFFD 41', 'a missing continuation byte keeps the next character');
end;

function ToUtf16(const Text: RawByteString; out Units: array of Word): PtrInt;
begin
  Result := Utf8ToUtf16(PChar(Text), @Units[0], Length(Units));
end;

procedure TestToUtf16;
var
  Units: array[0..15] of Word;
  Count: PtrInt;
  Index: Integer;
  LoneSurrogate: Boolean;
begin
  Count := ToUtf16(#$F0#$9F#$98#$80, Units);
  Check((Count = 2) and (Units[0] = $D83D) and (Units[1] = $DE00), 'U+1F600 is a surrogate pair');
  Count := ToUtf16(#$ED#$A0#$80#$F4#$90#$80#$80#$C0#$AF, Units);
  LoneSurrogate := False;
  for Index := 0 to Count - 1 do
    if (Units[Index] >= $D800) and (Units[Index] <= $DFFF) then
      LoneSurrogate := True;
  Check((Count = 3) and not LoneSurrogate, 'malformed input never becomes a surrogate');
  Check((Units[0] = $FFFD) and (Units[1] = $FFFD) and (Units[2] = $FFFD), 'each becomes U+FFFD');
  Check(ToUtf16(#$F0#$9F#$98#$80, Units[0..0]) = -1, 'a pair does not fit in one unit');
end;

function FromUtf16(const Units: array of Word): string;
var
  Buffer: array[0..63] of Char;
  Builder: TUtf8Builder;
begin
  BeginUtf8(Builder, @Buffer[0], SizeOf(Buffer));
  AppendUtf16(Builder, @Units[0], Length(Units));
  Result := DecodeAll(StrPas(@Buffer[0]));
end;

procedure TestFromUtf16;
var
  Buffer: array[0..15] of Char;
  Builder: TUtf8Builder;
begin
  Check(FromUtf16([$D83D, $DE00]) = '1F600', 'a surrogate pair round trips');
  Check(FromUtf16([$D83D, $41]) = 'FFFD 41', 'a lone high surrogate');
  Check(FromUtf16([$DE00]) = 'FFFD', 'a lone low surrogate');
  BeginUtf8(Builder, @Buffer[0], SizeOf(Buffer));
  AppendCodePoint(Builder, $D800);
  Check(DecodeAll(StrPas(@Buffer[0])) = 'FFFD', 'AppendCodePoint writes no surrogate');
end;

begin
  TestWellFormed;
  TestMalformed;
  TestToUtf16;
  TestFromUtf16;
  if Failures > 0 then
  begin
    WriteLn('UnicodeTest: ', Failures, ' failures');
    Halt(1);
  end;
  WriteLn('UnicodeTest: all checks passed');
end.
