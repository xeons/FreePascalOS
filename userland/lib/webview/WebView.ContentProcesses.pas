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
  The program's content processes (process per site): a view asks for
  the process of a site and gets one already locked to that site that
  has room (MaximumViewsPerProcess views), or a new one. Two sites never
  share a process. A process is started as /bin/webcontent with its end
  of a channel passed to it, its site, and the limits it puts on itself
  (the sandbox, the memory it may commit, the slow script limit); a
  process left without views is asked to end.

  On the GUI thread: the manager pings every process once a second and
  tells a process's views when it stops answering for
  HangTimeoutMilliseconds (and when it answers again); it hands each
  view the messages the IPC thread (WebView.ContentIo) queued for it,
  and the end of its process (crashed or not). It never waits for a
  content process: one asked to end that has not ended
  ShutdownGraceMilliseconds later - a script or a storm of tasks keeps
  it busy, or it is swapping - is ended by force, so closing a tab
  frees its memory and processor even then.
}
unit WebView.ContentProcesses;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes,
  Windowing.Messages,
  Controls.Timers,
  WebIpc.Messages,
  WebView.ContentProcess,
  WebView.ContentIo;

const
  { Posted to the manager when the IPC thread queued something. }
  MessageContentDelivery = $0F02;

type
  TContentProcessManager = class(TMessageReceiver)
  private
    FProcesses: TList;
    FQueue: TDeliveryQueue;
    FWakePosted: LongInt;
    FIo: TContentIoThread;
    FPingTimer: TTimer;
    FNextViewId: LongWord;
    FHangTimeoutMilliseconds: QWord;
    FScriptRunLimitMilliseconds: QWord;
    FMaximumViewsPerProcess: Integer;
    FMemoryLimitMegabytes: LongWord;
    FSandboxed: Boolean;
    FProgramPath: string;
    procedure Deliver(Item: TContentDelivery);
    procedure DrainQueue;
    procedure Dispatch(Item: TContentDelivery);
    procedure PingTimerFired(Sender: TTimer);
    procedure CheckResponsive(Process: TContentProcess);
    function Spawn(const Site: string): TContentProcess;
    procedure EnsureIo;
  public
    constructor Create;
    destructor Destroy; override;
    procedure ReceiveMessage(var Message: TPostedMessage); override;
    { A process locked to Site with room for one more view (nil when none
      can be started). }
    function ProcessForSite(const Site: string): TContentProcess;
    { Client becomes one of Process's views (it gets its view id). }
    procedure Attach(Process: TContentProcess; Client: TContentClient);
    { The view is gone; a process left without views is asked to end. }
    procedure Detach(Process: TContentProcess; Client: TContentClient);
    { Ends a process now (a hung page's Stop). }
    procedure Terminate(Process: TContentProcess);
    { Sends to a process from the GUI thread (never waits). }
    function Send(Process: TContentProcess; Kind: Word; ViewId, RequestId: LongWord; const Payload: TBytes): Boolean;
    function SendWithHandles(Process: TContentProcess; Kind: Word; ViewId, RequestId: LongWord;
      const Payload: TBytes; const Handles: array of Int64): Boolean;
    function ProcessCount: Integer;
    { Settings, for processes started from now on. }
    property HangTimeoutMilliseconds: QWord read FHangTimeoutMilliseconds write FHangTimeoutMilliseconds;
    { 0: scripts are never stopped (a test setting). }
    property ScriptRunLimitMilliseconds: QWord read FScriptRunLimitMilliseconds write FScriptRunLimitMilliseconds;
    property MaximumViewsPerProcess: Integer read FMaximumViewsPerProcess write FMaximumViewsPerProcess;
    property MemoryLimitMegabytes: LongWord read FMemoryLimitMegabytes write FMemoryLimitMegabytes;
    property Sandboxed: Boolean read FSandboxed write FSandboxed;
    property ProgramPath: string read FProgramPath write FProgramPath;
  end;

const
  DefaultContentProgram = '/bin/webcontent';
  DefaultHangTimeoutMilliseconds = 8000;
  DefaultMaximumViewsPerProcess = 4;
  { Used when the machine's RAM cannot be read; otherwise a quarter of
    it (WebView.ContentMemory). }
  DefaultMemoryLimitMegabytes = 1024;
  { How long a process asked to end may take before it is ended. }
  ShutdownGraceMilliseconds = 3000;
  { Each process takes two of the IPC thread's 64 wait handles. }
  MaximumContentProcesses = 30;

{ The program's manager (made when first asked for). }
function ContentProcesses: TContentProcessManager;
{ Ends every content process (at the program's end). }
procedure FreeContentProcesses;

implementation

uses
  Abi.SystemCalls,
  Sys.Objects,
  Sys.Processes,
  Windowing.Connection,
  Windowing.Theme,
  Web.Script.Watchdog,
  WebIpc.Endpoints,
  WebIpc.ViewMessages,
  WebView.NetworkService,
  WebView.ContentMemory;

const
  PingIntervalMilliseconds = 1000;

var
  Manager: TContentProcessManager = nil;

function ContentProcesses: TContentProcessManager;
begin
  if Manager = nil then
    Manager := TContentProcessManager.Create;
  Result := Manager;
end;

procedure FreeContentProcesses;
begin
  FreeAndNil(Manager);
end;

constructor TContentProcessManager.Create;
begin
  inherited Create;
  FProcesses := TList.Create;
  FQueue := TDeliveryQueue.Create;
  FHangTimeoutMilliseconds := DefaultHangTimeoutMilliseconds;
  FScriptRunLimitMilliseconds := DefaultScriptRunLimitMilliseconds;
  FMaximumViewsPerProcess := DefaultMaximumViewsPerProcess;
  if MachineRamMegabytes > 0 then
    FMemoryLimitMegabytes := PageMemoryLimitFor(MachineRamMegabytes)
  else
    FMemoryLimitMegabytes := DefaultMemoryLimitMegabytes;
  FSandboxed := True;
  FProgramPath := DefaultContentProgram;
  FPingTimer := TTimer.Create(Self);
  FPingTimer.Interval := PingIntervalMilliseconds;
  FPingTimer.OnTimer := @PingTimerFired;
end;

destructor TContentProcessManager.Destroy;
var
  Index: Integer;
  Process: TContentProcess;
begin
  FPingTimer.Free;
  for Index := 0 to FProcesses.Count - 1 do
  begin
    Process := TContentProcess(FProcesses[Index]);
    if not Process.Ended then
      TerminateProgram(Process.ProcessId, 143);
  end;
  { The thread ends; what it still delivers is dropped with the queue. }
  FIo.Free;
  for Index := 0 to FProcesses.Count - 1 do
  begin
    Process := TContentProcess(FProcesses[Index]);
    if Process.ProcessHandle >= 0 then
      CloseHandle(Process.ProcessHandle);
    Process.Free;
  end;
  FProcesses.Free;
  FQueue.Free;
  inherited Destroy;
end;

procedure TContentProcessManager.EnsureIo;
begin
  if FIo = nil then
    FIo := TContentIoThread.Create(@Deliver);
end;

{ The IPC thread: queue, and wake the GUI thread once. }
procedure TContentProcessManager.Deliver(Item: TContentDelivery);
begin
  FQueue.Push(Item);
  if InterlockedExchange(FWakePosted, 1) = 0 then
    if not PostMessage(Self, MessageContentDelivery) then
      FWakePosted := 0;
end;

procedure TContentProcessManager.ReceiveMessage(var Message: TPostedMessage);
begin
  if Message.Code = MessageContentDelivery then
  begin
    FWakePosted := 0;
    DrainQueue;
    Exit;
  end;
  inherited ReceiveMessage(Message);
end;

procedure TContentProcessManager.DrainQueue;
var
  Items: TList;
  Index: Integer;
begin
  Items := FQueue.TakeAll;
  try
    for Index := 0 to Items.Count - 1 do
    begin
      try
        Dispatch(TContentDelivery(Items[Index]));
      except
        on Error: Exception do
          WriteLn(StdErr, '[webview] a content message failed: ', Error.Message);
      end;
      TContentDelivery(Items[Index]).Free;
    end;
  finally
    Items.Free;
  end;
end;

procedure TContentProcessManager.Dispatch(Item: TContentDelivery);
var
  Process: TContentProcess;
  Client: TContentClient;
  Clients: array of TContentClient;
  Index: Integer;
  Crashed: Boolean;
begin
  Process := Item.Process;
  if Item.Message = nil then
  begin
    { The process ended: its views hear it, then it goes. }
    Crashed := not Process.ShutdownSent or Process.KilledAsHung or (Process.ExitCode <> 0);
    Clients := nil;
    SetLength(Clients, Process.ClientCount);
    for Index := 0 to Process.ClientCount - 1 do
      Clients[Index] := Process.Client(Index);
    FProcesses.Remove(Process);
    for Index := 0 to High(Clients) do
      Clients[Index].ProcessEnded(Crashed, Process.ExitCode);
    if Process.ProcessHandle >= 0 then
      CloseHandle(Process.ProcessHandle);
    Process.Free;
    Exit;
  end;
  if Item.Message.Kind = IpcHello then
  begin
    Process.LastPong := GetTickCount64;
    Exit;
  end;
  Client := Process.FindClient(Item.Message.ViewId);
  if Client <> nil then
    Client.Received(Item.Message);
end;

function TContentProcessManager.ProcessCount: Integer;
begin
  Result := FProcesses.Count;
end;

function TContentProcessManager.ProcessForSite(const Site: string): TContentProcess;
var
  Index: Integer;
  Process: TContentProcess;
begin
  for Index := 0 to FProcesses.Count - 1 do
  begin
    Process := TContentProcess(FProcesses[Index]);
    if (Process.Site = Site) and not Process.Ended and not Process.ShutdownSent and not Process.Hung and
       (Process.ClientCount < FMaximumViewsPerProcess) then
      Exit(Process);
  end;
  if FProcesses.Count >= MaximumContentProcesses then
    Exit(nil);
  Result := Spawn(Site);
end;

function TContentProcessManager.Spawn(const Site: string): TContentProcess;
var
  First, Second: Int64;
  Options: TProcessOptions;
  Arguments: array of string;
  ArgumentPointers: array of PChar;
  Passed: array[0..0] of Int64;
  Handle: Int64;
  Index: Integer;
begin
  Result := nil;
  if not FileExists(FProgramPath) then
    Exit;
  if CreateChannel(First, Second) <> ErrorNone then
    Exit;
  Arguments := nil;
  SetLength(Arguments, 8);
  Arguments[0] := FProgramPath;
  Arguments[1] := '--channel=' + IntToStr(Second);
  Arguments[2] := '--site=' + Site;
  Arguments[3] := '--scale=' + IntToStr(DisplayScale) + ',' + IntToStr(DisplayDpi);
  Arguments[4] := '--script-limit=' + IntToStr(FScriptRunLimitMilliseconds);
  Arguments[5] := '--memory-limit=' + IntToStr(FMemoryLimitMegabytes);
  Arguments[6] := '--theme=' + Theme.Key;
  if FSandboxed then
    Arguments[7] := '--sandbox'
  else
    Arguments[7] := '--no-sandbox';
  ArgumentPointers := nil;
  SetLength(ArgumentPointers, Length(Arguments) + 1);
  for Index := 0 to High(Arguments) do
    ArgumentPointers[Index] := PChar(Arguments[Index]);
  ArgumentPointers[Length(Arguments)] := nil;
  DefaultProcessOptions(Options);
  Passed[0] := Second;
  Options.PassedHandles := @Passed[0];
  Options.PassedHandleCount := 1;
  Handle := StartProgram(PChar(FProgramPath), @ArgumentPointers[0], Options);
  { The child has its end now. }
  CloseHandle(Second);
  if Handle < 0 then
  begin
    CloseHandle(First);
    Exit;
  end;
  { All pages together are limited too, so many heavy tabs cannot take
    what the rest of the system needs. }
  PutInContentJob(Handle, FMemoryLimitMegabytes);
  Result := TContentProcess.Create(TIpcEndpoint.Create(First), Site);
  Result.ProcessHandle := Handle;
  Result.ProcessId := ProcessIdOf(Handle);
  Result.LastPong := GetTickCount64;
  Result.Network := TContentNetwork.Create(Result);
  FProcesses.Add(Result);
  EnsureIo;
  FIo.AddProcess(Result);
  FPingTimer.Enabled := True;
end;

procedure TContentProcessManager.Attach(Process: TContentProcess; Client: TContentClient);
begin
  Inc(FNextViewId);
  Client.ViewId := FNextViewId;
  Process.AddClient(Client);
end;

procedure TContentProcessManager.Detach(Process: TContentProcess; Client: TContentClient);
begin
  Process.RemoveClient(Client);
  if Process.Ended then
    Exit;
  Send(Process, IpcDestroyView, Client.ViewId, 0, nil);
  if Process.ClientCount = 0 then
  begin
    Process.ShutdownSent := True;
    Process.ShutdownSentAt := GetTickCount64;
    Send(Process, IpcShutdown, 0, 0, nil);
  end;
end;

procedure TContentProcessManager.Terminate(Process: TContentProcess);
begin
  if Process.Ended then
    Exit;
  Process.KilledAsHung := True;
  TerminateProgram(Process.ProcessId, 137);
end;

function TContentProcessManager.Send(Process: TContentProcess; Kind: Word; ViewId, RequestId: LongWord;
  const Payload: TBytes): Boolean;
begin
  Result := SendWithHandles(Process, Kind, ViewId, RequestId, Payload, []);
end;

function TContentProcessManager.SendWithHandles(Process: TContentProcess; Kind: Word; ViewId, RequestId: LongWord;
  const Payload: TBytes; const Handles: array of Int64): Boolean;
begin
  if (Process = nil) or Process.Ended then
    Exit(False);
  Result := Process.Send(Kind, ViewId, RequestId, Payload, Handles);
  if Process.Endpoint.HasPending and (FIo <> nil) then
    FIo.Wake;
end;

procedure TContentProcessManager.CheckResponsive(Process: TContentProcess);
var
  Silent: QWord;
  Index: Integer;
  NowHung: Boolean;
begin
  Silent := GetTickCount64 - Process.LastPong;
  NowHung := (FHangTimeoutMilliseconds > 0) and (Silent > FHangTimeoutMilliseconds) and (Process.ClientCount > 0);
  if NowHung = Process.Hung then
    Exit;
  Process.Hung := NowHung;
  for Index := Process.ClientCount - 1 downto 0 do
    Process.Client(Index).ProcessResponsive(not NowHung);
end;

{ Asked to end (no views left) and still running after the grace time. }
function ShutdownOverdue(Process: TContentProcess): Boolean;
begin
  Result := Process.ShutdownSent and not Process.ShutdownForced and (Process.ClientCount = 0) and
    (GetTickCount64 - Process.ShutdownSentAt > ShutdownGraceMilliseconds);
end;

procedure TContentProcessManager.PingTimerFired(Sender: TTimer);
var
  Index: Integer;
  Process: TContentProcess;
begin
  for Index := FProcesses.Count - 1 downto 0 do
  begin
    Process := TContentProcess(FProcesses[Index]);
    if Process.Ended then
      Continue;
    if ShutdownOverdue(Process) then
    begin
      Process.ShutdownForced := True;
      TerminateProgram(Process.ProcessId, 143);
      Continue;
    end;
    Inc(Process.PingSequence);
    Send(Process, IpcPing, 0, 0, EncodeNumber(LongInt(Process.PingSequence)));
    CheckResponsive(Process);
  end;
  FPingTimer.Enabled := FProcesses.Count > 0;
end;

end.
