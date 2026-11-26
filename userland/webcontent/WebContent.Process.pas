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
  The content process as a whole: its options, its channel, its views
  and its loop. The loop is the page thread: it delivers the posted
  messages the engines wake themselves with, runs their timers (the
  shared kernel timer of Controls.Timers, watched like any handle),
  hands the browser's messages to the views (or to the network
  transport), lets each view paint a frame, and waits on the channel,
  the posted-message event and the watched handles. It ends when the
  browser says so (no views left) or its channel breaks (the browser is
  gone): a renderer never outlives its browser.
}
unit WebContent.Process;

{$mode objfpc}
{$H+}

interface

type
  TContentOptions = record
    Channel: Int64;
    Site: string;
    ScalePercent, Dpi: LongWord;
    ScriptRunLimitMilliseconds: QWord;
    MemoryLimitMegabytes: LongWord;
    ThemeKey: string;
    Sandbox: Boolean;
  end;

{ Reads the command line; False (with a message) when it is not usable. }
function ParseContentOptions(out Options: TContentOptions; out Problem: string): Boolean;
{ Runs the process; returns its exit status. }
function RunContentProcess(constref Options: TContentOptions): LongInt;

implementation

uses
  SysUtils,
  Classes,
  Abi.SystemCalls,
  Sys.Objects,
  Sys.Processes,
  Windowing.Messages,
  Windowing.HandleWatches,
  Windowing.Connection,
  Windowing.Theme,
  Web.Fetch.NetworkContexts,
  Web.Storage,
  Web.Script.Watchdog,
  Web.LongWork,
  WebIpc.Messages,
  WebIpc.ViewMessages,
  WebContent.Connection,
  WebContent.Transport,
  WebContent.Storage,
  WebContent.OriginData,
  Web.Storage.OriginData,
  WebContent.IndexedDb,
  Web.Workers.ServiceWorkers,
  WebContent.Views,
  WebContent.Sandbox,
  Web.Bindings.Context;

const
  { Eighths of the process's memory limit its pages' script heaps may hold. }
  ScriptHeapShareEighths = 5;

function OptionValue(const Argument, Name: string; out Value: string): Boolean;
begin
  Result := Copy(Argument, 1, Length(Name) + 1) = Name + '=';
  if Result then
    Value := Copy(Argument, Length(Name) + 2, Length(Argument));
end;

function ParseContentOptions(out Options: TContentOptions; out Problem: string): Boolean;
var
  Index, Comma: Integer;
  Value: string;
begin
  Options := Default(TContentOptions);
  Options.Channel := -1;
  Options.ScalePercent := 100;
  Options.Dpi := 96;
  Options.ScriptRunLimitMilliseconds := DefaultScriptRunLimitMilliseconds;
  Options.Sandbox := True;
  Problem := '';
  for Index := 1 to ParamCount do
  begin
    if OptionValue(ParamStr(Index), '--channel', Value) then
      Options.Channel := StrToInt64Def(Value, -1)
    else if OptionValue(ParamStr(Index), '--site', Value) then
      Options.Site := Value
    else if OptionValue(ParamStr(Index), '--scale', Value) then
    begin
      Comma := Pos(',', Value);
      if Comma > 0 then
      begin
        Options.ScalePercent := StrToIntDef(Copy(Value, 1, Comma - 1), 100);
        Options.Dpi := StrToIntDef(Copy(Value, Comma + 1, Length(Value)), 96);
      end;
    end
    else if OptionValue(ParamStr(Index), '--script-limit', Value) then
      Options.ScriptRunLimitMilliseconds := StrToQWordDef(Value, DefaultScriptRunLimitMilliseconds)
    else if OptionValue(ParamStr(Index), '--memory-limit', Value) then
      Options.MemoryLimitMegabytes := StrToIntDef(Value, 0)
    else if OptionValue(ParamStr(Index), '--theme', Value) then
      Options.ThemeKey := Value
    else if ParamStr(Index) = '--no-sandbox' then
      Options.Sandbox := False
    else if ParamStr(Index) = '--sandbox' then
      Options.Sandbox := True
    else
    begin
      Problem := 'unknown option ' + ParamStr(Index);
      Exit(False);
    end;
  end;
  if Options.Channel < 0 then
  begin
    Problem := 'no --channel: webcontent is started by the browser';
    Exit(False);
  end;
  Result := True;
end;

type
  TContentProcessRunner = class
  private
    FContext: TContentContext;
    FTransport: TContentTransport;
    FStorageBackend: TContentStorageBackend;
    FOriginData: TContentOriginData;
    FIndexedDbBackend: TContentIndexedDbBackend;
    FViews: TList;
    FShutdown: Boolean;
    FInterruptions: Integer;
    function FindView(ViewId: LongWord): TContentView;
    procedure Dispatch(Message: TIpcMessage);
    procedure ServeChannel;
    procedure FinishTurn;
    procedure WaitForWork;
    { A step of the engine's long work (Web.LongWork): pings are
      answered. }
    procedure LongWorkStep;
  public
    constructor Create(constref Options: TContentOptions);
    destructor Destroy; override;
    procedure Run;
  end;

constructor TContentProcessRunner.Create(constref Options: TContentOptions);
begin
  inherited Create;
  FViews := TList.Create;
  FContext := TContentContext.Create;
  FContext.Site := Options.Site;
  FContext.Connection := TContentConnection.Create(Options.Channel);
  FTransport := TContentTransport.Create(FContext.Connection);
  { The context owns the transport from now on. }
  FContext.Network := TNetworkContext.CreateForTransport(FTransport);
  FStorageBackend := TContentStorageBackend.Create(FContext.Connection);
  FContext.Storage := TWebStorageRegistry.Create('');
  FContext.Storage.Backend := FStorageBackend;
  { Caches and service worker registrations are the browser's to keep. }
  FOriginData := TContentOriginData.Create(FContext.Connection);
  OriginDataBackend := FOriginData;
  FIndexedDbBackend := TContentIndexedDbBackend.Create(FContext.Connection);
  FContext.IndexedDb := FIndexedDbBackend;
  { A service worker started before any page of its origin has the same
    storage service. }
  DefaultStorageBackend := FIndexedDbBackend;
  SetLongWorkStepHandler(@LongWorkStep);
end;

destructor TContentProcessRunner.Destroy;
var
  Index: Integer;
begin
  SetLongWorkStepHandler(nil);
  for Index := 0 to FViews.Count - 1 do
    TContentView(FViews[Index]).Free;
  FViews.Free;
  FContext.Storage.Free;
  FStorageBackend.Free;
  OriginDataBackend := nil;
  FOriginData.Free;
  DefaultStorageBackend := nil;
  FIndexedDbBackend.Free;
  FContext.Network.Free;
  FContext.Connection.Free;
  FContext.Free;
  inherited Destroy;
end;

function TContentProcessRunner.FindView(ViewId: LongWord): TContentView;
var
  Index: Integer;
begin
  for Index := 0 to FViews.Count - 1 do
    if TContentView(FViews[Index]).ViewId = ViewId then
      Exit(TContentView(FViews[Index]));
  Result := nil;
end;

procedure TContentProcessRunner.Dispatch(Message: TIpcMessage);
var
  View: TContentView;
begin
  if FTransport.Deliver(Message) then
    Exit;
  case Message.Kind of
    IpcShutdown: FShutdown := True;
    IpcIndexedDbNotice: FIndexedDbBackend.DeliverNotice(Message);
    IpcCreateView:
      if FindView(Message.ViewId) = nil then
        FViews.Add(TContentView.Create(FContext, Message.ViewId, DecodeViewSetup(Message.Payload)));
    IpcDestroyView:
      begin
        View := FindView(Message.ViewId);
        if View <> nil then
        begin
          FViews.Remove(View);
          View.Free;
        end;
      end;
  else
    begin
      View := FindView(Message.ViewId);
      if View <> nil then
        View.Handle(Message);
    end;
  end;
end;

procedure TContentProcessRunner.ServeChannel;
var
  Message: TIpcMessage;
begin
  while FContext.Connection.Next(Message) do
  begin
    try
      try
        Dispatch(Message);
      except
        on Error: Exception do
        begin
          { Where it failed, module and offset per frame (symbolize.py
            names them): a fault the loop lives through says where. }
          WriteLn(StdErr, 'webcontent: ', IpcKindName(Message.Kind), ' failed: ', Error.ClassName, ': ',
            Error.Message);
          DumpExceptionBackTrace(StdErr);
        end;
      end;
    finally
      Message.Free;
    end;
    if FShutdown then
      Exit;
  end;
end;

procedure TContentProcessRunner.FinishTurn;
var
  Index, Count: Integer;
  AnyShown: Boolean;
begin
  AnyShown := False;
  Count := ScriptWatchdogInterruptions;
  for Index := 0 to FViews.Count - 1 do
  begin
    if Count <> FInterruptions then
      TContentView(FViews[Index]).ScriptInterrupted;
    TContentView(FViews[Index]).FinishTurn;
    if TContentView(FViews[Index]).Visible then
      AnyShown := True;
  end;
  FInterruptions := Count;
  SetShown(AnyShown);
  FContext.Connection.Endpoint.Flush;
end;

procedure TContentProcessRunner.WaitForWork;
var
  Handles: array[0..MaximumHandleWatches + 1] of Int64;
  Count, Index: Integer;
  Ready: Int64;
  Timeout: Int64;
begin
  Handles[0] := FContext.Connection.Endpoint.Channel;
  Handles[1] := PostedMessageEvent;
  Count := 2;
  for Index := 0 to WatchedHandleCount - 1 do
  begin
    Handles[Count] := WatchedHandle(Index);
    Inc(Count);
  end;
  if FContext.Connection.HasDeferred then
    { Put aside while pings were answered: handled at once. }
    Timeout := 0
  else if FContext.Connection.Endpoint.HasPending then
    Timeout := 5
  else
    Timeout := InfiniteWait;
  Ready := WaitForHandles(Slice(Handles, Count), Timeout);
  if (Ready >= 2) and (Ready < Count) then
    ReportHandleReady(Ready - 2);
end;

procedure TContentProcessRunner.LongWorkStep;
begin
  if not FContext.Connection.Broken then
    FContext.Connection.AnswerWaitingPings;
end;

procedure TContentProcessRunner.Run;
begin
  repeat
    DeliverPostedMessages;
    ServeChannel;
    if FShutdown or FContext.Connection.Broken then
      Break;
    DeliverPostedMessages;
    FinishTurn;
    if FContext.CrashRequested then
      { A crash on purpose (about:crash): a fault nothing catches. }
      PLongWord(nil)^ := 1;
    if FContext.HangRequested then
      { A hang on purpose (about:hang): busy for ever, answering nothing. }
      while True do
        FContext.HangRequested := True;
    WaitForWork;
  until False;
end;

function RunContentProcess(constref Options: TContentOptions): LongInt;
var
  Runner: TContentProcessRunner;
  Hello: string;
begin
  UseScale(Options.ScalePercent, Options.Dpi);
  if Options.ThemeKey <> '' then
    LoadThemeByKey(Options.ThemeKey);
  if Options.ScriptRunLimitMilliseconds = 0 then
    ScriptRunLimitMilliseconds := High(QWord) div 2
  else
    ScriptRunLimitMilliseconds := Options.ScriptRunLimitMilliseconds;
  { The script heap gets most of the memory the process may commit; the
    rest is for documents, layout, images and the program itself. }
  if Options.MemoryLimitMegabytes > 0 then
    ContextHeapLimit := Int64(Options.MemoryLimitMegabytes) * 1024 * 1024 * ScriptHeapShareEighths div 8;
  Hello := EnterSandbox(Options.Sandbox, Options.MemoryLimitMegabytes);
  WriteLn(StdErr, 'webcontent: ', CurrentProcessId, ' for ', Options.Site, ': ', Hello);
  Runner := TContentProcessRunner.Create(Options);
  try
    Runner.FContext.Connection.Send(IpcHello, 0,
      EncodeNumbers(WebIpcProtocolVersion, LongInt(CurrentProcessId)));
    Runner.Run;
  finally
    Runner.Free;
  end;
  Result := 0;
end;

end.
