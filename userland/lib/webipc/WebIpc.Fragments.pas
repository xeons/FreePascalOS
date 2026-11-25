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
  A protocol message in channel messages. A channel message holds at
  most 16 KiB (Processes.Channels), so a longer payload goes in pieces,
  each with the same 16-byte header:

    0  kind (16 bits)       2  flags (16 bits: first, last)
    4  view id (32 bits)    8  request id (32 bits)
    12 the whole payload's length (32 bits)
    16 this piece of the payload

  The sender writes every piece of a message before any of the next
  (WebIpc.Endpoints holds a lock for it), and a channel keeps its
  order, so the receiver joins pieces in the order they come and never
  sees two messages interleaved. Handles travel with the first piece.
  Plain logic, without system calls: tested on the host (WebIpcTest).
}
unit WebIpc.Fragments;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  WebIpc.Messages;

const
  { What one channel message may hold (Processes.Channels). }
  ChannelMessageLimit = 16384;
  FragmentHeaderSize = 16;
  FragmentPayloadLimit = ChannelMessageLimit - FragmentHeaderSize;
  { The longest payload a receiver accepts (a frame's pixels never go
    through the channel: they are in a shared section). }
  MessagePayloadLimit = 256 * 1024 * 1024;

  FragmentFirst = 1;
  FragmentLast = 2;

type
  TFragmentList = array of TBytes;

{ The channel messages that carry a protocol message. }
function SplitMessage(Kind: Word; ViewId, RequestId: LongWord; const Payload: TBytes): TFragmentList;

type
  { Joins pieces into messages (one per channel: the pieces of a channel
    come in order). }
  TIpcReassembler = class
  private
    FPending: TIpcMessage;
    FFilled: Integer;
  public
    destructor Destroy; override;
    { Takes one channel message (and the handles that came with it).
      Returns the whole message when this was its last piece (the
      caller owns it), else nil. Raises EIpcMalformed for pieces that
      do not fit together. }
    function Feed(const Chunk: TBytes; const Handles: array of Int64): TIpcMessage;
    { A message is half received. }
    function Busy: Boolean;
  end;

implementation

uses
  WebIpc.Wire;

function SplitMessage(Kind: Word; ViewId, RequestId: LongWord; const Payload: TBytes): TFragmentList;
var
  Total, Offset, Piece, Count, Index: Integer;
  Flags: Word;
  Chunk: TBytes;
begin
  Result := nil;
  Total := Length(Payload);
  Count := (Total + FragmentPayloadLimit - 1) div FragmentPayloadLimit;
  if Count = 0 then
    Count := 1;
  SetLength(Result, Count);
  Offset := 0;
  for Index := 0 to Count - 1 do
  begin
    Piece := Total - Offset;
    if Piece > FragmentPayloadLimit then
      Piece := FragmentPayloadLimit;
    Flags := 0;
    if Index = 0 then
      Flags := Flags or FragmentFirst;
    if Index = Count - 1 then
      Flags := Flags or FragmentLast;
    Chunk := nil;
    SetLength(Chunk, FragmentHeaderSize + Piece);
    StoreWord(@Chunk[0], Kind);
    StoreWord(@Chunk[2], Flags);
    StoreLongWord(@Chunk[4], ViewId);
    StoreLongWord(@Chunk[8], RequestId);
    StoreLongWord(@Chunk[12], LongWord(Total));
    if Piece > 0 then
      Move(Payload[Offset], Chunk[FragmentHeaderSize], Piece);
    Result[Index] := Chunk;
    Inc(Offset, Piece);
  end;
end;

destructor TIpcReassembler.Destroy;
var
  Index: Integer;
begin
  if FPending <> nil then
  begin
    { Handles of a message never finished are not anyone's yet. }
    for Index := 0 to High(FPending.Handles) do
      FPending.Handles[Index] := -1;
    FPending.Free;
  end;
  inherited Destroy;
end;

function TIpcReassembler.Busy: Boolean;
begin
  Result := FPending <> nil;
end;

function TIpcReassembler.Feed(const Chunk: TBytes; const Handles: array of Int64): TIpcMessage;
var
  Kind, Flags: Word;
  Total: LongWord;
  Piece, Index: Integer;
begin
  Result := nil;
  if Length(Chunk) < FragmentHeaderSize then
    raise EIpcMalformed.Create('a channel message shorter than its header');
  Kind := LoadWord(@Chunk[0]);
  Flags := LoadWord(@Chunk[2]);
  Total := LoadLongWord(@Chunk[12]);
  Piece := Length(Chunk) - FragmentHeaderSize;
  if (Flags and FragmentFirst) <> 0 then
  begin
    if FPending <> nil then
      raise EIpcMalformed.Create('a message began before the last one ended');
    if Total > MessagePayloadLimit then
      raise EIpcMalformed.Create('a message longer than the limit');
    FPending := TIpcMessage.Create;
    FPending.Kind := Kind;
    FPending.ViewId := LoadLongWord(@Chunk[4]);
    FPending.RequestId := LoadLongWord(@Chunk[8]);
    SetLength(FPending.Payload, Total);
    SetLength(FPending.Handles, Length(Handles));
    for Index := 0 to High(Handles) do
      FPending.Handles[Index] := Handles[Index];
    FFilled := 0;
  end
  else
  begin
    if FPending = nil then
      raise EIpcMalformed.Create('a piece of a message that never began');
    if (Kind <> FPending.Kind) or (Total <> LongWord(Length(FPending.Payload))) then
      raise EIpcMalformed.Create('a piece of another message');
    if Length(Handles) > 0 then
      raise EIpcMalformed.Create('handles on a later piece');
  end;
  if Piece > Length(FPending.Payload) - FFilled then
    raise EIpcMalformed.Create('a message longer than it said');
  if Piece > 0 then
    Move(Chunk[FragmentHeaderSize], FPending.Payload[FFilled], Piece);
  Inc(FFilled, Piece);
  if (Flags and FragmentLast) = 0 then
    Exit;
  if FFilled <> Length(FPending.Payload) then
    raise EIpcMalformed.Create('a message shorter than it said');
  Result := FPending;
  FPending := nil;
end;

end.
