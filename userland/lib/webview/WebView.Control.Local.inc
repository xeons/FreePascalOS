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

{ WebView.Control: the page engine in the program, as a child control
  covering the view; what it tells goes to the host as the view's. }

function InProcessFactory(View: TWebEngineView; Page: TWebPage): TScriptExecutor;
var
  Owner: TWebView;
begin
  Owner := TWebView(View.Parent);
  if Assigned(Owner.FScriptExecutorFactory) then
    Result := Owner.FScriptExecutorFactory(Owner, Page)
  else
    Result := DefaultScriptExecutorFactory(Owner, Page);
end;

procedure TWebView.EnsureEngine;
begin
  if FEngine <> nil then
    Exit;
  FModelChosen := True;
  FModel := ProcessModelInProcess;
  FEngine := TWebEngineView.Create(Self);
  FEngine.Align := AlignClient;
  FEngine.ScriptingEnabled := FScriptingEnabled;
  if Assigned(FScriptExecutorFactory) or Assigned(DefaultScriptExecutorFactory) then
    FEngine.ScriptExecutorFactory := @InProcessFactory;
  FEngine.OnTitleChanged := @EngineTitleChanged;
  FEngine.OnLocationChanged := @EngineLocationChanged;
  FEngine.OnLoadingStateChanged := @EngineLoadingStateChanged;
  FEngine.OnFaviconChanged := @EngineFaviconChanged;
  FEngine.OnStatusText := @EngineStatusText;
  FEngine.OnHistoryChanged := @EngineHistoryChanged;
  FEngine.OnZoomChanged := @EngineZoomChanged;
  FEngine.OnLinkClicked := @EngineLinkClicked;
  FEngine.OnDownloadRequested := @EngineDownloadRequested;
  FEngine.OnNavigationFailed := @EngineNavigationFailed;
  FEngine.OnContextMenuRequested := @EngineContextMenu;
  FEngine.OnConfirmUnload := @EngineConfirmUnload;
  FEngine.OnScriptAlert := @EngineScriptAlert;
  FEngine.OnScriptConfirm := @EngineScriptConfirm;
  FEngine.OnScriptPrompt := @EngineScriptPrompt;
  FEngine.OnConsoleMessage := @EngineConsole;
  FEngine.OnPopupBlocked := @EnginePopupBlocked;
  ApplyEngineOptions;
  if FZoom <> 1 then
    FEngine.Zoom := FZoom;
  FEngine.Navigable.Fetcher.AboutPageProvider := FAboutPageProvider;
  if Focused then
    FEngine.SetFocus;
end;

procedure TWebView.EngineTitleChanged(Sender: TWebEngineView; const Value: string);
begin
  TellTitle(Value);
  { The current entry's title is in HistoryEntries now (as a content
    process tells it with its history). }
  TellHistory;
end;

procedure TWebView.EngineLocationChanged(Sender: TWebEngineView; const Value: string);
begin
  TellLocation(Value);
end;

procedure TWebView.EngineLoadingStateChanged(Sender: TWebEngineView; State: TLoadingState);
begin
  TellLoadingState(State);
end;

procedure TWebView.EngineFaviconChanged(Sender: TWebEngineView);
var
  Copy_: TImage;
begin
  Copy_ := nil;
  if Sender.Favicon <> nil then
  begin
    Copy_ := TImage.Create(Sender.Favicon.Width, Sender.Favicon.Height);
    Move(Sender.Favicon.Line(0)^, Copy_.Line(0)^, Sender.Favicon.Width * Sender.Favicon.Height * 4);
  end;
  TellFavicon(Copy_);
end;

procedure TWebView.EngineStatusText(Sender: TWebEngineView; const Value: string);
begin
  TellStatus(Value);
end;

procedure TWebView.EngineHistoryChanged(Sender: TWebEngineView);
begin
  TellHistory;
end;

procedure TWebView.EngineZoomChanged(Sender: TWebEngineView);
begin
  TellZoom(Sender.Zoom);
end;

procedure TWebView.EngineLinkClicked(Sender: TWebEngineView; const Url: string; Disposition: TLinkDisposition;
  var Handled: Boolean);
begin
  TellLink(Url, Disposition, Handled);
end;

procedure TWebView.EngineDownloadRequested(Sender: TWebEngineView; constref Download: TDownloadInfo);
begin
  TellDownload(Download);
end;

procedure TWebView.EngineNavigationFailed(Sender: TWebEngineView; const Url, Reason: string);
begin
  TellFailure(Url, Reason);
end;

procedure TWebView.EngineContextMenu(Sender: TWebEngineView; constref Info: TWebContextInfo; var Handled: Boolean);
begin
  if Assigned(FOnContextMenuRequested) then
    FOnContextMenuRequested(Self, Info, Handled);
end;

function TWebView.EngineConfirmUnload(Sender: TWebEngineView): Boolean;
begin
  if Assigned(FOnConfirmUnload) then
    Result := FOnConfirmUnload(Self)
  else
    Result := True;
end;

procedure TWebView.EngineScriptAlert(Sender: TWebEngineView; const Value: string);
begin
  if Assigned(FOnScriptAlert) then
    FOnScriptAlert(Self, Value);
end;

function TWebView.EngineScriptConfirm(Sender: TWebEngineView; const Message: string): Boolean;
begin
  Result := False;
  if Assigned(FOnScriptConfirm) then
    Result := FOnScriptConfirm(Self, Message);
end;

function TWebView.EngineScriptPrompt(Sender: TWebEngineView; const Message, Default: string;
  out Answer: string): Boolean;
begin
  Result := False;
  Answer := '';
  if Assigned(FOnScriptPrompt) then
    Result := FOnScriptPrompt(Self, Message, Default, Answer);
end;

procedure TWebView.EngineConsole(Sender: TWebEngineView; const Level, Value: string);
begin
  TellConsole(Level, Value);
end;
