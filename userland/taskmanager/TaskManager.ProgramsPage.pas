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
  The Programs tab: the programs with windows, by their windows'
  titles, as the display server lists them (the windows of this user's
  programs, every program's for root), with what state each window is
  in and its process.

  Switch To (or a double click) brings a window forward. End Program
  asks its program to end, as closing it would - a program with
  unsaved work asks what to do with it - and if the program still runs
  a few seconds later, offers to end it outright: it may have stopped
  responding.
}
unit TaskManager.ProgramsPage;

{$mode objfpc}
{$H+}

interface

uses
  Controls.Base,
  Controls.Window,
  Controls.Buttons,
  Controls.ListView,
  Windowing.WindowList,
  TaskManager.Sampler;

type
  TProgramsPage = class(TControl)
  private
    FWindow: TControlWindow;
    FSampler: TUsageSampler;
    FList: TListView;
    FSwitchButton: TButton;
    FEndButton: TButton;
    FWindows: TListedWindows;
    { What was told last, so the list is told again only when it
      changes. }
    FToldList: string;
    { The program End Program asked to end, waited for (0: none). }
    FPendingProcessId: QWord;
    FPendingTitle: string;
    function SelectedWindow(out Window: TListedWindow): Boolean;
    function RowIndexOf(WindowId: LongWord): LongInt;
    procedure TellList;
    procedure SwitchClicked(Sender: TControl);
    procedure EndClicked(Sender: TControl);
  protected
    procedure Layout; override;
  public
    constructor CreatePage(AParent: TControl; Window: TControlWindow; Sampler: TUsageSampler);
    { Lists the windows again. }
    procedure Update;
    { The wait for a program asked to end is over: if it still runs,
      offers to end it outright. }
    procedure EndWaitIsOver;
    procedure TellPlaces;
  end;

const
  { How long a program asked to end has before it is offered to end it
    outright, and the timer that measures it (the main window's). }
  EndProgramWaitMilliseconds = 5000;
  EndProgramTimer = 2;

implementation

uses
  SysUtils,
  Drawing.Rectangles,
  Abi.SystemCalls,
  Sys.Errors,
  Sys.ProcessList,
  Sys.Notifications,
  Sys.Processes,
  Util.Messages,
  Windowing.Protocol,
  Windowing.Connection,
  Windowing.Shell,
  Controls.Dialogs,
  Controls.MessageBoxes,
  TaskManager.ProcessActions,
  TaskManager.EndWatch,
  TaskManager.Output;

const
  { Logical units. }
  Margin = 6;
  ButtonWidth = 100;
  ButtonHeight = 24;
  ButtonGap = 6;
  ColumnTitle = 0;
  ColumnStatus = 1;
  ColumnProcess = 2;

constructor TProgramsPage.CreatePage(AParent: TControl; Window: TControlWindow; Sampler: TUsageSampler);
begin
  inherited Create(AParent);
  FWindow := Window;
  FSampler := Sampler;
  FList := TListView.Create(Self);
  FList.AddColumn('Program', 300);
  FList.AddColumn('Status', 90);
  FList.AddColumn('PID', 60);
  FList.SortOnHeaderClick := True;
  FList.OnActivate := @SwitchClicked;
  FSwitchButton := TButton.Create(Self);
  FSwitchButton.Text := '&Switch To';
  FSwitchButton.OnClick := @SwitchClicked;
  FEndButton := TButton.Create(Self);
  FEndButton.Text := '&End Program';
  FEndButton.OnClick := @EndClicked;
end;

procedure TProgramsPage.Layout;
var
  Width: LongInt;
  Height: LongInt;
  BarTop: LongInt;
begin
  Width := Unscaled(RectangleWidth(PixelBounds));
  Height := Unscaled(RectangleHeight(PixelBounds));
  BarTop := Height - Margin - ButtonHeight;
  FList.AssignBounds(Margin, Margin, Width - 2 * Margin, BarTop - 2 * Margin);
  FEndButton.AssignBounds(Width - Margin - ButtonWidth, BarTop, ButtonWidth, ButtonHeight);
  FSwitchButton.AssignBounds(Width - Margin - 2 * ButtonWidth - ButtonGap, BarTop, ButtonWidth, ButtonHeight);
  inherited Layout;
end;

function StatusOf(Flags: LongWord): string;
begin
  if (Flags and ShellWindowMinimized) <> 0 then
    Result := 'Minimized'
  else if (Flags and ShellWindowVisible) = 0 then
    Result := 'Hidden'
  else
    Result := 'Running';
end;

function TProgramsPage.RowIndexOf(WindowId: LongWord): LongInt;
var
  Index: LongInt;
begin
  for Index := 0 to FList.RowCount - 1 do
    if LongWord(PtrUInt(FList.Items[Index].Data)) = WindowId then
      Exit(Index);
  Result := -1;
end;

procedure TProgramsPage.Update;
var
  Index: LongInt;
  RowIndex: LongInt;
  Present: Boolean;
  Listed: LongInt;
begin
  if not ListOtherWindows(FWindows) then
    Exit;
  for RowIndex := FList.RowCount - 1 downto 0 do
  begin
    Present := False;
    for Index := 0 to High(FWindows) do
      if FWindows[Index].Id = LongWord(PtrUInt(FList.Items[RowIndex].Data)) then
        Present := True;
    if not Present then
      FList.DeleteRow(RowIndex);
  end;
  for Index := 0 to High(FWindows) do
  begin
    Listed := RowIndexOf(FWindows[Index].Id);
    if Listed < 0 then
    begin
      Listed := FList.AddRow(['']);
      FList.Items[Listed].Data := Pointer(PtrUInt(FWindows[Index].Id));
    end;
    FList.Cells[Listed, ColumnTitle] := FWindows[Index].Title;
    FList.Cells[Listed, ColumnStatus] := StatusOf(FWindows[Index].Flags);
    FList.Cells[Listed, ColumnProcess] := IntToStr(FWindows[Index].ProcessId);
  end;
  TellList;
end;

{ "program WINDOW PID TITLE" for each, and where its row is, when the
  list changed. }
procedure TProgramsPage.TellList;
var
  Index: LongInt;
  Listed: LongInt;
  Summary: string;
  Cell: TRectangle;
begin
  { The tab's page is what is shown or hidden; shown again, the list is
    told again. }
  if not Parent.Visible then
  begin
    FToldList := '';
    Exit;
  end;
  Summary := '';
  for Index := 0 to High(FWindows) do
    Summary := Summary + IntToStr(FWindows[Index].Id) + ' ' + FWindows[Index].Title + ';';
  if Summary = FToldList then
    Exit;
  FToldList := Summary;
  Say('programs ' + IntToStr(Length(FWindows)));
  for Index := 0 to High(FWindows) do
  begin
    Say('program ' + IntToStr(FWindows[Index].Id) + ' ' + IntToStr(FWindows[Index].ProcessId) + ' ' +
      FWindows[Index].Title);
    Listed := RowIndexOf(FWindows[Index].Id);
    if Listed < 0 then
      Continue;
    Cell := FList.ItemBounds(Listed);
    SayPlace('program-' + IntToStr(FWindows[Index].Id), FWindow, FList.PixelBounds.Left + Cell.Left + Scaled(40),
      FList.PixelBounds.Top + (Cell.Top + Cell.Bottom) div 2);
  end;
end;

function TProgramsPage.SelectedWindow(out Window: TListedWindow): Boolean;
var
  Index: LongInt;
  WindowId: LongWord;
begin
  Result := False;
  if FList.ItemIndex < 0 then
    Exit;
  WindowId := LongWord(PtrUInt(FList.Items[FList.ItemIndex].Data));
  for Index := 0 to High(FWindows) do
    if FWindows[Index].Id = WindowId then
    begin
      Window := FWindows[Index];
      Exit(True);
    end;
end;

procedure TProgramsPage.SwitchClicked(Sender: TControl);
var
  Window: TListedWindow;
begin
  if not SelectedWindow(Window) then
    Exit;
  Say('switch ' + IntToStr(Window.Id));
  ManageWindow(Window.Id, ManageActivate);
end;

procedure TProgramsPage.EndClicked(Sender: TControl);
var
  Window: TListedWindow;
  Error: LongInt;
begin
  if not SelectedWindow(Window) then
    Exit;
  Error := AskProcessToEnd(Window.ProcessId, EndReasonAsked);
  if Error <> ErrorNone then
  begin
    Say('error ' + Window.Title + ': ' + ErrorText(Error));
    ShowMessageBox('Task Manager', 'Could not end ' + Window.Title + ':'#10#10 + ErrorText(Error),
      MessageOk, SignError, FWindow);
    Exit;
  end;
  Say('asked ' + IntToStr(Window.ProcessId));
  WatchForEnd(Window.ProcessId);
  FPendingProcessId := Window.ProcessId;
  FPendingTitle := Window.Title;
  FWindow.StartTimer(EndProgramTimer, EndProgramWaitMilliseconds);
end;

procedure TProgramsPage.EndWaitIsOver;
var
  Details: TProcessDetails;
begin
  FWindow.StopTimer(EndProgramTimer);
  if FPendingProcessId = 0 then
    Exit;
  if not GetProcessDetails(FPendingProcessId, Details) or (Details.State = ProcessStateExiting) then
  begin
    FPendingProcessId := 0;
    Exit;
  end;
  Say('not-responding ' + IntToStr(FPendingProcessId));
  if ShowMessageBox('Task Manager', FPendingTitle + ' has not ended.'#10#10 +
    'It may have stopped responding. End it now?'#10 + 'Anything it has not saved is lost.', MessageYesNo,
    SignWarning, FWindow) = ResultYes then
  begin
    if TerminateProgram(FPendingProcessId, EndedOutrightStatus) = ErrorNone then
      Say('ended-now ' + IntToStr(FPendingProcessId));
  end;
  FPendingProcessId := 0;
end;

procedure TProgramsPage.TellPlaces;
begin
  SayControlPlace('switch-to', FWindow, FSwitchButton);
  SayControlPlace('end-program', FWindow, FEndButton);
end;

end.
