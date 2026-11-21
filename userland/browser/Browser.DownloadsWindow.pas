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
  The Downloads window (Tools > Downloads, Ctrl+J): a window of its own
  listing the downloads, newest first - the file, how far it got (the
  bytes, the total, the speed and the time left while it runs) and
  where from - with a search box. For the one chosen: Pause or Resume,
  Cancel, Retry, Open (a page or a picture in a tab), Show in Folder
  (the file manager) and Remove from List; Clear List takes off every
  finished one. Enter opens, Delete removes.
}
unit Browser.DownloadsWindow;

{$mode objfpc}
{$H+}

interface

uses
  Controls.Base,
  Controls.Window,
  Controls.Panels,
  Controls.Buttons,
  Controls.EditBox,
  Controls.ListView,
  Controls.ImageList,
  Browser.Downloads;

type
  TDownloadsWindow = class(TControlWindow)
  private
    FManager: TDownloadManager;
    FSearch: TEditBox;
    FList: TListView;
    FPause, FCancel, FRetry, FOpen, FShow, FRemove, FClear: TButton;
    function Chosen: TDownloadItem;
    procedure SearchChanged(Sender: TControl);
    procedure RowChosen(Sender: TControl);
    procedure RowActivated(Sender: TControl);
    procedure PauseClicked(Sender: TControl);
    procedure CancelClicked(Sender: TControl);
    procedure RetryClicked(Sender: TControl);
    procedure OpenClicked(Sender: TControl);
    procedure ShowClicked(Sender: TControl);
    procedure RemoveClicked(Sender: TControl);
    procedure ClearClicked(Sender: TControl);
    procedure UpdateButtons;
    function RowOf(Item: TDownloadItem): LongInt;
    procedure SetRow(Row: LongInt; Item: TDownloadItem);
  protected
    procedure CloseRequested; override;
  public
    constructor CreateFor(Manager: TDownloadManager);
    procedure Refresh;
    procedure ItemChanged(Item: TDownloadItem);
  end;

{ A download's state as the list shows it ("1.2 MB of 3.4 MB (200 KB/s)
  - 11 seconds left", "Done: 3.4 MB", "Paused"...). }
function DownloadStatusText(Item: TDownloadItem): string;

implementation

uses
  Controls.LayoutRules,
  SysUtils,
  Controls.Labels,
  Browser.Application,
  Browser.Launch,
  Browser.Output;

function TimeLeftText(Seconds: Int64): string;
begin
  if Seconds < 60 then
    Result := IntToStr(Seconds) + ' seconds left'
  else if Seconds < 3600 then
    Result := IntToStr(Seconds div 60) + ' minutes left'
  else
    Result := IntToStr(Seconds div 3600) + ' hours left';
end;

function DownloadStatusText(Item: TDownloadItem): string;
begin
  case Item.State of
    DownloadRunning:
      begin
        if Item.Total > 0 then
          Result := SizeText(Item.Received) + ' of ' + SizeText(Item.Total)
        else
          Result := SizeText(Item.Received);
        if Item.BytesPerSecond > 0 then
        begin
          Result := Result + ' (' + SizeText(Item.BytesPerSecond) + '/sec)';
          if Item.Total > Item.Received then
            Result := Result + ' - ' + TimeLeftText((Item.Total - Item.Received) div Item.BytesPerSecond);
        end;
      end;
    DownloadDone:
      Result := 'Done: ' + SizeText(Item.Received);
    DownloadFailed:
      Result := 'Failed: ' + Item.ErrorText;
    DownloadCancelled:
      Result := 'Canceled';
    DownloadPaused:
      if Item.Total > 0 then
        Result := 'Paused - ' + SizeText(Item.Received) + ' of ' + SizeText(Item.Total)
      else
        Result := 'Paused - ' + SizeText(Item.Received);
  end;
end;

constructor TDownloadsWindow.CreateFor(Manager: TDownloadManager);
var
  Top, Bottom: TPanel;

  function AddButton(Parent: TControl; const Text: string; Handler: TControlEvent): TButton;
  begin
    Result := TButton.Create(Parent);
    Result.Text := Text;
    Result.AutoSize := True;
    Result.Align := AlignLeft;
    Result.Margins := MakeSpacing(4, 5, 0, 5);
    Result.OnClick := Handler;
  end;

begin
  inherited Create('Downloads', 200, 120, 560, 380);
  IconName := 'folder-downloads';
  FManager := Manager;
  Top := TPanel.Create(Root);
  Top.Edge := PanelFlat;
  Top.Align := AlignTop;
  Top.SetBounds(0, 0, 400, 32);
  FSearch := TEditBox.Create(Top);
  FSearch.Align := AlignClient;
  FSearch.Margins := MakeSpacing(6, 5, 6, 5);
  FSearch.Placeholder := 'Search...';
  FSearch.OnChange := @SearchChanged;
  Bottom := TPanel.Create(Root);
  Bottom.Edge := PanelFlat;
  Bottom.Align := AlignBottom;
  Bottom.SetBounds(0, 0, 400, 34);
  FPause := AddButton(Bottom, '&Pause', @PauseClicked);
  FCancel := AddButton(Bottom, '&Cancel', @CancelClicked);
  FRetry := AddButton(Bottom, 'Re&try', @RetryClicked);
  FOpen := AddButton(Bottom, '&Open', @OpenClicked);
  FShow := AddButton(Bottom, '&Show in Folder', @ShowClicked);
  FRemove := AddButton(Bottom, '&Remove', @RemoveClicked);
  FClear := TButton.Create(Bottom);
  FClear.Text := 'Clear &List';
  FClear.AutoSize := True;
  FClear.Align := AlignRight;
  FClear.Margins := MakeSpacing(4, 5, 6, 5);
  FClear.OnClick := @ClearClicked;
  FList := TListView.Create(Root);
  FList.Align := AlignClient;
  FList.Margins := MakeSpacing(6, 0, 6, 0);
  FList.AddColumn('File', 190);
  FList.AddColumn('Status', 220);
  FList.AddColumn('From', 120);
  FList.OnChange := @RowChosen;
  FList.OnActivate := @RowActivated;
  Refresh;
end;

procedure TDownloadsWindow.CloseRequested;
begin
  Hide;
end;

function TDownloadsWindow.Chosen: TDownloadItem;
var
  Row: LongInt;
begin
  Result := nil;
  Row := FList.ItemIndex;
  if Row < 0 then
    Exit;
  Result := TDownloadItem(FList.Items[Row].Data);
  if FManager.IndexOf(Result) < 0 then
    Result := nil;
end;

procedure TDownloadsWindow.SetRow(Row: LongInt; Item: TDownloadItem);
var
  Host: string;
begin
  Host := Item.Url;
  if Pos('://', Host) > 0 then
  begin
    Host := Copy(Host, Pos('://', Host) + 3, MaxInt);
    if Pos('/', Host) > 0 then
      Host := Copy(Host, 1, Pos('/', Host) - 1);
  end;
  FList.Cells[Row, 0] := Item.FileName;
  FList.Cells[Row, 1] := DownloadStatusText(Item);
  FList.Cells[Row, 2] := Host;
end;

procedure TDownloadsWindow.Refresh;
var
  Index: Integer;
  Row: LongInt;
  Item: TDownloadItem;
  Needle: string;
begin
  FList.Clear;
  Needle := LowerCase(Trim(FSearch.Text));
  for Index := 0 to FManager.Count - 1 do
  begin
    Item := FManager.Items[Index];
    if (Needle <> '') and (Pos(Needle, LowerCase(Item.FileName + ' ' + Item.Url)) = 0) then
      Continue;
    Row := FList.AddRow(['', '', '']);
    FList.Items[Row].Data := Item;
    SetRow(Row, Item);
  end;
  UpdateButtons;
end;

function TDownloadsWindow.RowOf(Item: TDownloadItem): LongInt;
var
  Row: LongInt;
begin
  for Row := 0 to FList.RowCount - 1 do
    if FList.Items[Row].Data = Pointer(Item) then
      Exit(Row);
  Result := -1;
end;

procedure TDownloadsWindow.ItemChanged(Item: TDownloadItem);
var
  Row: LongInt;
begin
  Row := RowOf(Item);
  if Row < 0 then
    Refresh
  else
    SetRow(Row, Item);
  UpdateButtons;
end;

procedure TDownloadsWindow.UpdateButtons;
var
  Item: TDownloadItem;
begin
  Item := Chosen;
  FPause.Enabled := (Item <> nil) and (Item.State in [DownloadRunning, DownloadPaused]);
  if (Item <> nil) and (Item.State = DownloadPaused) then
    FPause.Text := 'Res&ume'
  else
    FPause.Text := '&Pause';
  FCancel.Enabled := (Item <> nil) and (Item.State in [DownloadRunning, DownloadPaused]);
  FRetry.Enabled := (Item <> nil) and (Item.State in [DownloadFailed, DownloadCancelled]);
  FOpen.Enabled := (Item <> nil) and (Item.State = DownloadDone);
  FShow.Enabled := (Item <> nil) and (Item.State = DownloadDone);
  FRemove.Enabled := (Item <> nil) and (Item.State <> DownloadRunning);
end;

procedure TDownloadsWindow.SearchChanged(Sender: TControl);
begin
  Refresh;
end;

procedure TDownloadsWindow.RowChosen(Sender: TControl);
begin
  UpdateButtons;
end;

procedure TDownloadsWindow.RowActivated(Sender: TControl);
begin
  OpenClicked(Sender);
end;

procedure TDownloadsWindow.PauseClicked(Sender: TControl);
var
  Item: TDownloadItem;
begin
  Item := Chosen;
  if Item = nil then
    Exit;
  if Item.State = DownloadPaused then
  begin
    FManager.Resume(Item);
    Say('download ' + Item.FileName + ' resumed');
  end
  else
  begin
    FManager.Pause(Item);
    Say('download ' + Item.FileName + ' pausing');
  end;
  ItemChanged(Item);
end;

procedure TDownloadsWindow.CancelClicked(Sender: TControl);
begin
  if Chosen <> nil then
    FManager.Cancel(Chosen);
end;

procedure TDownloadsWindow.RetryClicked(Sender: TControl);
begin
  if Chosen <> nil then
  begin
    FManager.Retry(Chosen);
    ItemChanged(Chosen);
  end;
end;

procedure TDownloadsWindow.OpenClicked(Sender: TControl);
var
  Item: TDownloadItem;
begin
  Item := Chosen;
  if (Item = nil) or (Item.State <> DownloadDone) then
    Exit;
  BrowserApp.OpenInActiveWindow('file://' + Item.Path);
end;

procedure TDownloadsWindow.ShowClicked(Sender: TControl);
begin
  if Chosen <> nil then
    ShowFolder(ExtractFileDir(Chosen.Path));
end;

procedure TDownloadsWindow.RemoveClicked(Sender: TControl);
begin
  if Chosen <> nil then
  begin
    FManager.Remove(Chosen);
    Refresh;
  end;
end;

procedure TDownloadsWindow.ClearClicked(Sender: TControl);
begin
  FManager.ClearFinished;
  Refresh;
  Say('downloads cleared');
end;

end.
