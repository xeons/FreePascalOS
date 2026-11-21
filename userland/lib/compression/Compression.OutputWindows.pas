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
  TOutputWindow: the decompressed data of the brotli and zstd decoders,
  kept in a ring as long as later data may copy from it (the sliding
  window) and until the caller has taken it.

  The ring's size is a power of two of at least the window; it starts
  small and doubles as the output grows (Reserve), up to the size Start
  was given, so a small response never takes the whole window a format
  allows. It grows only while it has not wrapped, so growing is one
  reallocation that keeps everything where it is.

  Writes (PutByte, PutBytes, PutRepeated, CopyMatch) need room: Reserve
  first, and never let the bytes not yet delivered exceed the size
  (Space says how many more may be written).
}
unit Compression.OutputWindows;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils;

type
  TOutputWindow = class
  private
    FData: TBytes;
    FCapacity: SizeUInt;
    FMask: SizeUInt;
    FMaximumCapacity: SizeUInt;
    FWritten: QWord;
    FDelivered: QWord;
    procedure Grow(Needed: QWord);
    function GetPending: SizeUInt;
    function GetSpace: SizeUInt;
  public
    { A new stream (or frame) whose window takes at most Maximum bytes
      (rounded up to a power of two). Nothing may be pending. }
    procedure Start(Maximum: SizeUInt);
    { Makes room for Count more bytes. }
    procedure Reserve(Count: SizeUInt);
    procedure PutByte(Value: Byte); inline;
    procedure PutBytes(Source: PByte; Count: SizeUInt);
    procedure PutRepeated(Value: Byte; Count: SizeUInt);
    { Copies Count bytes from Distance back (1 to Written); the copy may
      overlap what it writes. }
    procedure CopyMatch(Distance: SizeUInt; Count: SizeUInt);
    { Where the next bytes go, for writing them in place: at most Count,
      as far as the ring does not wrap (Available). Advance afterwards. }
    function WriteRegion(Count: SizeUInt; out Available: SizeUInt): PByte;
    procedure Advance(Count: SizeUInt);
    { The byte Distance back (1 or more); 0 before the start. }
    function ByteBack(Distance: SizeUInt): Byte;
    { Copies up to Capacity pending bytes to Output; the count. }
    function Deliver(Output: PByte; Capacity: SizeUInt): SizeUInt;
    { The ring holding Count bytes written from total position First on:
      one part, or two when they wrap. }
    procedure WrittenParts(First: QWord; Count: SizeUInt; out Part1: PByte; out Count1: SizeUInt;
      out Part2: PByte; out Count2: SizeUInt);

    { Bytes written since Start. }
    property Written: QWord read FWritten;
    property Pending: SizeUInt read GetPending;
    { How many more bytes fit before undelivered ones would be lost. }
    property Space: SizeUInt read GetSpace;
    property MaximumCapacity: SizeUInt read FMaximumCapacity;
  end;

implementation

const
  SmallestCapacity = 64 * 1024;

function RoundUpToPowerOfTwo(Value: QWord): QWord;
begin
  Result := 1;
  while Result < Value do
    Result := Result shl 1;
end;

procedure TOutputWindow.Start(Maximum: SizeUInt);
begin
  FMaximumCapacity := RoundUpToPowerOfTwo(Maximum);
  if FMaximumCapacity < 64 then
    FMaximumCapacity := 64;
  FWritten := 0;
  FDelivered := 0;
  { Keep a ring from an earlier stream if it is not too large. }
  if FCapacity > FMaximumCapacity then
  begin
    FData := nil;
    FCapacity := 0;
  end;
  if FCapacity = 0 then
  begin
    FCapacity := SmallestCapacity;
    if FCapacity > FMaximumCapacity then
      FCapacity := FMaximumCapacity;
    SetLength(FData, FCapacity);
  end;
  FMask := FCapacity - 1;
end;

procedure TOutputWindow.Grow(Needed: QWord);
var
  NewCapacity: QWord;
begin
  NewCapacity := RoundUpToPowerOfTwo(Needed);
  if NewCapacity > FMaximumCapacity then
    NewCapacity := FMaximumCapacity;
  if NewCapacity <= FCapacity then
    Exit;
  SetLength(FData, NewCapacity);
  FCapacity := NewCapacity;
  FMask := FCapacity - 1;
end;

procedure TOutputWindow.Reserve(Count: SizeUInt);
begin
  { Below the largest size the ring has never wrapped. }
  if (FCapacity < FMaximumCapacity) and (FWritten + Count > FCapacity) then
    Grow(FWritten + Count);
end;

function TOutputWindow.GetPending: SizeUInt;
begin
  Result := FWritten - FDelivered;
end;

function TOutputWindow.GetSpace: SizeUInt;
begin
  Result := FMaximumCapacity - (FWritten - FDelivered);
end;

procedure TOutputWindow.PutByte(Value: Byte);
begin
  FData[FWritten and FMask] := Value;
  Inc(FWritten);
end;

procedure TOutputWindow.PutBytes(Source: PByte; Count: SizeUInt);
var
  Index: SizeUInt;
  Chunk: SizeUInt;
begin
  while Count > 0 do
  begin
    Index := FWritten and FMask;
    Chunk := FCapacity - Index;
    if Chunk > Count then
      Chunk := Count;
    Move(Source^, FData[Index], Chunk);
    Inc(Source, Chunk);
    Inc(FWritten, Chunk);
    Dec(Count, Chunk);
  end;
end;

procedure TOutputWindow.PutRepeated(Value: Byte; Count: SizeUInt);
var
  Index: SizeUInt;
  Chunk: SizeUInt;
begin
  while Count > 0 do
  begin
    Index := FWritten and FMask;
    Chunk := FCapacity - Index;
    if Chunk > Count then
      Chunk := Count;
    FillChar(FData[Index], Chunk, Value);
    Inc(FWritten, Chunk);
    Dec(Count, Chunk);
  end;
end;

procedure TOutputWindow.CopyMatch(Distance: SizeUInt; Count: SizeUInt);
var
  Data: PByte;
  Source: SizeUInt;
  Target: SizeUInt;
  Chunk: SizeUInt;
  Index: SizeUInt;
begin
  Data := @FData[0];
  if Distance = 1 then
  begin
    PutRepeated(Data[(FWritten - 1) and FMask], Count);
    Exit;
  end;
  while Count > 0 do
  begin
    Source := (FWritten - Distance) and FMask;
    Target := FWritten and FMask;
    { As far as neither end wraps. }
    Chunk := Count;
    if Chunk > FCapacity - Source then
      Chunk := FCapacity - Source;
    if Chunk > FCapacity - Target then
      Chunk := FCapacity - Target;
    if Chunk <= Distance then
      Move(Data[Source], Data[Target], Chunk)
    else
    begin
      { The copy reads what it writes: byte by byte. }
      Index := 0;
      while Index < Chunk do
      begin
        Data[Target + Index] := Data[Source + Index];
        Inc(Index);
      end;
    end;
    Inc(FWritten, Chunk);
    Dec(Count, Chunk);
  end;
end;

function TOutputWindow.WriteRegion(Count: SizeUInt; out Available: SizeUInt): PByte;
var
  Index: SizeUInt;
begin
  Index := FWritten and FMask;
  Available := FCapacity - Index;
  if Available > Count then
    Available := Count;
  Result := @FData[Index];
end;

procedure TOutputWindow.Advance(Count: SizeUInt);
begin
  Inc(FWritten, Count);
end;

function TOutputWindow.ByteBack(Distance: SizeUInt): Byte;
begin
  if Distance > FWritten then
    Result := 0
  else
    Result := FData[(FWritten - Distance) and FMask];
end;

function TOutputWindow.Deliver(Output: PByte; Capacity: SizeUInt): SizeUInt;
var
  Index: SizeUInt;
  Chunk: SizeUInt;
  Remaining: SizeUInt;
begin
  Result := 0;
  Remaining := Pending;
  if Remaining > Capacity then
    Remaining := Capacity;
  while Remaining > 0 do
  begin
    Index := FDelivered and FMask;
    Chunk := FCapacity - Index;
    if Chunk > Remaining then
      Chunk := Remaining;
    Move(FData[Index], Output[Result], Chunk);
    Inc(FDelivered, Chunk);
    Inc(Result, Chunk);
    Dec(Remaining, Chunk);
  end;
end;

procedure TOutputWindow.WrittenParts(First: QWord; Count: SizeUInt; out Part1: PByte; out Count1: SizeUInt;
  out Part2: PByte; out Count2: SizeUInt);
var
  Index: SizeUInt;
begin
  Index := First and FMask;
  Part1 := @FData[Index];
  Count1 := Count;
  Part2 := nil;
  Count2 := 0;
  if Index + Count > FCapacity then
  begin
    Count1 := FCapacity - Index;
    Part2 := @FData[0];
    Count2 := Count - Count1;
  end;
end;

end.
