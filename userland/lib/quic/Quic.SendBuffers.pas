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
  The sending side of a stream or of a CRYPTO stream: the bytes written
  and not yet acknowledged, from Base (everything before it was
  acknowledged) to WriteOffset; how far they have been sent once
  (SentOffset); which ranges came back acknowledged and which were
  declared lost and wait to go again; and the FIN.

  Next hands out what to put in a frame: lost ranges first, then new
  bytes up to the flow control limit, then a FIN on its own. Bytes stay
  until they are acknowledged; the buffer holds at most Limit bytes
  (writers wait for acknowledgements to make room). Memory grows with
  what is held, never past Limit.
}
unit Quic.SendBuffers;

{$mode objfpc}
{$modeswitch advancedrecords}
{$pointermath on}

interface

uses
  Quic.RangeSets;

type
  TQuicSendBuffer = record
    Data: array of Byte;
    Base: QWord;
    Held: PtrUInt;
    Limit: PtrUInt;
    SentOffset: QWord;
    Acknowledged: TQuicRangeSet;
    Lost: TQuicRangeSet;
    FinQueued: Boolean;
    FinSent: Boolean;
    FinLost: Boolean;
    FinAcknowledged: Boolean;
    procedure Initialize(MaximumHeld: PtrUInt);
    procedure Release;
    function WriteOffset: QWord;
    function Room: PtrUInt;
    { Takes up to Count bytes (as many as there is room for). }
    function Append(Source: PByte; Count: PtrUInt): PtrUInt;
    procedure QueueFin;
    { Something to send: lost bytes, new bytes below FlowLimit, a FIN. }
    function HasPending(FlowLimit: QWord): Boolean;
    { The next frame's worth: at most MaximumLength bytes (new bytes
      also below FlowLimit). False when there is nothing. }
    function Next(MaximumLength, FlowLimit: QWord; out Offset, Count: QWord; out Fin: Boolean): Boolean;
    procedure Copy(Offset: QWord; Count: PtrUInt; Destination: PByte);
    procedure OnAcknowledged(Offset, Count: QWord; Fin: Boolean);
    procedure OnLost(Offset, Count: QWord; Fin: Boolean);
    { Everything written, the FIN included, was acknowledged. }
    function AllAcknowledged: Boolean;
    { Nothing is waiting to be (re)sent or acknowledged. }
    function Idle: Boolean;
  end;

implementation

procedure TQuicSendBuffer.Initialize(MaximumHeld: PtrUInt);
begin
  Self := Default(TQuicSendBuffer);
  Limit := MaximumHeld;
  Acknowledged.MaximumRanges := 0;
  Lost.MaximumRanges := 0;
end;

procedure TQuicSendBuffer.Release;
begin
  Data := nil;
  Acknowledged.Ranges := nil;
  Acknowledged.Count := 0;
  Lost.Ranges := nil;
  Lost.Count := 0;
  Held := 0;
end;

function TQuicSendBuffer.WriteOffset: QWord;
begin
  Result := Base + Held;
end;

function TQuicSendBuffer.Room: PtrUInt;
begin
  if FinQueued or (Held >= Limit) then
    Exit(0);
  Result := Limit - Held;
end;

function TQuicSendBuffer.Append(Source: PByte; Count: PtrUInt): PtrUInt;
var
  Capacity: PtrUInt;
begin
  if Count > Room then
    Count := Room;
  if Count = 0 then
    Exit(0);
  if Held + Count > PtrUInt(Length(Data)) then
  begin
    Capacity := Length(Data) * 2;
    if Capacity < 4096 then
      Capacity := 4096;
    while Capacity < Held + Count do
      Capacity := Capacity * 2;
    if Capacity > Limit then
      Capacity := Limit;
    SetLength(Data, Capacity);
  end;
  Move(Source^, Data[Held], Count);
  Held := Held + Count;
  Result := Count;
end;

procedure TQuicSendBuffer.QueueFin;
begin
  FinQueued := True;
end;

function TQuicSendBuffer.HasPending(FlowLimit: QWord): Boolean;
begin
  if not Lost.IsEmpty then
    Exit(True);
  if (SentOffset < WriteOffset) and (SentOffset < FlowLimit) then
    Exit(True);
  Result := FinQueued and not FinAcknowledged and (SentOffset = WriteOffset) and (not FinSent or FinLost);
end;

function TQuicSendBuffer.Next(MaximumLength, FlowLimit: QWord; out Offset, Count: QWord; out Fin: Boolean): Boolean;
var
  Range: TQuicRange;
  Finish: QWord;
begin
  Offset := 0;
  Count := 0;
  Fin := False;
  if Lost.TakeLowest(MaximumLength, Range) then
  begin
    Offset := Range.Start;
    Count := Range.Finish - Range.Start;
    Fin := FinQueued and (Range.Finish = WriteOffset) and not FinAcknowledged;
    if Fin then
      FinLost := False;
    Exit(True);
  end;
  if (SentOffset < WriteOffset) and (SentOffset < FlowLimit) and (MaximumLength > 0) then
  begin
    Finish := WriteOffset;
    if Finish > FlowLimit then
      Finish := FlowLimit;
    if Finish - SentOffset > MaximumLength then
      Finish := SentOffset + MaximumLength;
    Offset := SentOffset;
    Count := Finish - SentOffset;
    SentOffset := Finish;
    Fin := FinQueued and (SentOffset = WriteOffset);
    if Fin then
    begin
      FinSent := True;
      FinLost := False;
    end;
    Exit(True);
  end;
  if FinQueued and not FinAcknowledged and (SentOffset = WriteOffset) and (not FinSent or FinLost) then
  begin
    Offset := WriteOffset;
    Fin := True;
    FinSent := True;
    FinLost := False;
    Exit(True);
  end;
  Result := False;
end;

procedure TQuicSendBuffer.Copy(Offset: QWord; Count: PtrUInt; Destination: PByte);
begin
  if Count > 0 then
    Move(Data[PtrUInt(Offset - Base)], Destination^, Count);
end;

procedure TQuicSendBuffer.OnAcknowledged(Offset, Count: QWord; Fin: Boolean);
var
  NewBase, Released: QWord;
begin
  if Fin then
    FinAcknowledged := True;
  if Count = 0 then
    Exit;
  if Offset + Count <= Base then
    Exit;
  if Offset < Base then
  begin
    Count := Offset + Count - Base;
    Offset := Base;
  end;
  Acknowledged.Add(Offset, Offset + Count);
  Lost.Remove(Offset, Offset + Count);
  NewBase := Acknowledged.ContiguousEnd(Base);
  if NewBase > Base then
  begin
    Released := NewBase - Base;
    if Released < Held then
      Move(Data[PtrUInt(Released)], Data[0], Held - PtrUInt(Released));
    Held := Held - PtrUInt(Released);
    Base := NewBase;
    Acknowledged.Remove(0, NewBase);
    { Give back memory once a large buffer has drained. }
    if (Held = 0) and (Length(Data) > 65536) then
      Data := nil;
  end;
end;

procedure TQuicSendBuffer.OnLost(Offset, Count: QWord; Fin: Boolean);
var
  Index: Integer;
  Finish: QWord;
begin
  if Fin and not FinAcknowledged then
    FinLost := True;
  Finish := Offset + Count;
  if Offset < Base then
    Offset := Base;
  if Finish <= Offset then
    Exit;
  Lost.Add(Offset, Finish);
  for Index := Acknowledged.Count - 1 downto 0 do
    Lost.Remove(Acknowledged.Ranges[Index].Start, Acknowledged.Ranges[Index].Finish);
end;

function TQuicSendBuffer.AllAcknowledged: Boolean;
begin
  Result := FinQueued and FinAcknowledged and (Held = 0);
end;

function TQuicSendBuffer.Idle: Boolean;
begin
  Result := (Held = 0) and Lost.IsEmpty and (not FinQueued or FinAcknowledged);
end;

end.
