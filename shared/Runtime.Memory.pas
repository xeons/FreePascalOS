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
  Portable memory block operations shared by the loader and the kernel.

  These are written in plain Pascal so they compile unchanged for every
  target and calling convention. When both addresses are 8-byte aligned the
  bulk of the work is done a QWord at a time.

  Loops over unsigned counts are written as while loops on purpose: a
  "for Index := 0 to Count - 1" loop with an unsigned Count of zero wraps
  around to a huge upper bound instead of running zero times.
}
unit Runtime.Memory;

{$mode objfpc}
{$pointermath on}

interface

procedure FillMemory(Destination: Pointer; ByteCount: PtrUInt; Value: Byte);
procedure ZeroMemory(Destination: Pointer; ByteCount: PtrUInt);
procedure CopyMemory(Destination: Pointer; Source: Pointer; ByteCount: PtrUInt);

{ Copies correctly even when the two blocks overlap. }
procedure MoveMemory(Destination: Pointer; Source: Pointer; ByteCount: PtrUInt);

function MemoryIsEqual(First: Pointer; Second: Pointer; ByteCount: PtrUInt): Boolean;

implementation

const
  QWordSize = SizeOf(QWord);

function IsQWordAligned(Address: Pointer): Boolean;
begin
  Result := (PtrUInt(Address) and (QWordSize - 1)) = 0;
end;

procedure FillMemory(Destination: Pointer; ByteCount: PtrUInt; Value: Byte);
var
  DestinationBytes: PByte;
  DestinationQWords: PQWord;
  PatternQWord: QWord;
  QWordCount: PtrUInt;
  Index: PtrUInt;
begin
  DestinationBytes := PByte(Destination);

  if IsQWordAligned(Destination) then
  begin
    PatternQWord := QWord(Value) * QWord($0101010101010101);
    DestinationQWords := PQWord(Destination);
    QWordCount := ByteCount div QWordSize;
    Index := 0;
    while Index < QWordCount do
    begin
      DestinationQWords[Index] := PatternQWord;
      Inc(Index);
    end;

    DestinationBytes := PByte(DestinationQWords + QWordCount);
    ByteCount := ByteCount mod QWordSize;
  end;

  Index := 0;
  while Index < ByteCount do
  begin
    DestinationBytes[Index] := Value;
    Inc(Index);
  end;
end;

procedure ZeroMemory(Destination: Pointer; ByteCount: PtrUInt);
begin
  FillMemory(Destination, ByteCount, 0);
end;

procedure CopyMemory(Destination: Pointer; Source: Pointer; ByteCount: PtrUInt);
var
  DestinationBytes: PByte;
  SourceBytes: PByte;
  DestinationQWords: PQWord;
  SourceQWords: PQWord;
  QWordCount: PtrUInt;
  Index: PtrUInt;
begin
  DestinationBytes := PByte(Destination);
  SourceBytes := PByte(Source);

  if IsQWordAligned(Destination) and IsQWordAligned(Source) then
  begin
    DestinationQWords := PQWord(Destination);
    SourceQWords := PQWord(Source);
    QWordCount := ByteCount div QWordSize;
    Index := 0;
    while Index < QWordCount do
    begin
      DestinationQWords[Index] := SourceQWords[Index];
      Inc(Index);
    end;

    DestinationBytes := PByte(DestinationQWords + QWordCount);
    SourceBytes := PByte(SourceQWords + QWordCount);
    ByteCount := ByteCount mod QWordSize;
  end;

  Index := 0;
  while Index < ByteCount do
  begin
    DestinationBytes[Index] := SourceBytes[Index];
    Inc(Index);
  end;
end;

procedure CopyMemoryBackwards(Destination: Pointer; Source: Pointer; ByteCount: PtrUInt);
var
  DestinationBytes: PByte;
  SourceBytes: PByte;
  RemainingBytes: PtrUInt;
begin
  DestinationBytes := PByte(Destination);
  SourceBytes := PByte(Source);
  RemainingBytes := ByteCount;
  while RemainingBytes > 0 do
  begin
    Dec(RemainingBytes);
    DestinationBytes[RemainingBytes] := SourceBytes[RemainingBytes];
  end;
end;

procedure MoveMemory(Destination: Pointer; Source: Pointer; ByteCount: PtrUInt);
var
  DestinationStartsInsideSource: Boolean;
begin
  DestinationStartsInsideSource :=
    (PtrUInt(Destination) > PtrUInt(Source)) and
    (PtrUInt(Destination) < PtrUInt(Source) + ByteCount);

  if DestinationStartsInsideSource then
    CopyMemoryBackwards(Destination, Source, ByteCount)
  else
    CopyMemory(Destination, Source, ByteCount);
end;

function MemoryIsEqual(First: Pointer; Second: Pointer; ByteCount: PtrUInt): Boolean;
var
  FirstBytes: PByte;
  SecondBytes: PByte;
  Index: PtrUInt;
begin
  FirstBytes := PByte(First);
  SecondBytes := PByte(Second);
  Index := 0;
  while Index < ByteCount do
  begin
    if FirstBytes[Index] <> SecondBytes[Index] then
      Exit(False);
    Inc(Index);
  end;
  Result := True;
end;

end.
