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
  The receiving side of a stream or of a CRYPTO stream: bytes arrive at
  any offset, in any order, possibly more than once, and are put
  together in a ring buffer from ReadOffset on; Available says how many
  bytes in a row are there to read. The ring grows as data comes, up to
  Limit bytes beyond ReadOffset (the flow control window, which the
  sender may not exceed: Insert refuses more).

  The final size (RFC 9000 section 4.5) comes with a FIN (or a
  RESET_STREAM); data beyond it, or a different final size later, is a
  FINAL_SIZE_ERROR.
}
unit Quic.ReceiveBuffers;

{$mode objfpc}
{$modeswitch advancedrecords}
{$pointermath on}

interface

uses
  Quic.RangeSets;

type
  TQuicInsertResult = (InsertAccepted, InsertBeyondLimit, InsertFinalSizeError);

  TQuicReceiveBuffer = record
    Data: array of Byte;
    ReadOffset: QWord;
    Received: TQuicRangeSet;
    HighestOffset: QWord;
    FinalSize: QWord;
    FinalSizeKnown: Boolean;
    Limit: PtrUInt;
    procedure Initialize(Window: PtrUInt);
    procedure Release;
    function Insert(Offset: QWord; Source: PByte; Count: QWord; Fin: Boolean): TQuicInsertResult;
    { Notes the final size of a reset stream. }
    function SetFinalSize(Size: QWord): TQuicInsertResult;
    function Available: QWord;
    function Read(Destination: PByte; Count: PtrUInt): PtrUInt;
    { Everything up to the final size was read. }
    function Finished: Boolean;
  end;

implementation

procedure TQuicReceiveBuffer.Initialize(Window: PtrUInt);
begin
  Self := Default(TQuicReceiveBuffer);
  Limit := Window;
  Received.MaximumRanges := 0;
end;

procedure TQuicReceiveBuffer.Release;
begin
  Data := nil;
  Received.Ranges := nil;
  Received.Count := 0;
end;

{ Makes the ring at least Needed bytes, keeping the bytes from
  ReadOffset to HighestOffset at their new places. }
procedure GrowRing(var Buffer: TQuicReceiveBuffer; Needed: PtrUInt);
var
  NewData: array of Byte;
  Capacity, OldCapacity: PtrUInt;
  Offset: QWord;
begin
  OldCapacity := Length(Buffer.Data);
  Capacity := OldCapacity;
  if Capacity < 4096 then
    Capacity := 4096;
  while Capacity < Needed do
    Capacity := Capacity * 2;
  if Capacity = OldCapacity then
    Exit;
  NewData := nil;
  SetLength(NewData, Capacity);
  if OldCapacity > 0 then
  begin
    Offset := Buffer.ReadOffset;
    while Offset < Buffer.HighestOffset do
    begin
      NewData[PtrUInt(Offset mod Capacity)] := Buffer.Data[PtrUInt(Offset mod OldCapacity)];
      Inc(Offset);
    end;
  end;
  Buffer.Data := NewData;
end;

function TQuicReceiveBuffer.SetFinalSize(Size: QWord): TQuicInsertResult;
begin
  if FinalSizeKnown and (FinalSize <> Size) then
    Exit(InsertFinalSizeError);
  if HighestOffset > Size then
    Exit(InsertFinalSizeError);
  FinalSize := Size;
  FinalSizeKnown := True;
  Result := InsertAccepted;
end;

function TQuicReceiveBuffer.Insert(Offset: QWord; Source: PByte; Count: QWord; Fin: Boolean): TQuicInsertResult;
var
  Finish, Position: QWord;
  Capacity, Index, First: PtrUInt;
begin
  Finish := Offset + Count;
  if FinalSizeKnown and (Finish > FinalSize) then
    Exit(InsertFinalSizeError);
  if Fin then
  begin
    Result := SetFinalSize(Finish);
    if Result <> InsertAccepted then
      Exit;
  end;
  if Finish <= ReadOffset then
    Exit(InsertAccepted);
  if Finish > ReadOffset + Limit then
    Exit(InsertBeyondLimit);
  if Offset < ReadOffset then
  begin
    Source := Source + (ReadOffset - Offset);
    Offset := ReadOffset;
  end;
  if PtrUInt(Finish - ReadOffset) > PtrUInt(Length(Data)) then
    GrowRing(Self, Finish - ReadOffset);
  Capacity := Length(Data);
  { At most two pieces around the end of the ring. }
  Position := Offset;
  while Position < Finish do
  begin
    Index := Position mod Capacity;
    First := Capacity - Index;
    if First > Finish - Position then
      First := Finish - Position;
    Move(Source^, Data[Index], First);
    Source := Source + First;
    Position := Position + First;
  end;
  Received.Add(Offset, Finish);
  if Finish > HighestOffset then
    HighestOffset := Finish;
  Result := InsertAccepted;
end;

function TQuicReceiveBuffer.Available: QWord;
begin
  Result := Received.ContiguousEnd(ReadOffset) - ReadOffset;
end;

function TQuicReceiveBuffer.Read(Destination: PByte; Count: PtrUInt): PtrUInt;
var
  Capacity, Index, Piece, Done: PtrUInt;
begin
  if Count > Available then
    Count := Available;
  Result := Count;
  if Count = 0 then
    Exit;
  Capacity := Length(Data);
  Done := 0;
  while Done < Count do
  begin
    Index := (ReadOffset + Done) mod Capacity;
    Piece := Capacity - Index;
    if Piece > Count - Done then
      Piece := Count - Done;
    Move(Data[Index], Destination[Done], Piece);
    Done := Done + Piece;
  end;
  ReadOffset := ReadOffset + Count;
  Received.Remove(0, ReadOffset);
end;

function TQuicReceiveBuffer.Finished: Boolean;
begin
  Result := FinalSizeKnown and (ReadOffset >= FinalSize);
end;

end.
