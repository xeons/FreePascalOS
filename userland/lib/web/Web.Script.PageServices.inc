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
  Web.Script.PageScripting: the page environment's services for the
  platform scripts - navigation timing from the loader, Web Storage
  (local storage saved a second after it changes), the media
  environment and screen, animation frames at the window's rendering
  opportunities, beacons and script fetches through the loader.
}

type
  TStorageSaveTask = class(TWebTask)
  public
    Environment: TPageScriptEnvironment;
    procedure Run; override;
  end;

  { An animation frame of a context: runs the platform scripts' frame
    callbacks while the context lives. }
  TPageFrameCallback = class(TAnimationFrameCallback)
  public
    Executor: TPageScriptExecutor;
    Context: TBindingContext;
    procedure Invoke(Timestamp: Double); override;
  end;

const
  StorageSaveDelay = 1000;

procedure TStorageSaveTask.Run;
begin
  Environment.FSaveScheduled := False;
  Environment.SaveStorage;
end;

procedure TPageFrameCallback.Invoke(Timestamp: Double);
begin
  if Executor.IsLiveContext(Context) then
    Context.CallPlatform('onAnimationFrame', [JsNumber(Context.Now)]);
end;

{ The loader of a context's document: its own (a page's or a loaded
  frame's), else its top-level window's (a script-made about:blank
  frame); nil when it has none or its document was left. }
function TPageScriptEnvironment.LoaderOf(Context: TObject): TObject;
var
  Index: Integer;
  Top: TObject;
begin
  for Index := 0 to High(FExecutor.FContexts) do
    if FExecutor.FContexts[Index].Context = Context then
    begin
      if FExecutor.FContexts[Index].Stopped then
        Exit(nil);
      Exit(FExecutor.FContexts[Index].Loader);
    end;
  Top := Context;
  if Context is TBindingContext then
    Top := TBindingContext(Context).TopContext;
  for Index := 0 to High(FExecutor.FContexts) do
    if (FExecutor.FContexts[Index].Context = Top) and not FExecutor.FContexts[Index].Stopped then
      Exit(FExecutor.FContexts[Index].Loader);
  Result := nil;
end;

function TPageScriptEnvironment.NavigationTiming(Context: TObject): TScriptNavigationTiming;
var
  Loader: TDocumentLoader;
begin
  Result := inherited NavigationTiming(Context);
  Loader := TDocumentLoader(LoaderOf(Context));
  { A script-made frame has no navigation of its own. }
  if (Loader <> nil) and (TBindingContext(Context).Document <> Loader.Document) then
    Exit;
  if Loader = nil then
    Exit;
  Result.Kind := Loader.Times.Kind;
  Result.RedirectCount := Loader.Times.RedirectCount;
  Result.NavigationStart := Loader.Times.NavigationStart;
  Result.FetchStart := Loader.Times.FetchStart;
  Result.RequestStart := Loader.Times.FetchStart;
  Result.ResponseStart := Loader.Times.ResponseStart;
  Result.ResponseEnd := Loader.Times.ResponseEnd;
  Result.DomInteractive := Loader.Times.DomInteractive;
  Result.DomContentLoadedEventStart := Loader.Times.DomContentLoadedStart;
  Result.DomContentLoadedEventEnd := Loader.Times.DomContentLoadedEnd;
  Result.DomComplete := Loader.Times.DomComplete;
  Result.LoadEventStart := Loader.Times.LoadEventStart;
  Result.LoadEventEnd := Loader.Times.LoadEventEnd;
  Result.NextHopProtocol := Loader.Times.Protocol;
  Result.TransferSize := Loader.Times.BytesReceived;
  Result.EncodedBodySize := Loader.Times.BytesReceived;
  Result.DecodedBodySize := Loader.Times.BytesReceived;
  Result.ResponseStatus := Loader.Times.Status;
end;

procedure TPageScriptEnvironment.SetLocalStorage(Value: TWebStorageRegistry);
begin
  if FLocalStorage = Value then
    Exit;
  SaveStorage;
  if FOwnsLocalStorage then
    FLocalStorage.Free;
  FLocalStorage := Value;
  FOwnsLocalStorage := False;
end;

{ The serialized origin storage is kept under ('' when the context may
  have none: not http, https or file, or a sandboxed frame's opaque
  origin). Local files share one origin, file://. }
function TPageScriptEnvironment.StorageOrigin(Context: TObject): string;
var
  Url: TUrlRecord;
  Origin: TUrlOrigin;
begin
  Result := '';
  if not (Context is TBindingContext) or not ParseUrl(OriginUrlOf(TBindingContext(Context)), Url) then
    Exit;
  if (Url.Scheme <> 'http') and (Url.Scheme <> 'https') and (Url.Scheme <> 'file') then
    Exit;
  if (Url.Scheme <> 'file') and DocumentOrigin(TBindingContext(Context).Document).Opaque then
    Exit;
  Origin := OriginOfUrl(Url);
  if Url.Scheme = 'file' then
    Result := 'file://'
  else
    Result := SerializeOrigin(Origin);
  if Result = 'null' then
    Result := '';
end;

function TPageScriptEnvironment.StorageArea(Context: TObject; Session: Boolean): TWebStorageArea;
var
  Serialized: string;
begin
  Result := nil;
  Serialized := StorageOrigin(Context);
  if Serialized = '' then
    Exit;
  if Session then
    Exit(FSessionStorage.SessionArea(Serialized));
  if FLocalStorage = nil then
  begin
    FLocalStorage := TWebStorageRegistry.Create('');
    FOwnsLocalStorage := True;
  end;
  Result := FLocalStorage.LocalArea(Serialized);
end;

{ ---- IndexedDB, the Cache API, navigator.storage ---- }

function TPageScriptEnvironment.PageStorage: TPageStorage;
begin
  if FStorageService = nil then
  begin
    FStorageService := TPageStorage.Create;
    FStorageService.IsLive := @FExecutor.IsLiveContext;
  end;
  FStorageService.Loop := FExecutor.FLoop;
  Result := FStorageService;
end;

function TPageScriptEnvironment.GetIndexedDb: TIndexedDbBackend;
begin
  Result := PageStorage.HostBackend;
end;

procedure TPageScriptEnvironment.SetIndexedDb(Value: TIndexedDbBackend);
begin
  PageStorage.HostBackend := Value;
end;

function TPageScriptEnvironment.IndexedDbAccess(Context: TObject): Integer;
begin
  if StorageOrigin(Context) = '' then
    Result := IndexedDbDenied
  else
    Result := IndexedDbAllowed;
end;

function TPageScriptEnvironment.IndexedDbExecute(Context: TObject; const Request: TBytes; out Reply: TBytes): Boolean;
begin
  Reply := PageStorage.Execute(Context, StorageOrigin(Context), Request);
  Result := True;
end;

function TPageScriptEnvironment.QueueScriptTask(Context: TObject; TaskId: Integer): Boolean;
begin
  Result := FExecutor.IsLiveContext(Context) and PageStorage.QueueTask(Context, TaskId);
end;

procedure TPageScriptEnvironment.StorageChanged(Context: TObject; Area: TWebStorageArea);
var
  Task: TStorageSaveTask;
begin
  if FSaveScheduled or not Area.Dirty or (Area.FileName = '') or (FExecutor.FLoop = nil) then
    Exit;
  Task := TStorageSaveTask.Create;
  Task.Environment := Self;
  Task.Source := TaskSourceTimer;
  Task.Group := Self;
  FSaveTask := FExecutor.FLoop.ScheduleTask(Task, StorageSaveDelay);
  FSaveScheduled := True;
end;

procedure TPageScriptEnvironment.SaveStorage;
begin
  if FLocalStorage <> nil then
    FLocalStorage.SaveAll;
end;

function TPageScriptEnvironment.MediaEnvironment: TCssMediaEnvironment;
begin
  Result := FExecutor.FNavigable.Sink.MediaEnvironment;
end;

function TPageScriptEnvironment.ScreenWidth: Integer;
begin
  Result := FScreenWidth;
  if Result <= 0 then
    Result := ViewportWidth;
end;

function TPageScriptEnvironment.ScreenHeight: Integer;
begin
  Result := FScreenHeight;
  if Result <= 0 then
    Result := ViewportHeight;
end;

function TPageScriptEnvironment.RequestAnimationFrame(Context: TObject): Boolean;
var
  Callback: TPageFrameCallback;
  Window: TObject;
begin
  Result := False;
  if not (Context is TBindingContext) then
    Exit;
  Window := TBindingContext(Context).Window;
  if not (Window is TWebWindow) or not FExecutor.IsLiveContext(Context) then
    Exit;
  Callback := TPageFrameCallback.Create;
  Callback.Executor := FExecutor;
  Callback.Context := TBindingContext(Context);
  TWebWindow(Window).RequestAnimationFrame(Callback);
  Result := True;
end;

procedure TPageScriptEnvironment.SendBeacon(Context: TObject; const Url: string; const Body: TBytes;
  const ContentType: string);
var
  Loader: TDocumentLoader;
begin
  Loader := TDocumentLoader(LoaderOf(Context));
  if Loader <> nil then
    FFetches.SendBeacon(Loader.Fetcher, Loader.Client, Url, Body, ContentType);
end;

function TPageScriptEnvironment.StartFetch(Context: TObject; const Request: TScriptFetchRequest;
  Sink: TScriptFetchSink): TObject;
begin
  Result := FFetches.Start(TDocumentLoader(LoaderOf(Context)), Request, Sink);
end;

procedure TPageScriptEnvironment.CancelFetch(Context: TObject; Handle: TObject);
begin
  FFetches.Cancel(Handle);
end;
