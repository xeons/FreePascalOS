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
  The browser's IPC thread: it waits on every content process's channel
  and process handle, so the GUI thread never does. What comes is
  sorted there: pongs are noted, the network service's requests are
  answered on this thread (WebView.NetworkService), and everything for
  a view goes to the GUI thread's queue, which is woken with one posted
  message however much is waiting. Messages the channel would not take
  (the renderer is not reading) are sent again every few milliseconds
  until they go. A process whose channel broke or that ended is told to
  the GUI thread once, with its exit status, and not looked at again.
}
unit WebView.ContentIo;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes,
  WebView.ContentProcess;

type
  { Hands deliveries to the GUI thread (WebView.ContentProcesses). }
  TDeliveryEvent = procedure(Item: TContentDelivery) of object;

  TContentIoThread = class(TThread)
  private
    FProcesses: TList;
    FLock: TRTLCriticalSection;
    FWakeEvent: Int64;
    FOnDelivery: TDeliveryEvent;
    FLastStorageSave: QWord;
    { False when the process ended (it may be gone right after). }
    function ServeProcess(Process: TContentProcess): Boolean;
    procedure EndProcess(Process: TContentProcess);
    function Snapshot: TList;
  protected
    procedure Execute; override;
  public
    constructor Create(OnDelivery: TDeliveryEvent);
    destructor Destroy; override;
    { Starts watching a process (any thread). }
    procedure AddProcess(Process: TContentProcess);
    { Something was queued to send, or a process added: look again. }
    procedure Wake;
  end;

implementation

uses
  Abi.SystemCalls,
  Sys.Objects,
  Sys.Processes,
  WebIpc.Messages,
  WebIpc.Endpoints,
  WebView.NetworkService;

const
  { While something waits to be sent: how soon to try again. }
  RetryMilliseconds = 5;
  IdleMilliseconds = 1000;
  StorageSaveMilliseconds = 5000;

function UptimeMilliseconds: QWord;
begin
  Result := GetTickCount64;
end;

constructor TContentIoThread.Create(OnDelivery: TDeliveryEvent);
begin
  FProcesses := TList.Create;
  InitCriticalSection(FLock);
  FWakeEvent := CreateEvent(False, False);
  FOnDelivery := OnDelivery;
  inherited Create(False);
end;

destructor TContentIoThread.Destroy;
begin
  Terminate;
  Wake;
  inherited Destroy;
  CloseHandle(FWakeEvent);
  DoneCriticalSection(FLock);
  FProcesses.Free;
end;

procedure TContentIoThread.AddProcess(Process: TContentProcess);
begin
  EnterCriticalSection(FLock);
  try
    FProcesses.Add(Process);
  finally
    LeaveCriticalSection(FLock);
  end;
  Wake;
end;

procedure TContentIoThread.Wake;
begin
  SetEvent(FWakeEvent);
end;

function TContentIoThread.Snapshot: TList;
begin
  Result := TList.Create;
  EnterCriticalSection(FLock);
  try
    Result.Assign(FProcesses);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TContentIoThread.EndProcess(Process: TContentProcess);
var
  Item: TContentDelivery;
  Code: LongInt;
begin
  EnterCriticalSection(FLock);
  try
    FProcesses.Remove(Process);
  finally
    LeaveCriticalSection(FLock);
  end;
  { Its exchanges stop before it goes (their threads send to it). }
  FreeAndNil(Process.Network);
  Code := 0;
  if WaitForProgramWithTimeout(Process.ProcessHandle, 2000, Code) <> ErrorNone then
  begin
    { It closed its channel but runs on: it is not ours to trust. }
    TerminateProgram(ProcessIdOf(Process.ProcessHandle), 137);
    if WaitForProgramWithTimeout(Process.ProcessHandle, 2000, Code) <> ErrorNone then
      Code := -1;
  end;
  Process.ExitCode := Code;
  Process.Ended := True;
  Item := TContentDelivery.Create;
  Item.Process := Process;
  FOnDelivery(Item);
end;

function TContentIoThread.ServeProcess(Process: TContentProcess): Boolean;
var
  Message: TIpcMessage;
  Status: TIpcReceiveStatus;
  Item: TContentDelivery;
begin
  Process.Endpoint.Flush;
  repeat
    Status := Process.Endpoint.Receive(Message);
    if Status <> IpcReceived then
      Break;
    if Message.Kind = IpcPong then
    begin
      Process.LastPong := UptimeMilliseconds;
      Message.Free;
      Continue;
    end;
    if (Process.Network <> nil) and TContentNetwork(Process.Network).Handle(Message) then
      Continue;
    Item := TContentDelivery.Create;
    Item.Process := Process;
    Item.Message := Message;
    FOnDelivery(Item);
  until False;
  if Process.Network <> nil then
    TContentNetwork(Process.Network).Reap;
  Result := True;
  if (Status = IpcBroken) or Process.Endpoint.Broken then
  begin
    EndProcess(Process);
    Result := False;
  end;
end;

procedure TContentIoThread.Execute;
var
  Processes: TList;
  Handles: array[0..MaximumWaitHandles - 1] of Int64;
  Owners: array[0..MaximumWaitHandles - 1] of TContentProcess;
  Count, Index: Integer;
  Process, EndedByHandle: TContentProcess;
  Timeout: Int64;
  Ready: Int64;
begin
  while not Terminated do
  begin
    Processes := Snapshot;
    try
      Handles[0] := FWakeEvent;
      Owners[0] := nil;
      Count := 1;
      Timeout := IdleMilliseconds;
      for Index := 0 to Processes.Count - 1 do
      begin
        Process := TContentProcess(Processes[Index]);
        if Count + 2 > MaximumWaitHandles then
          Break;
        Handles[Count] := Process.Endpoint.Channel;
        Owners[Count] := Process;
        Inc(Count);
        Handles[Count] := Process.ProcessHandle;
        Owners[Count] := Process;
        Inc(Count);
        if Process.Endpoint.HasPending then
          Timeout := RetryMilliseconds;
      end;
    finally
      Processes.Free;
    end;
    Ready := WaitForHandles(Slice(Handles, Count), Timeout);
    if Terminated then
      Break;
    { A process that ended without its channel breaking yet. }
    EndedByHandle := nil;
    if (Ready > 0) and (Ready < Count) and (Owners[Ready] <> nil) and
       (Handles[Ready] = Owners[Ready].ProcessHandle) then
      EndedByHandle := Owners[Ready];
    { Serve every process: a ready one, and any with something to send. }
    Processes := Snapshot;
    try
      for Index := 0 to Processes.Count - 1 do
      begin
        Process := TContentProcess(Processes[Index]);
        if ServeProcess(Process) and (Process = EndedByHandle) then
          EndProcess(Process);
      end;
    finally
      Processes.Free;
    end;
    if UptimeMilliseconds - FLastStorageSave >= StorageSaveMilliseconds then
    begin
      FLastStorageSave := UptimeMilliseconds;
      SaveServiceStorage;
    end;
  end;
end;

end.
