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

{ WebIpcTest: messages in pieces (WebIpc.Fragments). }
unit WebIpcTest.Fragments;

{$mode objfpc}
{$H+}

interface

procedure RunFragmentChecks;

implementation

uses
  SysUtils,
  TestChecks,
  WebIpc.Wire,
  WebIpc.Messages,
  WebIpc.Fragments;

function Pattern(Count: Integer): TBytes;
var
  Index: Integer;
begin
  Result := nil;
  SetLength(Result, Count);
  for Index := 0 to Count - 1 do
    Result[Index] := Byte((Index * 7 + Index shr 8) and $FF);
end;

function SameBytes(const A, B: TBytes): Boolean;
begin
  Result := (Length(A) = Length(B)) and ((Length(A) = 0) or CompareMem(@A[0], @B[0], Length(A)));
end;

procedure CheckRoundTrip(Count: Integer; ExpectedPieces: Integer);
var
  Payload: TBytes;
  Pieces: TFragmentList;
  Joiner: TIpcReassembler;
  Message: TIpcMessage;
  Index, Largest: Integer;
  NoneEarly: Boolean;
begin
  Payload := Pattern(Count);
  Pieces := SplitMessage(IpcHopData, 7, 42, Payload);
  Largest := 0;
  for Index := 0 to High(Pieces) do
    if Length(Pieces[Index]) > Largest then
      Largest := Length(Pieces[Index]);
  Check(Length(Pieces) = ExpectedPieces, Format('pieces: %d bytes go in %d pieces', [Count, ExpectedPieces]));
  Check(Largest <= ChannelMessageLimit, Format('pieces: %d bytes, no piece over the channel limit', [Count]));
  Joiner := TIpcReassembler.Create;
  try
    NoneEarly := True;
    Message := nil;
    for Index := 0 to High(Pieces) do
    begin
      Message := Joiner.Feed(Pieces[Index], []);
      if (Message <> nil) and (Index < High(Pieces)) then
        NoneEarly := False;
    end;
    Check(NoneEarly and (Message <> nil), Format('pieces: %d bytes joined only at the last piece', [Count]));
    if Message <> nil then
    begin
      Check((Message.Kind = IpcHopData) and (Message.ViewId = 7) and (Message.RequestId = 42),
        Format('pieces: %d bytes keep kind, view and request', [Count]));
      Check(SameBytes(Message.Payload, Payload), Format('pieces: %d bytes come back the same', [Count]));
      Message.Free;
    end;
    Check(not Joiner.Busy, Format('pieces: %d bytes leave nothing half joined', [Count]));
  finally
    Joiner.Free;
  end;
end;

procedure CheckHandlesOnFirstPiece;
var
  Pieces: TFragmentList;
  Joiner: TIpcReassembler;
  Message: TIpcMessage;
begin
  Pieces := SplitMessage(IpcSurfaceCreated, 3, 0, Pattern(FragmentPayloadLimit + 10));
  Joiner := TIpcReassembler.Create;
  try
    Message := Joiner.Feed(Pieces[0], [41, 42]);
    Check(Message = nil, 'handles: the first piece alone is not a message');
    Message := Joiner.Feed(Pieces[1], []);
    Check((Message <> nil) and (Length(Message.Handles) = 2) and (Message.Handles[0] = 41) and
      (Message.Handles[1] = 42), 'handles: come with the message, from its first piece');
    Message.Free;
  finally
    Joiner.Free;
  end;
end;

function FeedingFails(const First, Second: TBytes; SecondHandles: Boolean): Boolean;
var
  Joiner: TIpcReassembler;
  Message: TIpcMessage;
begin
  Result := False;
  Joiner := TIpcReassembler.Create;
  try
    try
      if Length(First) > 0 then
      begin
        Message := Joiner.Feed(First, []);
        Message.Free;
      end;
      if SecondHandles then
        Message := Joiner.Feed(Second, [5])
      else
        Message := Joiner.Feed(Second, []);
      Message.Free;
    except
      on EIpcMalformed do
        Result := True;
    end;
  finally
    Joiner.Free;
  end;
end;

procedure CheckMisfitsRefused;
var
  Long, Other: TFragmentList;
  Short, Tampered: TBytes;
begin
  Long := SplitMessage(IpcHopData, 1, 0, Pattern(FragmentPayloadLimit * 2));
  Other := SplitMessage(IpcHopHead, 1, 0, Pattern(FragmentPayloadLimit * 2));
  Check(FeedingFails(nil, Long[1], False), 'misfits: a later piece without a first is refused');
  Check(FeedingFails(Long[0], Other[0], False), 'misfits: a message beginning before the last ended is refused');
  Check(FeedingFails(Long[0], Other[1], False), 'misfits: a piece of another message is refused');
  Check(FeedingFails(Long[0], Long[1], True), 'misfits: handles on a later piece are refused');
  Short := nil;
  SetLength(Short, FragmentHeaderSize - 1);
  Check(FeedingFails(nil, Short, False), 'misfits: a piece shorter than its header is refused');
  { A single piece claiming more than it carries. }
  Tampered := Copy(SplitMessage(IpcPing, 0, 0, Pattern(10))[0]);
  StoreLongWord(@Tampered[12], 11);
  Check(FeedingFails(nil, Tampered, False), 'misfits: a message shorter than it says is refused');
  Tampered := Copy(SplitMessage(IpcPing, 0, 0, Pattern(10))[0]);
  StoreLongWord(@Tampered[12], 9);
  Check(FeedingFails(nil, Tampered, False), 'misfits: a message longer than it says is refused');
  StoreLongWord(@Tampered[12], MessagePayloadLimit + 1);
  Check(FeedingFails(nil, Tampered, False), 'misfits: a message over the size limit is refused');
end;

procedure RunFragmentChecks;
begin
  CheckRoundTrip(0, 1);
  CheckRoundTrip(1, 1);
  CheckRoundTrip(FragmentPayloadLimit - 1, 1);
  CheckRoundTrip(FragmentPayloadLimit, 1);
  CheckRoundTrip(FragmentPayloadLimit + 1, 2);
  CheckRoundTrip(3 * FragmentPayloadLimit + 5, 4);
  CheckRoundTrip(1024 * 1024, (1024 * 1024 + FragmentPayloadLimit - 1) div FragmentPayloadLimit);
  CheckHandlesOnFirstPiece;
  CheckMisfitsRefused;
end;

end.
