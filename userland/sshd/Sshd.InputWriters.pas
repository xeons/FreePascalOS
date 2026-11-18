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
  Feeding a session's program what the client sends, without holding up
  the connection.

  A pipe write waits until every byte is in, so a program that is busy
  writing its own output (which the connection must keep reading) would
  stop the connection if the connection wrote to it directly - and
  scp/sftp do exactly that, many requests in flight while replies come
  back. So each session's input goes through a thread of its own: the
  connection queues the bytes (Write) and goes on; the thread writes
  them, counts what went in and signals the connection's progress event,
  and the connection then opens the channel's window by as much
  (TakeWrittenCount), so the client never has more in flight than the
  program takes. FinishWhenEmpty closes the handle once everything is
  written: the program reads end of file.
}
unit Sshd.InputWriters;

{$mode objfpc}{$H+}

interface

uses
  Classes;

type
  TInputWriter = class(TThread)
  private
    FHandle: Int64;
    FCloseHandleAtEnd: Boolean;
    FLock: TRTLCriticalSection;
    FQueue: string;
    FWritten: QWord;
    FFinishWhenEmpty: Boolean;
    FBroken: Boolean;
    FWakeEvent: Int64;
    FProgressEvent: Int64;
    function TakeChunk(out Chunk: string; out Finish: Boolean): Boolean;
    function WriteChunk(const Chunk: string): Boolean;
  protected
    procedure Execute; override;
  public
    { TargetHandle is written to (and closed at the end when CloseHandleAtEnd);
      ProgressEvent (not owned) is signaled after each write. }
    constructor Create(TargetHandle, ProgressEvent: Int64; CloseHandleAtEnd: Boolean);
    destructor Destroy; override;
    procedure Write(const Data: string);
    procedure FinishWhenEmpty;
    { Bytes written since the last call. }
    function TakeWrittenCount: QWord;
    function Pending: Integer;
    function Broken: Boolean;
  end;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Kernel,
  Sys.Objects,
  Sys.Processes;

const
  ChunkBytes = 16 * 1024;
  StopWaitMilliseconds = 2000;
  StopPollMilliseconds = 20;

constructor TInputWriter.Create(TargetHandle, ProgressEvent: Int64; CloseHandleAtEnd: Boolean);
begin
  FHandle := TargetHandle;
  FProgressEvent := ProgressEvent;
  FCloseHandleAtEnd := CloseHandleAtEnd;
  InitCriticalSection(FLock);
  FQueue := '';
  FWakeEvent := CreateEvent(False, False);
  FreeOnTerminate := False;
  inherited Create(False);
end;

destructor TInputWriter.Destroy;
var
  Waited: Integer;
begin
  Terminate;
  SetEvent(FWakeEvent);
  { The thread may sit in a write the program never takes; it is given
    a moment (ending the program breaks the write), not waited for. }
  Waited := 0;
  while not Finished and (Waited < StopWaitMilliseconds) do
  begin
    SleepMilliseconds(StopPollMilliseconds);
    Inc(Waited, StopPollMilliseconds);
  end;
  if not Finished then
    Exit;
  inherited Destroy;
  CloseHandle(FWakeEvent);
  DoneCriticalSection(FLock);
end;

procedure TInputWriter.Write(const Data: string);
begin
  if Data = '' then
    Exit;
  EnterCriticalSection(FLock);
  try
    if not FBroken and not FFinishWhenEmpty then
      FQueue := FQueue + Data;
  finally
    LeaveCriticalSection(FLock);
  end;
  SetEvent(FWakeEvent);
end;

procedure TInputWriter.FinishWhenEmpty;
begin
  EnterCriticalSection(FLock);
  FFinishWhenEmpty := True;
  LeaveCriticalSection(FLock);
  SetEvent(FWakeEvent);
end;

function TInputWriter.TakeWrittenCount: QWord;
begin
  EnterCriticalSection(FLock);
  Result := FWritten;
  FWritten := 0;
  LeaveCriticalSection(FLock);
end;

function TInputWriter.Pending: Integer;
begin
  EnterCriticalSection(FLock);
  Result := Length(FQueue);
  LeaveCriticalSection(FLock);
end;

function TInputWriter.Broken: Boolean;
begin
  EnterCriticalSection(FLock);
  Result := FBroken;
  LeaveCriticalSection(FLock);
end;

function TInputWriter.TakeChunk(out Chunk: string; out Finish: Boolean): Boolean;
begin
  EnterCriticalSection(FLock);
  try
    Chunk := Copy(FQueue, 1, ChunkBytes);
    Delete(FQueue, 1, Length(Chunk));
    Finish := FFinishWhenEmpty and (Chunk = '');
    Result := (Chunk <> '') or Finish;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

{ Writes all of Chunk (a terminal's master side takes what fits each
  time); False once the other side is gone. }
function TInputWriter.WriteChunk(const Chunk: string): Boolean;
var
  Done: Integer;
  Count: Int64;
begin
  Done := 0;
  while Done < Length(Chunk) do
  begin
    if Terminated then
      Exit(False);
    Count := KernelWrite(FHandle, @Chunk[Done + 1], Length(Chunk) - Done);
    if Count <= 0 then
      Exit(False);
    Done := Done + Integer(Count);
    EnterCriticalSection(FLock);
    FWritten := FWritten + QWord(Count);
    LeaveCriticalSection(FLock);
    SetEvent(FProgressEvent);
  end;
  Result := True;
end;

procedure TInputWriter.Execute;
var
  Chunk: string;
  Finish: Boolean;
begin
  while not Terminated do
  begin
    if not TakeChunk(Chunk, Finish) then
    begin
      WaitForHandle(FWakeEvent, InfiniteWait);
      Continue;
    end;
    if Finish then
      Break;
    if not WriteChunk(Chunk) then
    begin
      EnterCriticalSection(FLock);
      FBroken := True;
      FQueue := '';
      LeaveCriticalSection(FLock);
      SetEvent(FProgressEvent);
      Break;
    end;
  end;
  if FCloseHandleAtEnd then
    KernelClose(FHandle);
end;

end.
