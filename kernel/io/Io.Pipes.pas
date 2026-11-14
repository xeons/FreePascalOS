{
  Pipes: one-way byte channels between processes.

  A pipe is a fixed size ring buffer with a read end and a write end.
  Reading waits until data arrives and returns end of file (zero bytes)
  once every write end is closed and the buffer is empty. Writing waits
  for room and fails with "broken pipe" once every read end is closed.

  Ends are counted separately from object references (handles call
  OpenPipeEnd/ClosePipeEnd), so end of file is detected even while the
  pipe object itself is still referenced.
}
unit Io.Pipes;

{$mode objfpc}
{$pointermath on}

interface

uses
  Kernel.Mutex,
  Kernel.Events;

const
  PipeBufferSize = 4096;

type
  PPipe = ^TPipe;
  TPipe = record
    Lock: TMutex;
    Buffer: array[0..PipeBufferSize - 1] of Byte;
    ReadPosition: LongWord;
    ByteCount: LongWord;
    OpenReadEnds: LongInt;
    OpenWriteEnds: LongInt;
    { Synchronization events: signaled when data (or end of file) arrives,
      and when room (or a closed reader) appears. }
    DataAvailable: TEvent;
    SpaceAvailable: TEvent;
  end;

procedure InitializePipes;

{ Creates a pipe with no open ends; handles open them. }
function CreatePipe: PPipe;

procedure OpenPipeEnd(Pipe: PPipe; IsWriteEnd: Boolean);
procedure ClosePipeEnd(Pipe: PPipe; IsWriteEnd: Boolean);

{ Returns the number of bytes read (0 at end of file). }
function ReadFromPipe(Pipe: PPipe; Destination: PByte; ByteCount: QWord): QWord;
{ Returns the number of bytes written, or -1 if no reader is left. }
function WriteToPipe(Pipe: PPipe; Source: PByte; ByteCount: QWord): Int64;

implementation

uses
  Objects.Manager;

var
  PipeObjectType: TObjectType;

procedure InitializePipes;
begin
  RegisterObjectType(PipeObjectType, 'Pipe', SizeOf(TPipe), nil);
end;

function CreatePipe: PPipe;
begin
  Result := PPipe(CreateObject(PipeObjectType, nil));
  if Result = nil then
    Exit;
  InitializeMutex(Result^.Lock);
  InitializeEvent(Result^.DataAvailable, EventKindSynchronization, False);
  InitializeEvent(Result^.SpaceAvailable, EventKindSynchronization, False);
end;

procedure OpenPipeEnd(Pipe: PPipe; IsWriteEnd: Boolean);
begin
  AcquireMutex(Pipe^.Lock);
  if IsWriteEnd then
    Inc(Pipe^.OpenWriteEnds)
  else
    Inc(Pipe^.OpenReadEnds);
  ReleaseMutex(Pipe^.Lock);
end;

procedure ClosePipeEnd(Pipe: PPipe; IsWriteEnd: Boolean);
begin
  AcquireMutex(Pipe^.Lock);
  if IsWriteEnd then
  begin
    Dec(Pipe^.OpenWriteEnds);
    { Wake a reader so it can see end of file. }
    SignalEvent(Pipe^.DataAvailable);
  end
  else
  begin
    Dec(Pipe^.OpenReadEnds);
    SignalEvent(Pipe^.SpaceAvailable);
  end;
  ReleaseMutex(Pipe^.Lock);
end;

function ReadFromPipe(Pipe: PPipe; Destination: PByte; ByteCount: QWord): QWord;
begin
  Result := 0;
  if ByteCount = 0 then
    Exit;

  AcquireMutex(Pipe^.Lock);
  while (Pipe^.ByteCount = 0) and (Pipe^.OpenWriteEnds > 0) do
  begin
    ReleaseMutex(Pipe^.Lock);
    WaitForEvent(Pipe^.DataAvailable);
    AcquireMutex(Pipe^.Lock);
  end;

  while (Result < ByteCount) and (Pipe^.ByteCount > 0) do
  begin
    Destination[Result] := Pipe^.Buffer[Pipe^.ReadPosition];
    Pipe^.ReadPosition := (Pipe^.ReadPosition + 1) mod PipeBufferSize;
    Dec(Pipe^.ByteCount);
    Inc(Result);
  end;

  if Result > 0 then
    SignalEvent(Pipe^.SpaceAvailable);
  { Leave the signal for another reader if data remains. }
  if Pipe^.ByteCount > 0 then
    SignalEvent(Pipe^.DataAvailable);
  ReleaseMutex(Pipe^.Lock);
end;

function WriteToPipe(Pipe: PPipe; Source: PByte; ByteCount: QWord): Int64;
var
  Written: QWord;
  WritePosition: LongWord;
begin
  Written := 0;
  AcquireMutex(Pipe^.Lock);
  while Written < ByteCount do
  begin
    if Pipe^.OpenReadEnds <= 0 then
    begin
      ReleaseMutex(Pipe^.Lock);
      if Written > 0 then
        Exit(Int64(Written));
      Exit(-1);
    end;

    if Pipe^.ByteCount = PipeBufferSize then
    begin
      ReleaseMutex(Pipe^.Lock);
      WaitForEvent(Pipe^.SpaceAvailable);
      AcquireMutex(Pipe^.Lock);
      Continue;
    end;

    WritePosition := (Pipe^.ReadPosition + Pipe^.ByteCount) mod PipeBufferSize;
    Pipe^.Buffer[WritePosition] := Source[Written];
    Inc(Pipe^.ByteCount);
    Inc(Written);
    SignalEvent(Pipe^.DataAvailable);
  end;
  ReleaseMutex(Pipe^.Lock);
  Result := Int64(Written);
end;

end.
