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
  The task manager's window: the menus, the three tabs (Programs,
  Processes, Performance), and a status bar with the number of
  processes, how busy the processors are and how much memory is in use.

  It looks at the system at the chosen speed (View > Update Speed: twice
  a second, every second, every four seconds, or paused; Refresh Now,
  F5, looks at once) and brings every tab up to date. The window's
  size, the tab, the Processes list's sort and the speed are kept in
  the user's settings (TaskManager.Settings).
}
unit TaskManager.MainWindow;

{$mode objfpc}
{$H+}

interface

uses
  Controls.Base,
  Controls.Window,
  Controls.Menus,
  Controls.StatusBar,
  Controls.TabControl,
  TaskManager.Sampler,
  TaskManager.ProgramsPage,
  TaskManager.ProcessesPage,
  TaskManager.PerformancePage;

type
  TTaskManagerWindow = class(TControlWindow)
  private
    FSampler: TUsageSampler;
    FMenuBar: TMenuBar;
    FStatusBar: TStatusBar;
    FTabs: TTabControl;
    FProgramsPage: TProgramsPage;
    FProcessesPage: TProcessesPage;
    FPerformancePage: TPerformancePage;
    FSpeedItems: array[0..3] of TMenuItem;
    FUpdateMilliseconds: LongWord;
    { Where the window was when the places were told (the server may
      move a new window to fit the display). }
    FToldLeft: LongInt;
    FToldTop: LongInt;
    procedure BuildMenus;
    procedure BuildPages;
    procedure PlaceStatusPanels;
    procedure ShowStatus;
    procedure SetUpdateSpeed(Milliseconds: LongWord);
    procedure TellTabPlaces;
    procedure TabChanged(Sender: TControl);
    procedure SortChanged(Column: LongInt; Ascending: Boolean);
    procedure ExitChosen(Item: TMenuItem);
    procedure RefreshChosen(Item: TMenuItem);
    procedure SpeedChosen(Item: TMenuItem);
    procedure AboutChosen(Item: TMenuItem);
  protected
    procedure Resized; override;
    procedure TimerFired(TimerId: LongWord); override;
    procedure CloseRequested; override;
  public
    constructor Create;
    destructor Destroy; override;
    { Looks at the system again and brings every tab up to date. }
    procedure Refresh;
    { Starts looking at the chosen speed, and says where things are. }
    procedure Start;
  end;

implementation

uses
  SysUtils,
  Drawing.Rectangles,
  Windowing.Connection,
  Windowing.Windows,
  Controls.Keys,
  Controls.MessageBoxes,
  TaskManager.Settings,
  TaskManager.Formatting,
  TaskManager.EndWatch,
  TaskManager.Output;

const
  ProgramName = 'Task Manager';
  UpdateTimer = 1;
  { Logical units: the status bar's panels. }
  StatusPanelWidth = 150;
  TabNames: array[0..2] of string = ('programs', 'processes', 'performance');
  Speeds: array[0..3] of LongWord = (HighUpdateMilliseconds, NormalUpdateMilliseconds, LowUpdateMilliseconds,
    PausedUpdateMilliseconds);
  SpeedNames: array[0..3] of string = ('high', 'normal', 'low', 'paused');

constructor TTaskManagerWindow.Create;
var
  Settings: TTaskManagerSettings;
begin
  Settings := RememberedSettings;
  inherited Create(ProgramName, 60, 40, Settings.Width, Settings.Height);
  FSampler := TUsageSampler.Create;
  BuildMenus;
  FStatusBar := TStatusBar.Create(Root);
  PlaceStatusPanels;
  BuildPages;
  FProcessesPage.SortBy(Settings.SortColumn, Settings.SortAscending);
  FTabs.PageIndex := Settings.TabIndex;
  FTabs.OnChange := @TabChanged;
  FUpdateMilliseconds := Settings.UpdateMilliseconds;
  Say(Format('settings size %d %d, tab %s, sort %d %s, update %d', [Settings.Width, Settings.Height,
    TabNames[Settings.TabIndex], Settings.SortColumn, BoolToStr(Settings.SortAscending, 'ascending', 'descending'),
    Settings.UpdateMilliseconds]));
end;

destructor TTaskManagerWindow.Destroy;
begin
  inherited Destroy;
  FSampler.Free;
end;

procedure TTaskManagerWindow.BuildMenus;
var
  Menu: TMenuItem;
  Speed: TMenuItem;
  Item: TMenuItem;
  Index: LongInt;
begin
  FMenuBar := TMenuBar.Create(Root);
  Menu := FMenuBar.Menu.Add('&File');
  Menu.Add('E&xit', @ExitChosen);
  Menu := FMenuBar.Menu.Add('&View');
  Item := Menu.Add('&Refresh Now', @RefreshChosen, 'F5');
  AddItemAccelerator(Self, Item, KeyF5, 0);
  Speed := Menu.Add('&Update Speed');
  FSpeedItems[0] := Speed.Add('&High', @SpeedChosen);
  FSpeedItems[1] := Speed.Add('&Normal', @SpeedChosen);
  FSpeedItems[2] := Speed.Add('&Low', @SpeedChosen);
  FSpeedItems[3] := Speed.Add('&Paused', @SpeedChosen);
  for Index := 0 to High(FSpeedItems) do
    FSpeedItems[Index].Tag := Index;
  Menu := FMenuBar.Menu.Add('&Help');
  Menu.Add('&About Task Manager', @AboutChosen);
end;

procedure TTaskManagerWindow.BuildPages;
begin
  FTabs := TTabControl.Create(Root);
  FTabs.Align := AlignClient;
  FProgramsPage := TProgramsPage.CreatePage(FTabs.AddPage('Pro&grams'), Self, FSampler);
  FProgramsPage.Align := AlignClient;
  FProcessesPage := TProcessesPage.CreatePage(FTabs.AddPage('P&rocesses'), Self, FSampler);
  FProcessesPage.Align := AlignClient;
  FProcessesPage.OnSortChanged := @SortChanged;
  FPerformancePage := TPerformancePage.CreatePage(FTabs.AddPage('Per&formance'), Self, FSampler);
  FPerformancePage.Align := AlignClient;
end;

procedure TTaskManagerWindow.PlaceStatusPanels;
begin
  FStatusBar.SetPanels([StatusPanelWidth, StatusPanelWidth, ClientWidth - 2 * StatusPanelWidth]);
end;

procedure TTaskManagerWindow.Resized;
begin
  inherited Resized;
  if FStatusBar <> nil then
    PlaceStatusPanels;
end;

procedure TTaskManagerWindow.ShowStatus;
var
  Busy: LongWord;
  Memory: LongWord;
begin
  Busy := FSampler.AllProcessorsBusy;
  Memory := FSampler.MemoryInUseTenths;
  FStatusBar.PanelText[0] := ' Processes: ' + IntToStr(FSampler.ProcessCount);
  FStatusBar.PanelText[1] := ' CPU usage: ' + FormatPercent(Busy);
  FStatusBar.PanelText[2] := ' Memory: ' + FormatPercent(Memory);
  Say('cpu ' + FormatPercent(Busy) + ' memory ' + FormatPercent(Memory));
end;

procedure TTaskManagerWindow.Refresh;
begin
  FSampler.Refresh;
  FProgramsPage.Update;
  FProcessesPage.Update;
  FPerformancePage.Update;
  NoticeEndedProcesses(FSampler);
  ShowStatus;
  if (ScreenLeft <> FToldLeft) or (ScreenTop <> FToldTop) then
    TellTabPlaces;
end;

procedure TTaskManagerWindow.SetUpdateSpeed(Milliseconds: LongWord);
var
  Index: LongInt;
begin
  FUpdateMilliseconds := Milliseconds;
  for Index := 0 to High(Speeds) do
    FSpeedItems[Index].Checked := Speeds[Index] = Milliseconds;
  StopTimer(UpdateTimer);
  if Milliseconds <> PausedUpdateMilliseconds then
    StartTimer(UpdateTimer, Milliseconds);
end;

procedure TTaskManagerWindow.TellTabPlaces;
var
  Index: LongInt;
  Tab: TRectangle;
begin
  FToldLeft := ScreenLeft;
  FToldTop := ScreenTop;
  for Index := 0 to FTabs.PageCount - 1 do
  begin
    Tab := FTabs.TabBounds(Index);
    SayPlace('tab-' + TabNames[Index], Self, FTabs.PixelBounds.Left + (Tab.Left + Tab.Right) div 2,
      FTabs.PixelBounds.Top + (Tab.Top + Tab.Bottom) div 2);
  end;
  case FTabs.PageIndex of
    0: FProgramsPage.TellPlaces;
    1: FProcessesPage.TellPlaces;
    2: FPerformancePage.TellPlaces;
  end;
end;

procedure TTaskManagerWindow.Start;
begin
  { Two looks, a moment apart, so the first figures are already shares
    of the time between them. }
  FSampler.Refresh;
  Sleep(100);
  Refresh;
  SetUpdateSpeed(FUpdateMilliseconds);
  Say('tab ' + TabNames[FTabs.PageIndex]);
  TellTabPlaces;
end;

procedure TTaskManagerWindow.TabChanged(Sender: TControl);
begin
  RememberTab(FTabs.PageIndex);
  Say('tab ' + TabNames[FTabs.PageIndex]);
  Refresh;
  TellTabPlaces;
end;

procedure TTaskManagerWindow.SortChanged(Column: LongInt; Ascending: Boolean);
begin
  RememberSort(Column, Ascending);
end;

procedure TTaskManagerWindow.TimerFired(TimerId: LongWord);
begin
  case TimerId of
    UpdateTimer: Refresh;
    EndProgramTimer: FProgramsPage.EndWaitIsOver;
  end;
end;

procedure TTaskManagerWindow.ExitChosen(Item: TMenuItem);
begin
  CloseRequested;
end;

procedure TTaskManagerWindow.RefreshChosen(Item: TMenuItem);
begin
  Say('refresh');
  Refresh;
end;

procedure TTaskManagerWindow.SpeedChosen(Item: TMenuItem);
begin
  SetUpdateSpeed(Speeds[Item.Tag]);
  RememberUpdateSpeed(Speeds[Item.Tag]);
  Say('speed ' + SpeedNames[Item.Tag]);
end;

procedure TTaskManagerWindow.AboutChosen(Item: TMenuItem);
begin
  ShowMessageBox('About Task Manager', 'Task Manager'#10'The programs, processes and performance of FreePascalOS.',
    MessageOk, SignInformation, Self);
end;

procedure TTaskManagerWindow.CloseRequested;
begin
  RememberSize(ClientWidth, ClientHeight);
  Say('exit');
  QuitMessageLoop(0);
end;

end.
