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
  View > Page Source (Ctrl+U): a window of its own showing the page's
  source with its markup coloured (Browser.SourceColoring), in a web
  view of the browser's own (no scripts). The source is fetched again
  on a thread (from the HTTP cache when it holds the page; a local file
  is read). Its menus: File (Save Page As..., Close), Edit (Copy,
  Select All, Find...), View (Wrap Long Lines, Reload).
}
unit Browser.PageSource;

{$mode objfpc}
{$H+}

interface

procedure ShowPageSource(const Url: string);

implementation

uses
  SysUtils,
  Classes,
  Abi.SystemCalls,
  Windowing.Messages,
  Controls.Base,
  Controls.Window,
  Controls.Menus,
  Controls.Keys,
  Controls.FileDialog,
  WebView.Control,
  WebView.Network,
  Url.Records,
  Url.Parser,
  Http.Messages,
  Http.Client,
  Http.BodySinks,
  Http.Results,
  Web.Fetch.LocalFiles,
  Browser.SourceColoring,
  Browser.Downloads,
  Browser.Application,
  Browser.Output;

const
  MessageSourceFetched = MessageUser + 20;
  MaximumSourceBytes = 8 * 1024 * 1024;

type
  TPageSourceWindow = class;

  TSourceThread = class(TThread)
  private
    FWindow: TPageSourceWindow;
    FUrl: string;
  protected
    procedure Execute; override;
  public
    Source: string;
    ErrorText: string;
    constructor Create(Window: TPageSourceWindow; const Url: string);
  end;

  TPageSourceWindow = class(TControlWindow)
  private
    FUrl: string;
    FSource: string;
    FView: TWebView;
    FWrap: Boolean;
    FThread: TSourceThread;
    FMenuBar: TMenuBar;
    FWrapItem: TMenuItem;
    procedure Fetch;
    procedure ShowSource;
    procedure SaveChosen(Item: TMenuItem);
    procedure CloseChosen(Item: TMenuItem);
    procedure CopyChosen(Item: TMenuItem);
    procedure SelectAllChosen(Item: TMenuItem);
    procedure WrapChosen(Item: TMenuItem);
    procedure ReloadChosen(Item: TMenuItem);
  protected
    procedure CloseRequested; override;
  public
    constructor Create(const Url: string);
    destructor Destroy; override;
    procedure ReceiveMessage(var Message: TPostedMessage); override;
  end;

constructor TSourceThread.Create(Window: TPageSourceWindow; const Url: string);
begin
  FWindow := Window;
  FUrl := Url;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TSourceThread.Execute;
var
  Parsed: TUrlRecord;
  Path: string;
  Lines: TStringList;
  Request: THttpRequest;
  Response: THttpResponse;
  Sink: THttpMemorySink;
  Outcome: THttpResult;
begin
  try
    if not ParseUrl(FUrl, Parsed) then
      ErrorText := 'not a URL'
    else if Parsed.Scheme = 'file' then
    begin
      if LocalPathOfUrl(Parsed, Path) and FileExists(Path) then
      begin
        Lines := TStringList.Create;
        try
          Lines.LoadFromFile(Path);
          Source := Lines.Text;
        finally
          Lines.Free;
        end;
      end
      else
        ErrorText := 'the file is not there';
    end
    else if (Parsed.Scheme = 'http') or (Parsed.Scheme = 'https') then
    begin
      Response := nil;
      Sink := THttpMemorySink.Create(MaximumSourceBytes);
      Request := THttpRequest.Create('GET', Parsed);
      try
        Outcome := SharedNetworkContext.Client.Fetch(Request, Sink, Response);
        if HttpSucceeded(Outcome) then
          Source := Sink.Text
        else
          ErrorText := Outcome.Text;
      finally
        Response.Free;
        Request.Free;
        Sink.Free;
      end;
    end
    else
      ErrorText := 'the source of ' + Parsed.Scheme + ': pages cannot be shown';
  except
    on Error: Exception do
      ErrorText := Error.Message;
  end;
  PostMessage(FWindow, MessageSourceFetched);
end;

constructor TPageSourceWindow.Create(const Url: string);
var
  Menu: TMenuItem;
begin
  inherited Create('Source of: ' + Url + ' - Browser', 100, 80, 760, 560);
  IconName := 'app-web-browser';
  FUrl := Url;
  FWrap := True;
  FMenuBar := TMenuBar.Create(Root);
  Menu := FMenuBar.Menu.Add('&File');
  Menu.Add('Save Page &As...', @SaveChosen, 'Ctrl+S');
  Menu.AddSeparator;
  AddItemAccelerator(Self, Menu.Add('&Close', @CloseChosen, 'Ctrl+W'), KeyW, ModifierControl);
  Menu := FMenuBar.Menu.Add('&Edit');
  Menu.Add('&Copy', @CopyChosen, 'Ctrl+C');
  Menu.Add('Select &All', @SelectAllChosen, 'Ctrl+A');
  Menu := FMenuBar.Menu.Add('&View');
  FWrapItem := Menu.Add('&Wrap Long Lines', @WrapChosen);
  FWrapItem.Checked := FWrap;
  AddItemAccelerator(Self, Menu.Add('&Reload', @ReloadChosen, 'F5'), KeyF5, 0);
  FView := TWebView.Create(Root);
  FView.ProcessModel := ProcessModelInProcess;
  FView.ScriptingEnabled := False;
  FView.Align := AlignClient;
  FView.LoadHtml(ColoredSourcePage('Loading...', Url, FWrap), 'about:blank');
  Fetch;
end;

destructor TPageSourceWindow.Destroy;
begin
  if FThread <> nil then
  begin
    FThread.WaitFor;
    FThread.Free;
  end;
  inherited Destroy;
end;

procedure TPageSourceWindow.Fetch;
begin
  if FThread <> nil then
    Exit;
  FThread := TSourceThread.Create(Self, FUrl);
end;

procedure TPageSourceWindow.ShowSource;
begin
  FView.LoadHtml(ColoredSourcePage(FSource, FUrl, FWrap), 'about:blank');
end;

procedure TPageSourceWindow.ReceiveMessage(var Message: TPostedMessage);
begin
  if Message.Code = MessageSourceFetched then
  begin
    if FThread = nil then
      Exit;
    FThread.WaitFor;
    if FThread.ErrorText <> '' then
      FSource := 'The source could not be fetched: ' + FThread.ErrorText
    else
      FSource := FThread.Source;
    FreeAndNil(FThread);
    ShowSource;
    Say('page-source ' + IntToStr(Length(FSource)));
    Exit;
  end;
  inherited ReceiveMessage(Message);
end;

procedure TPageSourceWindow.CloseRequested;
begin
  Hide;
  if FThread = nil then
    PostMessage(BrowserApp, MessageCloseWindowLater, PtrInt(Self));
end;

procedure TPageSourceWindow.SaveChosen(Item: TMenuItem);
var
  Path: string;
begin
  if ChooseFileToSave('Save Page As', DownloadsFolder, '*', Path, FileNameOfUrl(FUrl)) then
    BrowserApp.StartDownload(FUrl, ExtractFileName(Path), Path);
end;

procedure TPageSourceWindow.CloseChosen(Item: TMenuItem);
begin
  CloseRequested;
end;

procedure TPageSourceWindow.CopyChosen(Item: TMenuItem);
begin
  FView.CopySelection;
end;

procedure TPageSourceWindow.SelectAllChosen(Item: TMenuItem);
begin
  FView.SelectAll;
end;

procedure TPageSourceWindow.WrapChosen(Item: TMenuItem);
begin
  FWrap := not FWrap;
  FWrapItem.Checked := FWrap;
  ShowSource;
end;

procedure TPageSourceWindow.ReloadChosen(Item: TMenuItem);
begin
  Fetch;
end;

procedure ShowPageSource(const Url: string);
var
  Window: TPageSourceWindow;
begin
  if Url = '' then
    Exit;
  Window := TPageSourceWindow.Create(Url);
  Window.Show;
  Say('page-source open ' + Url);
end;

end.
