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
  What the browser's windows share (BrowserApp): the settings, the
  history, the bookmarks, the downloads, the search engines, saved
  passwords, the Error Console's messages, the browser's own pages,
  and the session - the open windows (asked of each window when it is
  saved), the recently closed tabs and windows.

  It opens windows (NewWindow), remembers a closed one and ends the
  browser with the last (WindowClosed), saves the session a moment
  after each change (session.txt, "running" until the browser ends, so
  a crash is seen at the next start), and starts: the session again
  after a crash or when the startup setting says so, else the home
  pages, plus any addresses given.

  Private browsing is the whole browser's, as it was in the browsers of
  that time: starting it puts the session aside, closes the windows and
  switches the network to cookies, cache and storage kept only in
  memory, with no history kept; stopping it drops all that and brings
  the session back.
}
unit Browser.Application;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes,
  Windowing.Messages,
  Controls.Timers,
  Browser.Settings,
  Browser.History,
  Browser.Bookmarks,
  Browser.Downloads,
  Browser.SearchEngines,
  Browser.Passwords,
  Browser.ConsoleLog,
  Browser.SessionStore,
  Browser.AboutPages;

const
  MessageDownloadChanged = MessageUser + 1;
  MessageCloseWindowLater = MessageUser + 2;

type
  TBrowserApplication = class(TMessageReceiver)
  private
    FSettings: TBrowserSettings;
    FHistory: THistoryStore;
    FBookmarks: TBookmarkStore;
    FDownloads: TDownloadManager;
    FEngines: TSearchEngineList;
    FPasswords: TPasswordStore;
    FConsole: TConsoleLog;
    FAboutPages: TAboutPages;
    FSession: TSession;
    FPutAside: TSession;
    FWindows: TList;
    FPrivate: Boolean;
    FSaveTimer: TTimer;
    FQuitting: Boolean;
    FDownloadsWindow: TObject;
    FActiveWindow: TObject;
    procedure SaveTimerFired(Sender: TTimer);
    procedure StoresChanged(Sender: TObject);
    function CaptureSession: TSession;
    procedure OpenSessionWindows(constref Session: TSession);
    procedure CloseAllWindows;
  public
    constructor Create;
    destructor Destroy; override;
    procedure ReceiveMessage(var Message: TPostedMessage); override;
    { The first windows (Addresses: given on the command line). }
    procedure Start(const Addresses: TStringArray);
    { A new window with a tab per address (none: the home pages); the
      window (a TBrowserWindow). }
    function NewWindow(const Addresses: TStringArray): TObject;
    { A window from the session (a closed one brought back). }
    function RestoreWindow(constref Window: TSessionWindow): TObject;
    { The window is closing: remembered among the closed ones. }
    procedure WindowClosed(Window: TObject);
    function WindowCount: Integer;
    function WindowAt(Index: Integer): TObject;
    { Ends the browser (asking first about several tabs, if set). }
    procedure Quit;
    { The session is to be saved soon. }
    procedure SessionChanged;
    procedure SaveSessionNow(Running: Boolean);
    { The settings changed (the Options window): every window follows. }
    procedure ApplySettings;
    procedure SaveSettings;
    { The chosen search engine ('' none); its URL is kept as SearchUrl. }
    procedure ChooseSearchEngine(const Name: string);
    procedure SaveSearchEngines;
    procedure StartPrivateBrowsing;
    procedure StopPrivateBrowsing;
    { Clears what Items says (Browser.Settings' ClearItems letters) from
      Since on (Unix time; 0 everything). }
    procedure ClearPrivateData(const Items: string; Since: Int64);
    { The Downloads window, made if need be (shown when Bring). }
    procedure ShowDownloadsWindow(Bring: Boolean);
    procedure DownloadsWindowClosed;
    { Starts a download and shows it as the settings say. }
    function StartDownload(const Url, FileName: string; const TargetPath: string = ''): TDownloadItem;
    function NowUnix: Int64;
    { Url in a new tab of the window used last (a new window if none). }
    procedure OpenInActiveWindow(const Url: string);
    { The browser window used last (nil: none). }
    property ActiveWindow: TObject read FActiveWindow write FActiveWindow;
    property Settings: TBrowserSettings read FSettings write FSettings;
    property History: THistoryStore read FHistory;
    property Bookmarks: TBookmarkStore read FBookmarks;
    property Downloads: TDownloadManager read FDownloads;
    property Engines: TSearchEngineList read FEngines;
    property Passwords: TPasswordStore read FPasswords;
    property Console: TConsoleLog read FConsole;
    property AboutPages: TAboutPages read FAboutPages;
    property Session: TSession read FSession write FSession;
    property PrivateBrowsing: Boolean read FPrivate;
    property Quitting: Boolean read FQuitting;
  end;

var
  BrowserApp: TBrowserApplication;

implementation

uses
  DateUtils,
  Windowing.Windows,
  Controls.MessageBoxes,
  Controls.Dialogs,
  WebView.Network,
  Browser.Profile,
  Browser.Output,
  Browser.MainWindow,
  Browser.DownloadsWindow;

const
  SessionSaveDelay = 2000;

constructor TBrowserApplication.Create;
var
  Folder: string;
begin
  inherited Create;
  FSettings := LoadBrowserSettings;
  SetHttp3Allowed(FSettings.Http3);
  Folder := BrowserProfileFolder;
  SetWebStorageFolder(Folder + '/storage');
  FHistory := THistoryStore.Create(Folder + '/history.txt');
  FHistory.Load;
  FHistory.Enabled := KeepsHistory(FSettings);
  FBookmarks := TBookmarkStore.Create(Folder + '/bookmarks.txt');
  FBookmarks.Load;
  FBookmarks.OnChanged := @StoresChanged;
  FDownloads := TDownloadManager.Create(Self, MessageDownloadChanged);
  if FSettings.RememberDownloads then
  begin
    FDownloads.ListPath := Folder + '/downloads.txt';
    FDownloads.LoadList;
  end;
  FDownloads.Folder := FSettings.DownloadFolder;
  FEngines := TSearchEngineList.Create;
  FEngines.Load(Folder + '/searchengines.txt');
  { A search URL set before there were engines becomes one. }
  if (FSettings.SearchEngine = '') and (FSettings.SearchUrl <> '') then
  begin
    if FEngines.IndexOfUrl(FSettings.SearchUrl) < 0 then
      FEngines.Add('Custom search', FSettings.SearchUrl, '');
    if FEngines.IndexOfUrl(FSettings.SearchUrl) >= 0 then
      FSettings.SearchEngine := FEngines[FEngines.IndexOfUrl(FSettings.SearchUrl)].Name;
  end;
  FPasswords := TPasswordStore.Create(Folder + '/passwords.txt');
  FPasswords.Load;
  FConsole := TConsoleLog.Create;
  FAboutPages := TAboutPages.Create(FHistory, FBookmarks, FDownloads);
  FWindows := TList.Create;
  FSaveTimer := TTimer.Create(Self);
  FSaveTimer.Interval := SessionSaveDelay;
  FSaveTimer.OnTimer := @SaveTimerFired;
end;

destructor TBrowserApplication.Destroy;
begin
  FSaveTimer.Free;
  FWindows.Free;
  FAboutPages.Free;
  FConsole.Free;
  FPasswords.Free;
  FEngines.Free;
  FDownloads.Free;
  FBookmarks.Free;
  FHistory.Free;
  inherited Destroy;
end;

function TBrowserApplication.NowUnix: Int64;
begin
  Result := DateTimeToUnix(LocalTimeToUniversal(Now));
end;

procedure TBrowserApplication.StoresChanged(Sender: TObject);
var
  Index: Integer;
begin
  for Index := 0 to FWindows.Count - 1 do
    TBrowserWindow(FWindows[Index]).BookmarksChanged;
end;

function TBrowserApplication.WindowCount: Integer;
begin
  Result := FWindows.Count;
end;

function TBrowserApplication.WindowAt(Index: Integer): TObject;
begin
  Result := TObject(FWindows[Index]);
end;

function TBrowserApplication.NewWindow(const Addresses: TStringArray): TObject;
var
  Window: TBrowserWindow;
  Pages: TStringArray;
  Index: Integer;
begin
  Window := TBrowserWindow.Create;
  FWindows.Add(Window);
  FActiveWindow := Window;
  Pages := Addresses;
  if Length(Pages) = 0 then
  begin
    if FPrivate then
    begin
      SetLength(Pages, 1);
      Pages[0] := 'about:privatebrowsing';
    end
    else if FSettings.Startup = StartupBlank then
    begin
      SetLength(Pages, 1);
      Pages[0] := 'about:blank';
    end
    else
      Pages := HomePages(FSettings);
  end;
  for Index := 0 to High(Pages) do
    Window.OpenTab(Pages[Index], Index = 0);
  Window.Show;
  Say('windows ' + IntToStr(FWindows.Count));
  SessionChanged;
  Result := Window;
end;

function TBrowserApplication.RestoreWindow(constref Window: TSessionWindow): TObject;
var
  Browser: TBrowserWindow;
begin
  Browser := TBrowserWindow.Create;
  FWindows.Add(Browser);
  Browser.RestoreSession(Window);
  Browser.Show;
  Say('windows ' + IntToStr(FWindows.Count));
  SessionChanged;
  Result := Browser;
end;

procedure TBrowserApplication.OpenSessionWindows(constref Session: TSession);
var
  Index: Integer;
begin
  for Index := 0 to High(Session.Windows) do
    RestoreWindow(Session.Windows[Index]);
end;

procedure TBrowserApplication.Start(const Addresses: TStringArray);
var
  Saved: TSession;
  Restore: Boolean;
begin
  Restore := False;
  if LoadSession(ProfileFile('session.txt'), Saved) then
  begin
    FSession.ClosedTabs := Saved.ClosedTabs;
    FSession.ClosedWindows := Saved.ClosedWindows;
    Restore := (Length(Saved.Windows) > 0) and (Saved.Running or (FSettings.Startup = StartupSession));
    if Restore and Saved.Running then
      Say('session restored after a crash')
    else if Restore then
      Say('session restored');
  end;
  if FSettings.AlwaysPrivate then
  begin
    FPrivate := True;
    SetPrivateBrowsing(True);
    FHistory.Enabled := False;
    Restore := False;
  end;
  if Restore then
  begin
    OpenSessionWindows(Saved);
    if Length(Addresses) > 0 then
      TBrowserWindow(FWindows[0]).OpenAddresses(Addresses);
  end
  else
    NewWindow(Addresses);
  SaveSessionNow(True);
end;

procedure TBrowserApplication.WindowClosed(Window: TObject);
var
  Index: Integer;
begin
  Index := FWindows.IndexOf(Window);
  if Index < 0 then
    Exit;
  if not FQuitting and (FWindows.Count > 1) and not FPrivate then
    RememberClosedWindow(FSession, TBrowserWindow(Window).CaptureSession, NowUnix);
  FWindows.Delete(Index);
  if FActiveWindow = Window then
  begin
    FActiveWindow := nil;
    if FWindows.Count > 0 then
      FActiveWindow := TObject(FWindows[0]);
  end;
  Say('windows ' + IntToStr(FWindows.Count));
  if (FWindows.Count = 0) and not FQuitting then
    Quit
  else
    SessionChanged;
end;

function TBrowserApplication.CaptureSession: TSession;
var
  Index: Integer;
begin
  Result := FSession;
  Result.Windows := nil;
  SetLength(Result.Windows, FWindows.Count);
  for Index := 0 to FWindows.Count - 1 do
    Result.Windows[Index] := TBrowserWindow(FWindows[Index]).CaptureSession;
end;

procedure TBrowserApplication.SessionChanged;
begin
  if FQuitting then
    Exit;
  FSaveTimer.Enabled := False;
  FSaveTimer.Enabled := True;
end;

procedure TBrowserApplication.SaveTimerFired(Sender: TTimer);
begin
  Sender.Enabled := False;
  SaveSessionNow(True);
end;

procedure TBrowserApplication.SaveSessionNow(Running: Boolean);
var
  Current: TSession;
begin
  { Private windows are never written: the session put aside is. }
  if FPrivate then
    Current := FPutAside
  else
    Current := CaptureSession;
  Current.Running := Running;
  SaveSession(Current, ProfileFile('session.txt'));
end;

procedure TBrowserApplication.CloseAllWindows;
var
  Window: TBrowserWindow;
begin
  FActiveWindow := nil;
  while FWindows.Count > 0 do
  begin
    Window := TBrowserWindow(FWindows[FWindows.Count - 1]);
    FWindows.Delete(FWindows.Count - 1);
    Window.CloseQuietly;
  end;
end;

procedure TBrowserApplication.OpenInActiveWindow(const Url: string);
var
  Pages: TStringArray;
begin
  if (FActiveWindow = nil) and (FWindows.Count > 0) then
    FActiveWindow := TObject(FWindows[0]);
  if FActiveWindow = nil then
  begin
    Pages := nil;
    SetLength(Pages, 1);
    Pages[0] := Url;
    NewWindow(Pages);
    Exit;
  end;
  TBrowserWindow(FActiveWindow).OpenTab(Url, True);
  TBrowserWindow(FActiveWindow).Activate;
end;

procedure TBrowserApplication.Quit;
var
  Index, Tabs: Integer;
begin
  if FQuitting then
    Exit;
  Tabs := 0;
  for Index := 0 to FWindows.Count - 1 do
    Inc(Tabs, TBrowserWindow(FWindows[Index]).TabCount);
  if FSettings.WarnClosingTabs and (Tabs > 1) and (FSettings.Startup <> StartupSession) and
     (FWindows.Count > 0) then
    if ShowMessageBox('Confirm close', 'You are about to close ' + IntToStr(FWindows.Count) + ' window(s) with ' +
      IntToStr(Tabs) + ' tabs. Are you sure you want to continue?', MessageOkCancel, SignWarning,
      TWindow(FWindows[0])) <> ResultOk then
      Exit;
  FQuitting := True;
  FSaveTimer.Enabled := False;
  if FPrivate then
    SaveSessionNow(False)
  else
  begin
    SaveSessionNow(False);
    if FSettings.ClearOnClose then
      ClearPrivateData(FSettings.ClearItems, 0);
  end;
  CloseAllWindows;
  Say('exit');
  QuitMessageLoop(0);
end;

procedure TBrowserApplication.ApplySettings;
var
  Index: Integer;
begin
  SetHttp3Allowed(FSettings.Http3);
  FHistory.Enabled := KeepsHistory(FSettings) and not FPrivate;
  FDownloads.Folder := FSettings.DownloadFolder;
  if FSettings.RememberDownloads then
    FDownloads.ListPath := ProfileFile('downloads.txt')
  else
    FDownloads.ListPath := '';
  SetHttpCacheLimit(Int64(FSettings.CacheMegabytes) * 1024 * 1024);
  if FSettings.AcceptCookies then
  begin
    if FSettings.ThirdPartyCookies then
      SetCookiePolicy(CookiesAccept, FSettings.CookiesAllowed.Split([',', ' '], TStringSplitOptions.ExcludeEmpty),
        FSettings.CookiesBlocked.Split([',', ' '], TStringSplitOptions.ExcludeEmpty))
    else
      SetCookiePolicy(CookiesRefuseThirdParty, FSettings.CookiesAllowed.Split([',', ' '],
        TStringSplitOptions.ExcludeEmpty), FSettings.CookiesBlocked.Split([',', ' '], TStringSplitOptions.ExcludeEmpty));
  end
  else
    SetCookiePolicy(CookiesRefuse, FSettings.CookiesAllowed.Split([',', ' '], TStringSplitOptions.ExcludeEmpty),
      FSettings.CookiesBlocked.Split([',', ' '], TStringSplitOptions.ExcludeEmpty));
  for Index := 0 to FWindows.Count - 1 do
    TBrowserWindow(FWindows[Index]).ApplySettings;
end;

procedure TBrowserApplication.SaveSettings;
begin
  SaveBrowserSettings(FSettings);
end;

procedure TBrowserApplication.ChooseSearchEngine(const Name: string);
var
  Index: Integer;
  Window: Integer;
begin
  Index := FEngines.IndexOf(Name);
  if Index < 0 then
  begin
    FSettings.SearchEngine := '';
    FSettings.SearchUrl := '';
  end
  else
  begin
    FSettings.SearchEngine := FEngines[Index].Name;
    FSettings.SearchUrl := FEngines[Index].Url;
  end;
  SaveSettings;
  Say('search-engine ' + FSettings.SearchEngine);
  for Window := 0 to FWindows.Count - 1 do
    TBrowserWindow(FWindows[Window]).SearchEnginesChanged;
end;

procedure TBrowserApplication.SaveSearchEngines;
var
  Window: Integer;
begin
  FEngines.Save(ProfileFile('searchengines.txt'));
  if (FSettings.SearchEngine <> '') and (FEngines.IndexOf(FSettings.SearchEngine) < 0) then
    ChooseSearchEngine('')
  else if FSettings.SearchEngine <> '' then
    ChooseSearchEngine(FSettings.SearchEngine)
  else
    for Window := 0 to FWindows.Count - 1 do
      TBrowserWindow(FWindows[Window]).SearchEnginesChanged;
end;

procedure TBrowserApplication.StartPrivateBrowsing;
var
  Pages: TStringArray;
begin
  if FPrivate then
    Exit;
  FPutAside := CaptureSession;
  FPutAside.Running := True;
  FQuitting := True;
  CloseAllWindows;
  FQuitting := False;
  FPrivate := True;
  SetPrivateBrowsing(True);
  FHistory.Enabled := False;
  Say('private on');
  Pages := nil;
  NewWindow(Pages);
end;

procedure TBrowserApplication.StopPrivateBrowsing;
var
  Pages: TStringArray;
begin
  if not FPrivate then
    Exit;
  FQuitting := True;
  CloseAllWindows;
  FQuitting := False;
  FPrivate := False;
  SetPrivateBrowsing(False);
  FHistory.Enabled := KeepsHistory(FSettings);
  Say('private off');
  if Length(FPutAside.Windows) > 0 then
    OpenSessionWindows(FPutAside)
  else
  begin
    Pages := nil;
    NewWindow(Pages);
  end;
  FPutAside := Default(TSession);
end;

procedure TBrowserApplication.ClearPrivateData(const Items: string; Since: Int64);
begin
  if Pos('h', Items) > 0 then
  begin
    if Since <= 0 then
      FHistory.Clear
    else
      FHistory.RemoveSince(Since);
    FSession.ClosedTabs := nil;
    FSession.ClosedWindows := nil;
  end;
  if Pos('d', Items) > 0 then
    FDownloads.ClearFinished;
  if Pos('c', Items) > 0 then
    ClearCookies;
  if Pos('a', Items) > 0 then
    ClearHttpCache;
  if Pos('s', Items) > 0 then
    FPasswords.Clear;
  if Pos('o', Items) > 0 then
    ClearWebStorage;
  Say('cleared ' + Items);
end;

procedure TBrowserApplication.ShowDownloadsWindow(Bring: Boolean);
begin
  if FDownloadsWindow = nil then
    FDownloadsWindow := TDownloadsWindow.CreateFor(FDownloads);
  TDownloadsWindow(FDownloadsWindow).Refresh;
  TDownloadsWindow(FDownloadsWindow).Show;
  if Bring then
    TDownloadsWindow(FDownloadsWindow).Activate;
end;

procedure TBrowserApplication.DownloadsWindowClosed;
begin
  FDownloadsWindow := nil;
end;

function TBrowserApplication.StartDownload(const Url, FileName: string; const TargetPath: string): TDownloadItem;
begin
  Result := FDownloads.Start(Url, FileName, TargetPath);
  Say('download ' + Result.FileName + ' started');
  if FSettings.ShowDownloads then
    ShowDownloadsWindow(False);
end;

procedure TBrowserApplication.ReceiveMessage(var Message: TPostedMessage);
const
  StateNames: array[TDownloadState] of string = ('running', 'done', 'failed', 'cancelled', 'paused');
var
  Item: TDownloadItem;
  Index: Integer;
begin
  if Message.Code = MessageCloseWindowLater then
  begin
    { A window that closed (its own events are over by now). }
    TObject(Message.Parameter1).Free;
    Exit;
  end;
  if Message.Code = MessageDownloadChanged then
  begin
    Item := TDownloadItem(Message.Parameter1);
    if FDownloads.IndexOf(Item) < 0 then
      Exit;
    if (Item.State <> DownloadRunning) and not Item.EndReported then
    begin
      Item.EndReported := True;
      Say('download ' + Item.FileName + ' ' + StateNames[Item.State]);
      FDownloads.Reap;
    end;
    for Index := 0 to FWindows.Count - 1 do
      TBrowserWindow(FWindows[Index]).DownloadChanged(Item);
    if FDownloadsWindow <> nil then
    begin
      TDownloadsWindow(FDownloadsWindow).ItemChanged(Item);
      if FSettings.CloseDownloadsWhenDone and (FDownloads.RunningCount = 0) and (Item.State = DownloadDone) then
        TDownloadsWindow(FDownloadsWindow).Hide;
    end;
    Exit;
  end;
  inherited ReceiveMessage(Message);
end;

end.
