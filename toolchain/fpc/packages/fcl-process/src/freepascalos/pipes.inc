{
    FreePascalOS
    Copyright (C) 2026 Brandon Scott

    The FreePascalOS part of the pipe streams (fcl-process), on the
    kernel's pipes. Part of the FreePascalOS patches to Free Pascal.

    See the file COPYING.FPC, included in the Free Pascal distribution,
    for details about the copyright.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 **********************************************************************}

uses
  Sys.Objects, Sys.Processes;

const
  { What NumBytesAvailable reports while a read would not wait: a read
    returns what is there, at most this much. The kernel tells only
    whether something is there (or the writer is gone). }
  PipeReadChunk = 4096;

Function CreatePipeHandles (Var Inhandle,OutHandle : THandle; APipeBufferSize : Cardinal = 1024) : Boolean;
var
  ReadHandle, WriteHandle: Int64;
begin
  Result := Sys.Processes.CreatePipe(ReadHandle, WriteHandle) = 0;
  if Result then
    begin
    InHandle := THandle(ReadHandle);
    OutHandle := THandle(WriteHandle);
    end
  else
    begin
    InHandle := THandle(UnusedHandle);
    OutHandle := THandle(UnusedHandle);
    end;
end;

Function TInputPipeStream.GetNumBytesAvailable: DWord;
begin
  if Sys.Objects.WaitForHandle(Handle, 0) = 0 then
    Result := PipeReadChunk
  else
    Result := 0;
end;

function TInputPipeStream.GetPosition: Int64;
begin
  Result:=FPos;
end;

procedure TInputPipeStream.InvalidSeek;
begin
  Raise EPipeSeek.Create (ENoSeekMsg);
end;

procedure PipeClose (const FHandle: THandle); inline;
begin
  if FHandle <> THandle(UnusedHandle) then
    FileClose(FHandle);
end;
