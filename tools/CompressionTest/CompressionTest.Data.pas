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
  The test data of CompressionTest, made by the same generators as in
  make-vectors.py (a linear congruential generator, so both make the
  same bytes), and small helpers for byte arrays.
}
unit CompressionTest.Data;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

type
  TDataKind = (DataText, DataRandom, DataRuns, DataBlocks, DataFar, DataZeros);

  TNumberGenerator = record
    State: QWord;
  end;

procedure StartGenerator(out Generator: TNumberGenerator; Seed: LongWord);
function NextNumber(var Generator: TNumberGenerator): LongWord;

function MakeData(Kind: TDataKind; Size: Integer; Seed: LongWord): TBytes;
function HexToData(Hex: PChar): TBytes;
function SameData(const First: TBytes; const Second: TBytes): Boolean;
function JoinData(const First: TBytes; const Second: TBytes): TBytes;
function SliceData(const Data: TBytes; First: Integer; Count: Integer): TBytes;

implementation

const
  Words: array[0..23] of string = ('the', 'quick', 'brown', 'fox', 'jumps', 'over', 'lazy', 'dog', 'pascal',
    'kernel', 'window', 'deflate', 'huffman', 'block', 'stream', 'of', 'and', 'a', 'compression', 'image',
    'pixel', 'free', 'system', 'user');

procedure StartGenerator(out Generator: TNumberGenerator; Seed: LongWord);
begin
  Generator.State := Seed and $7FFFFFFF;
end;

function NextNumber(var Generator: TNumberGenerator): LongWord;
begin
  Generator.State := (Generator.State * 1103515245 + 12345) and $7FFFFFFF;
  Result := Generator.State shr 16;
end;

procedure AppendText(var Data: TBytes; var Used: Integer; const Text: string);
var
  Index: Integer;
begin
  for Index := 1 to Length(Text) do
  begin
    if Used >= Length(Data) then
      Exit;
    Data[Used] := Ord(Text[Index]);
    Inc(Used);
  end;
end;

function MakeText(Size: Integer; Seed: LongWord): TBytes;
var
  Generator: TNumberGenerator;
  Used: Integer;
begin
  Result := nil;
  SetLength(Result, Size);
  StartGenerator(Generator, Seed);
  Used := 0;
  while Used < Size do
  begin
    AppendText(Result, Used, Words[NextNumber(Generator) mod Length(Words)]);
    if NextNumber(Generator) mod 8 = 0 then
      AppendText(Result, Used, #10)
    else
      AppendText(Result, Used, ' ');
  end;
end;

function MakeRandom(Size: Integer; Seed: LongWord): TBytes;
var
  Generator: TNumberGenerator;
  Index: Integer;
begin
  Result := nil;
  SetLength(Result, Size);
  StartGenerator(Generator, Seed);
  for Index := 0 to Size - 1 do
    Result[Index] := NextNumber(Generator) and $FF;
end;

function MakeRuns(Size: Integer; Seed: LongWord): TBytes;
var
  Generator: TNumberGenerator;
  Used: Integer;
  Value: Byte;
  RunLength: Integer;
begin
  Result := nil;
  SetLength(Result, Size);
  StartGenerator(Generator, Seed);
  Used := 0;
  while Used < Size do
  begin
    Value := NextNumber(Generator) and $FF;
    RunLength := 1 + Integer(NextNumber(Generator) mod 300);
    while (RunLength > 0) and (Used < Size) do
    begin
      Result[Used] := Value;
      Inc(Used);
      Dec(RunLength);
    end;
  end;
end;

function MakeBlocks(Size: Integer; Seed: LongWord): TBytes;
var
  Block: TBytes;
  Used: Integer;
  Repetition: Integer;
  Count: Integer;
begin
  Result := nil;
  SetLength(Result, Size);
  Block := MakeRandom(4096, Seed);
  Used := 0;
  Repetition := 0;
  while Used < Size do
  begin
    Block[(Repetition * 517) mod 4096] := Repetition and $FF;
    Count := 4096;
    if Count > Size - Used then
      Count := Size - Used;
    Move(Block[0], Result[Used], Count);
    Inc(Used, Count);
    Inc(Repetition);
  end;
end;

function MakeFar(Size: Integer; Seed: LongWord): TBytes;
var
  Chunk: TBytes;
  Used: Integer;
  Count: Integer;
begin
  Result := nil;
  SetLength(Result, Size);
  Chunk := MakeText(32768, Seed);
  Used := 0;
  while Used < Size do
  begin
    Count := Length(Chunk);
    if Count > Size - Used then
      Count := Size - Used;
    Move(Chunk[0], Result[Used], Count);
    Inc(Used, Count);
  end;
end;

function MakeData(Kind: TDataKind; Size: Integer; Seed: LongWord): TBytes;
begin
  case Kind of
    DataText: Result := MakeText(Size, Seed);
    DataRandom: Result := MakeRandom(Size, Seed);
    DataRuns: Result := MakeRuns(Size, Seed);
    DataBlocks: Result := MakeBlocks(Size, Seed);
    DataFar: Result := MakeFar(Size, Seed);
  else
    begin
      Result := nil;
      SetLength(Result, Size);
      if Size > 0 then
        FillChar(Result[0], Size, 0);
    end;
  end;
end;

function HexDigitValue(Character: Char): Integer;
begin
  case Character of
    '0'..'9': Result := Ord(Character) - Ord('0');
    'a'..'f': Result := Ord(Character) - Ord('a') + 10;
    'A'..'F': Result := Ord(Character) - Ord('A') + 10;
  else
    Result := 0;
  end;
end;

function HexToData(Hex: PChar): TBytes;
var
  Count: Integer;
  Index: Integer;
begin
  Result := nil;
  Count := StrLen(Hex) div 2;
  SetLength(Result, Count);
  for Index := 0 to Count - 1 do
    Result[Index] := HexDigitValue(Hex[2 * Index]) * 16 + HexDigitValue(Hex[2 * Index + 1]);
end;

function SameData(const First: TBytes; const Second: TBytes): Boolean;
begin
  Result := (Length(First) = Length(Second)) and
    ((Length(First) = 0) or CompareMem(@First[0], @Second[0], Length(First)));
end;

function JoinData(const First: TBytes; const Second: TBytes): TBytes;
begin
  Result := nil;
  SetLength(Result, Length(First) + Length(Second));
  if Length(First) > 0 then
    Move(First[0], Result[0], Length(First));
  if Length(Second) > 0 then
    Move(Second[0], Result[Length(First)], Length(Second));
end;

function SliceData(const Data: TBytes; First: Integer; Count: Integer): TBytes;
begin
  Result := nil;
  SetLength(Result, Count);
  if Count > 0 then
    Move(Data[First], Result[0], Count);
end;

end.
