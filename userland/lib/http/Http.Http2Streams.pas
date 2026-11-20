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
  One HTTP/2 stream as the client sees it (RFC 9113 section 5.1): open
  once its HEADERS went, half closed (local) after its END_STREAM went,
  closed when END_STREAM came back too, or at a RST_STREAM. What came
  for it waits here until its exchange takes it: the response head, the
  data (held in a buffer the receive window bounds), the trailers, and
  why it failed. Each stream has an event its exchange sleeps on while
  another thread reads the connection.

  The connection's lock guards every field.

  Plain Pascal (the RTL only), checked on the host by tools/HttpTest.
}
unit Http.Http2Streams;

{$mode objfpc}
{$H+}

interface

uses
  Http.ByteBuffers,
  Http.Connections,
  Http.HeaderFields,
  Http.Results;

type
  THttp2Stream = class
  public
    Id: LongWord;
    Event: PRTLEvent;
    { An exchange sleeps on Event. }
    Waiting: Boolean;
    IsHead: Boolean;
    { The final response head came. }
    HeadReceived: Boolean;
    Head: THttpResponseHeadInfo;
    Trailers: THttpHeaderFieldArray;
    Data: THttpByteBuffer;
    { Data.Data[DataStart..Data.Length - 1] is not taken yet. }
    DataStart: Integer;
    RemoteEnded: Boolean;
    LocalEnded: Boolean;
    { -1 without a content-length. }
    ExpectedLength: Int64;
    ReceivedLength: Int64;
    { What the peer may still send on this stream before a WINDOW_UPDATE. }
    ReceiveWindow: Int64;
    { Bytes taken by the exchange and not yet given back. }
    Unacknowledged: Int64;
    SendWindow: Int64;
    { Reset by either side, or failed with the connection. }
    Failed: Boolean;
    Failure: THttpResult;
    { The exchange let go before the end: what arrives is dropped. }
    Abandoned: Boolean;
    constructor Create(StreamId: LongWord);
    destructor Destroy; override;
    function AvailableData: Integer;
    { Takes up to Count bytes of data into Buffer. }
    function TakeData(Buffer: Pointer; Count: Integer): Integer;
    procedure Fail(constref Reason: THttpResult);
    procedure Wake;
  end;

implementation

constructor THttp2Stream.Create(StreamId: LongWord);
begin
  inherited Create;
  Id := StreamId;
  Event := RTLEventCreate;
  ExpectedLength := -1;
  Head.ContentLength := -1;
end;

destructor THttp2Stream.Destroy;
begin
  RTLEventDestroy(Event);
  inherited Destroy;
end;

function THttp2Stream.AvailableData: Integer;
begin
  Result := Data.Length - DataStart;
end;

function THttp2Stream.TakeData(Buffer: Pointer; Count: Integer): Integer;
begin
  Result := AvailableData;
  if Result > Count then
    Result := Count;
  if Result <= 0 then
    Exit(0);
  Move(Data.Data[DataStart], Buffer^, Result);
  Inc(DataStart, Result);
  if DataStart = Data.Length then
  begin
    { Everything taken: the buffer starts over (its storage kept). }
    DataStart := 0;
    ClearBuffer(Data);
  end
  else if DataStart > Data.Length div 2 then
  begin
    ConsumeBuffer(Data, DataStart);
    DataStart := 0;
  end;
end;

procedure THttp2Stream.Fail(constref Reason: THttpResult);
begin
  if Failed then
    Exit;
  Failed := True;
  Failure := Reason;
end;

procedure THttp2Stream.Wake;
begin
  RTLEventSetEvent(Event);
end;

end.
