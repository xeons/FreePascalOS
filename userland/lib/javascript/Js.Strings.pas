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
  JavaScript strings: immutable sequences of UTF-16 code units.

  A flat string holds one byte per code unit when every unit is below
  256 (Latin-1), two otherwise. Concatenating long strings makes a rope
  (the two halves, flattened into one buffer the first time anything
  looks at the characters), so building a string piece by piece is not
  quadratic. Flattening walks the rope with a stack of its own: a rope
  as deep as a loop of += is long does not deepen the Pascal stack.

  An atom is a flat string the atom table has interned (Js.Atoms):
  equal atoms are the same cell, so property keys compare by pointer.
  The hash (FNV-1a over the code units, the same for both widths) and
  whether the string is an array index ("0", "17", never "017") are
  worked out once and kept.
}
unit Js.Strings;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  Js.Values,
  Js.Heap;

const
  { Longest string: 2^30 - 1 code units. }
  JsMaximumStringLength = (1 shl 30) - 1;
  { Shorter results of a concatenation are copied, longer ones roped. }
  JsRopeThreshold = 40;

  StringFlagWide = 1;
  StringFlagRope = 2;
  StringFlagAtom = 4;
  StringFlagIndexKnown = 8;
  StringFlagIsIndex = 16;

type
  TJsString = class(TJsCell)
  private
    FLength: Integer;
    FHash: LongWord;
    FFlags: Byte;
    FIndex: LongWord;
    FData: Pointer;
    FLeft: TJsString;
    FRight: TJsString;
    procedure ComputeIndex;
    procedure FlattenRope(Heap: TJsHeap);
  public
    destructor Destroy; override;
    procedure Trace(Tracer: TJsTracer); override;
    function MemorySize: SizeInt; override;
    { Makes the characters one buffer (a rope's first look). }
    procedure Flatten(Heap: TJsHeap); inline;
    function Hash: LongWord;
    { The array index this string names, if it is one (below 2^32 - 1). }
    function ArrayIndex(out Index: LongWord): Boolean;
    function IsWide: Boolean; inline;
    function IsRope: Boolean; inline;
    function IsAtom: Boolean; inline;
    { The code unit at Index of a flat string. }
    function CharAt(Index: Integer): Word; inline;
    function Chars8: PByte; inline;
    function Chars16: PWord; inline;
    procedure MarkAtom;
    property Length: Integer read FLength;
    property Flags: Byte read FFlags;
  end;

  TJsStringList = array of TJsString;

function NewLatin1String(Heap: TJsHeap; Characters: PByte; Count: Integer): TJsString;
{ Narrows to Latin-1 when every unit fits. }
function NewUtf16String(Heap: TJsHeap; Units: PWord; Count: Integer): TJsString;
{ A string of Count units to fill in (Wide: two bytes each). }
function NewBlankString(Heap: TJsHeap; Count: Integer; Wide: Boolean): TJsString;
function NewStringFromUtf8(Heap: TJsHeap; const Text: string): TJsString;
function NewStringFromUnicode(Heap: TJsHeap; const Text: UnicodeString): TJsString;
{ A + B; nil when the result would be too long. }
function ConcatStrings(Heap: TJsHeap; First, Second: TJsString): TJsString;
function SubString(Heap: TJsHeap; Text: TJsString; Start, Count: Integer): TJsString;

{ The text as UTF-8 (lone surrogates become U+FFFD). }
function StringToUtf8(Heap: TJsHeap; Text: TJsString): string;
function StringToUnicode(Heap: TJsHeap; Text: TJsString): UnicodeString;
function StringsEqual(Heap: TJsHeap; First, Second: TJsString): Boolean;
{ <0, 0, >0 by code units. }
function CompareStrings(Heap: TJsHeap; First, Second: TJsString): Integer;
{ The first Count units equal Pattern's at Offset of Text. }
function StringRegionEquals(Text: TJsString; Offset: Integer; Pattern: TJsString): Boolean;
{ Index of Pattern in Text from Start, -1 when absent (both flat). }
function StringIndexOf(Text, Pattern: TJsString; Start: Integer): Integer;
function StringLastIndexOf(Text, Pattern: TJsString; Start: Integer): Integer;
function HashUnits8(Characters: PByte; Count: Integer): LongWord;
function HashUnits16(Units: PWord; Count: Integer): LongWord;
{ Whether the code units of Text equal the ASCII text. }
function StringEqualsAscii(Text: TJsString; const Ascii: string): Boolean;

implementation

const
  FnvOffset = LongWord(2166136261);
  FnvPrime = LongWord(16777619);

function HashUnits8(Characters: PByte; Count: Integer): LongWord;
var
  Index: Integer;
begin
  Result := FnvOffset;
  for Index := 0 to Count - 1 do
    Result := (Result xor Characters[Index]) * FnvPrime;
  if Result = 0 then
    Result := 1;
end;

function HashUnits16(Units: PWord; Count: Integer): LongWord;
var
  Index: Integer;
begin
  Result := FnvOffset;
  for Index := 0 to Count - 1 do
    Result := (Result xor Units[Index]) * FnvPrime;
  if Result = 0 then
    Result := 1;
end;

{ TJsString }

destructor TJsString.Destroy;
begin
  if FData <> nil then
    FreeMem(FData);
  inherited Destroy;
end;

procedure TJsString.Trace(Tracer: TJsTracer);
begin
  if FLeft <> nil then
    Tracer.MarkCell(FLeft);
  if FRight <> nil then
    Tracer.MarkCell(FRight);
end;

function TJsString.MemorySize: SizeInt;
begin
  Result := InstanceSize;
  if FData <> nil then
  begin
    if (FFlags and StringFlagWide) <> 0 then
      Inc(Result, FLength * 2)
    else
      Inc(Result, FLength);
  end;
end;

function TJsString.IsWide: Boolean;
begin
  Result := (FFlags and StringFlagWide) <> 0;
end;

function TJsString.IsRope: Boolean;
begin
  Result := (FFlags and StringFlagRope) <> 0;
end;

function TJsString.IsAtom: Boolean;
begin
  Result := (FFlags and StringFlagAtom) <> 0;
end;

function TJsString.CharAt(Index: Integer): Word;
begin
  if (FFlags and StringFlagWide) <> 0 then
    Result := PWord(FData)[Index]
  else
    Result := PByte(FData)[Index];
end;

function TJsString.Chars8: PByte;
begin
  Result := PByte(FData);
end;

function TJsString.Chars16: PWord;
begin
  Result := PWord(FData);
end;

procedure TJsString.MarkAtom;
begin
  FFlags := FFlags or StringFlagAtom;
end;

procedure TJsString.Flatten(Heap: TJsHeap);
begin
  if (FFlags and StringFlagRope) <> 0 then
    FlattenRope(Heap);
end;

{ Apart from Flatten so that flat strings, nearly every call, skip
  setting up and freeing the stack. }
procedure TJsString.FlattenRope(Heap: TJsHeap);
var
  Stack: array of TJsString;
  StackCount: Integer;
  Node: TJsString;
  Position, Bytes: Integer;
  Wide: Boolean;
  Index: Integer;
  Target8: PByte;
  Target16: PWord;
begin
  Wide := (FFlags and StringFlagWide) <> 0;
  if Wide then
    Bytes := FLength * 2
  else
    Bytes := FLength;
  FData := GetMem(Bytes + 2);
  Target8 := PByte(FData);
  Target16 := PWord(FData);
  Stack := nil;
  SetLength(Stack, 32);
  Stack[0] := Self;
  StackCount := 1;
  Position := 0;
  while StackCount > 0 do
  begin
    Dec(StackCount);
    Node := Stack[StackCount];
    if ((Node.FFlags and StringFlagRope) <> 0) and (Node.FData = nil) or (Node = Self) then
    begin
      if StackCount + 2 > System.Length(Stack) then
        SetLength(Stack, System.Length(Stack) * 2);
      Stack[StackCount] := Node.FRight;
      Stack[StackCount + 1] := Node.FLeft;
      Inc(StackCount, 2);
      Continue;
    end;
    if Wide then
    begin
      if (Node.FFlags and StringFlagWide) <> 0 then
        Move(Node.FData^, Target16[Position], Node.FLength * 2)
      else
        for Index := 0 to Node.FLength - 1 do
          Target16[Position + Index] := PByte(Node.FData)[Index];
    end
    else
      Move(Node.FData^, Target8[Position], Node.FLength);
    Inc(Position, Node.FLength);
  end;
  FLeft := nil;
  FRight := nil;
  FFlags := FFlags and not StringFlagRope;
  Heap.Account(Bytes);
end;

function TJsString.Hash: LongWord;
begin
  if FHash = 0 then
  begin
    if (FFlags and StringFlagWide) <> 0 then
      FHash := HashUnits16(PWord(FData), FLength)
    else
      FHash := HashUnits8(PByte(FData), FLength);
  end;
  Result := FHash;
end;

procedure TJsString.ComputeIndex;
var
  Value: QWord;
  Index: Integer;
  Unit16: Word;
begin
  FFlags := FFlags or StringFlagIndexKnown;
  if (FLength = 0) or (FLength > 10) then
    Exit;
  if (FLength > 1) and (CharAt(0) = Ord('0')) then
    Exit;
  Value := 0;
  for Index := 0 to FLength - 1 do
  begin
    Unit16 := CharAt(Index);
    if (Unit16 < Ord('0')) or (Unit16 > Ord('9')) then
      Exit;
    Value := Value * 10 + (Unit16 - Ord('0'));
  end;
  if Value >= QWord($FFFFFFFF) then
    Exit;
  FIndex := LongWord(Value);
  FFlags := FFlags or StringFlagIsIndex;
end;

function TJsString.ArrayIndex(out Index: LongWord): Boolean;
begin
  if (FFlags and StringFlagIndexKnown) = 0 then
    ComputeIndex;
  Index := FIndex;
  Result := (FFlags and StringFlagIsIndex) <> 0;
end;

{ Making strings }

function NewBlankString(Heap: TJsHeap; Count: Integer; Wide: Boolean): TJsString;
var
  Bytes: Integer;
begin
  Result := TJsString.Create;
  Heap.Register(Result, ckString);
  Result.FLength := Count;
  if Wide then
  begin
    Result.FFlags := StringFlagWide;
    Bytes := Count * 2;
  end
  else
    Bytes := Count;
  Result.FData := GetMem(Bytes + 2);
  Heap.Account(Bytes);
end;

function NewLatin1String(Heap: TJsHeap; Characters: PByte; Count: Integer): TJsString;
begin
  Result := NewBlankString(Heap, Count, False);
  if Count > 0 then
    Move(Characters^, Result.FData^, Count);
end;

function NewUtf16String(Heap: TJsHeap; Units: PWord; Count: Integer): TJsString;
var
  Index: Integer;
  Narrow: Boolean;
begin
  Narrow := True;
  for Index := 0 to Count - 1 do
    if Units[Index] > 255 then
    begin
      Narrow := False;
      Break;
    end;
  if Narrow then
  begin
    Result := NewBlankString(Heap, Count, False);
    for Index := 0 to Count - 1 do
      PByte(Result.FData)[Index] := Units[Index];
  end
  else
  begin
    Result := NewBlankString(Heap, Count, True);
    if Count > 0 then
      Move(Units^, Result.FData^, Count * 2);
  end;
end;

function NewStringFromUnicode(Heap: TJsHeap; const Text: UnicodeString): TJsString;
begin
  if Text = '' then
    Result := NewBlankString(Heap, 0, False)
  else
    Result := NewUtf16String(Heap, PWord(PUnicodeChar(Text)), System.Length(Text));
end;

{ Decodes UTF-8 into UTF-16 units; malformed bytes become U+FFFD. }
function DecodeUtf8(const Text: string; out Units: array of Word): Integer;
var
  Position, Count, Extra, Index: Integer;
  Lead: Byte;
  CodePoint, Minimum: LongWord;
begin
  Count := 0;
  Position := 1;
  while Position <= System.Length(Text) do
  begin
    Lead := Byte(Text[Position]);
    Inc(Position);
    if Lead < $80 then
    begin
      Units[Count] := Lead;
      Inc(Count);
      Continue;
    end;
    if (Lead and $E0) = $C0 then
    begin
      Extra := 1;
      CodePoint := Lead and $1F;
      Minimum := $80;
    end
    else if (Lead and $F0) = $E0 then
    begin
      Extra := 2;
      CodePoint := Lead and $0F;
      Minimum := $800;
    end
    else if (Lead and $F8) = $F0 then
    begin
      Extra := 3;
      CodePoint := Lead and $07;
      Minimum := $10000;
    end
    else
    begin
      Units[Count] := $FFFD;
      Inc(Count);
      Continue;
    end;
    Index := 0;
    while (Index < Extra) and (Position <= System.Length(Text)) and
      ((Byte(Text[Position]) and $C0) = $80) do
    begin
      CodePoint := (CodePoint shl 6) or (Byte(Text[Position]) and $3F);
      Inc(Position);
      Inc(Index);
    end;
    if (Index < Extra) or (CodePoint < Minimum) or (CodePoint > $10FFFF) then
    begin
      Units[Count] := $FFFD;
      Inc(Count);
    end
    else if CodePoint >= $10000 then
    begin
      Dec(CodePoint, $10000);
      Units[Count] := $D800 + (CodePoint shr 10);
      Units[Count + 1] := $DC00 + (CodePoint and $3FF);
      Inc(Count, 2);
    end
    else
    begin
      Units[Count] := CodePoint;
      Inc(Count);
    end;
  end;
  Result := Count;
end;

function NewStringFromNonAsciiUtf8(Heap: TJsHeap; const Text: string): TJsString;
var
  Units: array of Word;
  Count: Integer;
begin
  Units := nil;
  SetLength(Units, System.Length(Text) + 1);
  Count := DecodeUtf8(Text, Units);
  Result := NewUtf16String(Heap, @Units[0], Count);
end;

function NewStringFromUtf8(Heap: TJsHeap; const Text: string): TJsString;
var
  Index: Integer;
begin
  for Index := 1 to System.Length(Text) do
    if Byte(Text[Index]) >= $80 then
      Exit(NewStringFromNonAsciiUtf8(Heap, Text));
  Result := NewBlankString(Heap, System.Length(Text), False);
  if Text <> '' then
    Move(Text[1], Result.FData^, System.Length(Text));
end;

function ConcatStrings(Heap: TJsHeap; First, Second: TJsString): TJsString;
var
  Total, Index: Integer;
  Wide: Boolean;
begin
  if Second.FLength = 0 then
    Exit(First);
  if First.FLength = 0 then
    Exit(Second);
  Total := First.FLength + Second.FLength;
  if Total > JsMaximumStringLength then
    Exit(nil);
  Wide := ((First.FFlags or Second.FFlags) and StringFlagWide) <> 0;
  if Total < JsRopeThreshold then
  begin
    First.Flatten(Heap);
    Second.Flatten(Heap);
    Result := NewBlankString(Heap, Total, Wide);
    if Wide then
    begin
      for Index := 0 to First.FLength - 1 do
        PWord(Result.FData)[Index] := First.CharAt(Index);
      for Index := 0 to Second.FLength - 1 do
        PWord(Result.FData)[First.FLength + Index] := Second.CharAt(Index);
    end
    else
    begin
      Move(First.FData^, Result.FData^, First.FLength);
      Move(Second.FData^, PByte(Result.FData)[First.FLength], Second.FLength);
    end;
    Exit;
  end;
  Result := TJsString.Create;
  Heap.Register(Result, ckString);
  Result.FLength := Total;
  Result.FFlags := StringFlagRope;
  if Wide then
    Result.FFlags := Result.FFlags or StringFlagWide;
  Result.FLeft := First;
  Result.FRight := Second;
end;

function SubString(Heap: TJsHeap; Text: TJsString; Start, Count: Integer): TJsString;
begin
  Text.Flatten(Heap);
  if (Start = 0) and (Count = Text.FLength) then
    Exit(Text);
  if Text.IsWide then
    Result := NewUtf16String(Heap, @PWord(Text.FData)[Start], Count)
  else
    Result := NewLatin1String(Heap, @PByte(Text.FData)[Start], Count);
end;

function StringToUnicode(Heap: TJsHeap; Text: TJsString): UnicodeString;
var
  Index: Integer;
begin
  Result := '';
  Text.Flatten(Heap);
  SetLength(Result, Text.FLength);
  for Index := 0 to Text.FLength - 1 do
    Result[Index + 1] := WideChar(Text.CharAt(Index));
end;

function StringToUtf8(Heap: TJsHeap; Text: TJsString): string;
var
  Index, Count: Integer;
  CodePoint, Next: LongWord;
  Buffer: string;

  procedure Put(Value: Byte);
  begin
    Inc(Count);
    if Count > System.Length(Buffer) then
      SetLength(Buffer, System.Length(Buffer) * 2 + 16);
    Buffer[Count] := Char(Value);
  end;

begin
  Result := '';
  Text.Flatten(Heap);
  Buffer := '';
  SetLength(Buffer, Text.FLength + 8);
  Count := 0;
  Index := 0;
  while Index < Text.FLength do
  begin
    CodePoint := Text.CharAt(Index);
    Inc(Index);
    if (CodePoint >= $D800) and (CodePoint <= $DBFF) and (Index < Text.FLength) then
    begin
      Next := Text.CharAt(Index);
      if (Next >= $DC00) and (Next <= $DFFF) then
      begin
        CodePoint := $10000 + ((CodePoint - $D800) shl 10) + (Next - $DC00);
        Inc(Index);
      end;
    end;
    if (CodePoint >= $D800) and (CodePoint <= $DFFF) then
      CodePoint := $FFFD;
    if CodePoint < $80 then
      Put(CodePoint)
    else if CodePoint < $800 then
    begin
      Put($C0 or (CodePoint shr 6));
      Put($80 or (CodePoint and $3F));
    end
    else if CodePoint < $10000 then
    begin
      Put($E0 or (CodePoint shr 12));
      Put($80 or ((CodePoint shr 6) and $3F));
      Put($80 or (CodePoint and $3F));
    end
    else
    begin
      Put($F0 or (CodePoint shr 18));
      Put($80 or ((CodePoint shr 12) and $3F));
      Put($80 or ((CodePoint shr 6) and $3F));
      Put($80 or (CodePoint and $3F));
    end;
  end;
  SetLength(Buffer, Count);
  Result := Buffer;
end;

function StringsEqual(Heap: TJsHeap; First, Second: TJsString): Boolean;
var
  Index: Integer;
begin
  if First = Second then
    Exit(True);
  if First.FLength <> Second.FLength then
    Exit(False);
  if First.IsAtom and Second.IsAtom then
    Exit(False);
  First.Flatten(Heap);
  Second.Flatten(Heap);
  if (First.FHash <> 0) and (Second.FHash <> 0) and (First.FHash <> Second.FHash) then
    Exit(False);
  if not First.IsWide and not Second.IsWide then
    Exit(CompareByte(First.FData^, Second.FData^, First.FLength) = 0);
  for Index := 0 to First.FLength - 1 do
    if First.CharAt(Index) <> Second.CharAt(Index) then
      Exit(False);
  Result := True;
end;

function CompareStrings(Heap: TJsHeap; First, Second: TJsString): Integer;
var
  Index, Shorter: Integer;
  A, B: Word;
begin
  First.Flatten(Heap);
  Second.Flatten(Heap);
  Shorter := First.FLength;
  if Second.FLength < Shorter then
    Shorter := Second.FLength;
  for Index := 0 to Shorter - 1 do
  begin
    A := First.CharAt(Index);
    B := Second.CharAt(Index);
    if A <> B then
      Exit(Integer(A) - Integer(B));
  end;
  Result := First.FLength - Second.FLength;
end;

function StringRegionEquals(Text: TJsString; Offset: Integer; Pattern: TJsString): Boolean;
var
  Index: Integer;
begin
  if (Offset < 0) or (Offset + Pattern.FLength > Text.FLength) then
    Exit(False);
  for Index := 0 to Pattern.FLength - 1 do
    if Text.CharAt(Offset + Index) <> Pattern.CharAt(Index) then
      Exit(False);
  Result := True;
end;

function StringIndexOf(Text, Pattern: TJsString; Start: Integer): Integer;
var
  Position, Last: Integer;
  First: Word;
begin
  if Start < 0 then
    Start := 0;
  if Pattern.FLength = 0 then
  begin
    if Start > Text.FLength then
      Exit(Text.FLength);
    Exit(Start);
  end;
  Last := Text.FLength - Pattern.FLength;
  First := Pattern.CharAt(0);
  for Position := Start to Last do
    if (Text.CharAt(Position) = First) and StringRegionEquals(Text, Position, Pattern) then
      Exit(Position);
  Result := -1;
end;

function StringLastIndexOf(Text, Pattern: TJsString; Start: Integer): Integer;
var
  Position: Integer;
begin
  Position := Text.FLength - Pattern.FLength;
  if Start < Position then
    Position := Start;
  while Position >= 0 do
  begin
    if StringRegionEquals(Text, Position, Pattern) then
      Exit(Position);
    Dec(Position);
  end;
  Result := -1;
end;

function StringEqualsAscii(Text: TJsString; const Ascii: string): Boolean;
var
  Index: Integer;
begin
  if Text.FLength <> System.Length(Ascii) then
    Exit(False);
  for Index := 0 to Text.FLength - 1 do
    if Text.CharAt(Index) <> Byte(Ascii[Index + 1]) then
      Exit(False);
  Result := True;
end;

end.
