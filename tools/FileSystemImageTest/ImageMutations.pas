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
  Random damage to disk images, for FileSystemImageTest --fuzz. A seed
  and an iteration number give the same damage every time, so a failure
  can be run again on its own.

  Most damage goes to bytes that are not zero in the undamaged image:
  the test images keep their file contents zero, so those are the
  metadata (boot sectors, superblocks, descriptors, allocation tables,
  inodes, directories). Some goes to the first 64 KiB, the rest anywhere.
}
unit ImageMutations;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

type
  TMutationGenerator = record
    State: QWord;
    { Offsets of the bytes that are not zero in the undamaged image. }
    Targets: array of LongWord;
  end;

{ Notes where Image holds something (call once, before the first
  StartMutations). }
procedure ChooseTargets(var Generator: TMutationGenerator; const Image: TBytes);
procedure StartMutations(var Generator: TMutationGenerator; Seed: LongWord; Iteration: Integer);
procedure DamageImage(var Generator: TMutationGenerator; var Image: TBytes);

implementation

const
  HotAreaBytes = 64 * 1024;

{$push}{$Q-}{$R-}
function NextRandom(var Generator: TMutationGenerator): QWord;
begin
  { xorshift64* }
  Generator.State := Generator.State xor (Generator.State shr 12);
  Generator.State := Generator.State xor (Generator.State shl 25);
  Generator.State := Generator.State xor (Generator.State shr 27);
  Result := Generator.State * QWord($2545F4914F6CDD1D);
end;

procedure StartMutations(var Generator: TMutationGenerator; Seed: LongWord; Iteration: Integer);
begin
  Generator.State := (QWord(Seed) shl 32) xor QWord(Iteration) xor QWord($9E3779B97F4A7C15);
  NextRandom(Generator);
end;
{$pop}

function RandomBelow(var Generator: TMutationGenerator; Limit: QWord): QWord;
begin
  Result := NextRandom(Generator) mod Limit;
end;

procedure ChooseTargets(var Generator: TMutationGenerator; const Image: TBytes);
var
  Index: LongWord;
  Count: LongWord;
begin
  SetLength(Generator.Targets, Length(Image));
  Count := 0;
  Index := 0;
  while Index < LongWord(Length(Image)) do
  begin
    if Image[Index] <> 0 then
    begin
      Generator.Targets[Count] := Index;
      Inc(Count);
    end;
    Inc(Index);
  end;
  SetLength(Generator.Targets, Count);
end;

function PickOffset(var Generator: TMutationGenerator; Size: QWord): QWord;
var
  Choice: QWord;
begin
  Choice := RandomBelow(Generator, 10);
  if (Choice < 7) and (Length(Generator.Targets) > 0) then
    { Near a byte that holds something: 0-3 bytes before it, so a field
      around it may change as a whole. }
    Result := Generator.Targets[RandomBelow(Generator, Length(Generator.Targets))] -
      RandomBelow(Generator, 4)
  else if (Choice < 9) and (Size > HotAreaBytes) then
    Result := RandomBelow(Generator, HotAreaBytes)
  else
    Result := RandomBelow(Generator, Size);
  if Result >= Size then
    Result := 0;
end;

procedure StoreWord(var Image: TBytes; Offset: QWord; Value: QWord; ByteCount: Integer);
var
  Index: Integer;
begin
  for Index := 0 to ByteCount - 1 do
    if Offset + QWord(Index) < QWord(Length(Image)) then
      Image[Offset + QWord(Index)] := Byte(Value shr (8 * Index));
end;

procedure DamageOnce(var Generator: TMutationGenerator; var Image: TBytes);
const
  Extremes: array[0..5] of QWord = (0, 1, $7F, $FFFF, $FFFFFFFF, QWord($FFFFFFFFFFFFFFFF));
var
  Offset: QWord;
  Size: QWord;
  RunLength: QWord;
begin
  Size := Length(Image);
  Offset := PickOffset(Generator, Size);
  case RandomBelow(Generator, 5) of
    0: Image[Offset] := Byte(NextRandom(Generator));
    1: Image[Offset] := Image[Offset] xor Byte(1 shl RandomBelow(Generator, 8));
    2: StoreWord(Image, Offset and not QWord(1), Extremes[RandomBelow(Generator, Length(Extremes))], 2);
    3: StoreWord(Image, Offset and not QWord(3), Extremes[RandomBelow(Generator, Length(Extremes))], 4);
  else
    begin
      RunLength := 1 + RandomBelow(Generator, 64);
      while (RunLength > 0) and (Offset < Size) do
      begin
        Image[Offset] := 0;
        Inc(Offset);
        Dec(RunLength);
      end;
    end;
  end;
end;

procedure DamageImage(var Generator: TMutationGenerator; var Image: TBytes);
var
  Count: QWord;
begin
  if Length(Image) = 0 then
    Exit;
  Count := 1 + RandomBelow(Generator, 12);
  while Count > 0 do
  begin
    DamageOnce(Generator, Image);
    Dec(Count);
  end;
end;

end.
