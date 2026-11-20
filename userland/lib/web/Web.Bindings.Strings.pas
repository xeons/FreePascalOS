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
  Strings between JavaScript (UTF-16, one byte per unit when Latin-1)
  and the DOM (UTF-8; a lone surrogate from script kept as generalized
  UTF-8, WTF-8). ASCII text is copied byte for byte both ways.

  DOMString keeps lone surrogates (WTF-8); USVString replaces them with
  U+FFFD (proper UTF-8), as WebIDL says.
}
unit Web.Bindings.Strings;

{$mode objfpc}
{$H+}

interface

uses
  Js.Values,
  Js.Heap,
  Js.Strings,
  Js.Runtime;

{ The DOM text of a JavaScript string: WTF-8 (KeepSurrogates) or UTF-8. }
function JsStringToText(Heap: TJsHeap; Text: TJsString; KeepSurrogates: Boolean = True): string;
{ A JavaScript string of UTF-8 or WTF-8 text. }
function TextToJsString(Heap: TJsHeap; const Text: string): TJsString;
function TextToJsValue(Heap: TJsHeap; const Text: string): TJsValue; inline;

implementation

function IsAsciiRun(Text: PChar; Count: SizeInt): Boolean;
var
  Index: SizeInt;
begin
  for Index := 0 to Count - 1 do
    if Ord(Text[Index]) >= $80 then
      Exit(False);
  Result := True;
end;

procedure AppendUtf8(var Output: string; var Length: SizeInt; CodePoint: LongWord);
begin
  if Length + 4 > System.Length(Output) then
    SetLength(Output, System.Length(Output) * 2 + 8);
  if CodePoint < $80 then
  begin
    Output[Length + 1] := Chr(CodePoint);
    Inc(Length);
  end
  else if CodePoint < $800 then
  begin
    Output[Length + 1] := Chr($C0 or (CodePoint shr 6));
    Output[Length + 2] := Chr($80 or (CodePoint and $3F));
    Inc(Length, 2);
  end
  else if CodePoint < $10000 then
  begin
    Output[Length + 1] := Chr($E0 or (CodePoint shr 12));
    Output[Length + 2] := Chr($80 or ((CodePoint shr 6) and $3F));
    Output[Length + 3] := Chr($80 or (CodePoint and $3F));
    Inc(Length, 3);
  end
  else
  begin
    Output[Length + 1] := Chr($F0 or (CodePoint shr 18));
    Output[Length + 2] := Chr($80 or ((CodePoint shr 12) and $3F));
    Output[Length + 3] := Chr($80 or ((CodePoint shr 6) and $3F));
    Output[Length + 4] := Chr($80 or (CodePoint and $3F));
    Inc(Length, 4);
  end;
end;

function JsStringToText(Heap: TJsHeap; Text: TJsString; KeepSurrogates: Boolean): string;
var
  Index, Count: Integer;
  Length: SizeInt;
  Units: PWord;
  Bytes: PByte;
  Unit_, Next: Word;
begin
  Result := '';
  Text.Flatten(Heap);
  Count := Text.Length;
  if Count = 0 then
    Exit;
  Length := 0;
  if not Text.IsWide then
  begin
    Bytes := Text.Chars8;
    if IsAsciiRun(PChar(Bytes), Count) then
    begin
      SetLength(Result, Count);
      Move(Bytes^, Result[1], Count);
      Exit;
    end;
    SetLength(Result, Count * 2);
    for Index := 0 to Count - 1 do
      AppendUtf8(Result, Length, Bytes[Index]);
    SetLength(Result, Length);
    Exit;
  end;
  Units := Text.Chars16;
  SetLength(Result, Count * 3);
  Index := 0;
  while Index < Count do
  begin
    Unit_ := Units[Index];
    Inc(Index);
    if (Unit_ >= $D800) and (Unit_ <= $DBFF) and (Index < Count) then
    begin
      Next := Units[Index];
      if (Next >= $DC00) and (Next <= $DFFF) then
      begin
        Inc(Index);
        AppendUtf8(Result, Length, $10000 + ((LongWord(Unit_) - $D800) shl 10) + (LongWord(Next) - $DC00));
        Continue;
      end;
    end;
    if (Unit_ >= $D800) and (Unit_ <= $DFFF) and not KeepSurrogates then
      Unit_ := $FFFD;
    AppendUtf8(Result, Length, Unit_);
  end;
  SetLength(Result, Length);
end;

function TextToJsString(Heap: TJsHeap; const Text: string): TJsString;
var
  Units: array of Word;
  Count, Index, Length: SizeInt;
  Lead: Byte;
  CodePoint: LongWord;
  Needed: Integer;
begin
  Count := System.Length(Text);
  if Count = 0 then
    Exit(NewLatin1String(Heap, nil, 0));
  if IsAsciiRun(PChar(Text), Count) then
    Exit(NewLatin1String(Heap, PByte(PChar(Text)), Count));
  Units := nil;
  SetLength(Units, Count);
  Length := 0;
  Index := 1;
  while Index <= Count do
  begin
    Lead := Ord(Text[Index]);
    Inc(Index);
    if Lead < $80 then
    begin
      CodePoint := Lead;
      Needed := 0;
    end
    else if (Lead and $E0) = $C0 then
    begin
      CodePoint := Lead and $1F;
      Needed := 1;
    end
    else if (Lead and $F0) = $E0 then
    begin
      CodePoint := Lead and $0F;
      Needed := 2;
    end
    else if (Lead and $F8) = $F0 then
    begin
      CodePoint := Lead and $07;
      Needed := 3;
    end
    else
    begin
      CodePoint := $FFFD;
      Needed := 0;
    end;
    while (Needed > 0) and (Index <= Count) and ((Ord(Text[Index]) and $C0) = $80) do
    begin
      CodePoint := (CodePoint shl 6) or (Ord(Text[Index]) and $3F);
      Inc(Index);
      Dec(Needed);
    end;
    if Needed > 0 then
      CodePoint := $FFFD;
    if CodePoint >= $10000 then
    begin
      Units[Length] := $D800 + ((CodePoint - $10000) shr 10);
      Units[Length + 1] := $DC00 + ((CodePoint - $10000) and $3FF);
      Inc(Length, 2);
    end
    else
    begin
      Units[Length] := CodePoint;
      Inc(Length);
    end;
  end;
  Result := NewUtf16String(Heap, @Units[0], Length);
end;

function TextToJsValue(Heap: TJsHeap; const Text: string): TJsValue;
begin
  Result := JsStringValue(TextToJsString(Heap, Text));
end;

end.
