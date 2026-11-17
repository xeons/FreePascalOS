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
  The taskbar: a strip along the bottom of the first display with the
  Start button, a button for each window of the other programs, and the
  notification area with the clock.

  It is a topmost window that never takes the keyboard, so clicking it
  leaves the keyboard with the window that had it: a click on the active
  window's button minimizes it, on another's activates it (restoring it
  if minimized). A right click on a button opens Restore, Minimize,
  Maximize and Close for that window; on the taskbar itself, a menu
  with the Task Manager. The buttons share what is left
  between the Start button and the notification area, each at most
  MaximumButtonWidth wide. The clock is checked every second and drawn
  when the minute changes, and the volume and network icons with it
  (Desktop.VolumeIndicator, Desktop.NetworkIndicator); a notification
  icon's tooltip shows when the pointer has rested on it for a moment
  (the window's hints, Controls.Hints: the icon's hint), a
  click on a volume icon opens the volume control (Desktop.VolumePopup)
  and on a network icon the list of interfaces (Desktop.NetworkPopup).
  The clock follows the user's settings as they change (its format,
  Desktop.Settings) and a new time zone at once.
}
unit Desktop.Taskbar;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  Configuration.Changes,
  Drawing.Rectangles,
  Drawing.Canvas,
  Windowing.Protocol,
  Controls.Base,
  Controls.Window,
  Controls.Menus,
  Desktop.WindowList,
  Desktop.StartButton,
  Desktop.TaskButtons,
  Desktop.NotificationArea,
  Desktop.VolumeIndicator,
  Desktop.NetworkIndicator,
  Desktop.StartMenu;

const
  { Logical units. }
  TaskbarHeight = 30;

type
  TTaskbarEvent = procedure of object;

  TTaskbarWindow = class(TControlWindow)
  private
    FWindowList: TWindowList;
    FStartButton: TStartButton;
    FStartMenu: TStartMenu;
    FNotificationArea: TNotificationArea;
    FButtons: TList;
    FContextMenu: TMenuItem;
    FContextWindowId: LongWord;
    FTaskbarMenu: TMenuItem;
    FOnTaskManagerChosen: TTaskbarEvent;
    FVolumeIndicator: TVolumeIndicator;
    FNetworkIndicator: TNetworkIndicator;
    procedure IconClicked(Sender: TControl);
    procedure OpenVolumePopup(Left: LongInt);
    procedure OpenNetworkPopup(Left: LongInt);
    function ButtonCount: LongInt;
    function Button(Index: LongInt): TTaskButton;
    function ButtonFor(WindowId: LongWord): TTaskButton;
    function WindowHasButton(WindowId: LongWord): Boolean;
    procedure ArrangeControls;
    procedure StartClicked(Sender: TControl);
    procedure StartMenuClosed(Sender: TControl);
    procedure TaskClicked(Sender: TControl);
    procedure TaskContextMenu(Sender: TControl; X, Y: LongInt; PressedButton: LongWord);
    procedure ContextChosen(Item: TMenuItem);
    procedure ShowTaskbarMenu(X, Y: LongInt);
    procedure TaskManagerChosen(Item: TMenuItem);
    procedure HintShown(Sender: TControl; const Text: string);
    procedure TellPlaces;
    procedure ClockSettingsChanged(const Group: string; const Changes: TSettingChanges);
  protected
    procedure Resized; override;
    procedure PointerUp(X, Y: LongInt; ReleasedButton: LongWord); override;
    procedure TimerFired(TimerId: LongWord); override;
    procedure CloseRequested; override;
  public
    { Along the bottom of a display whose logical place and size these
      are. }
    constructor CreateTaskbar(WindowList: TWindowList; DisplayLeft, DisplayTop, DisplayWidth, DisplayHeight: LongInt);
    destructor Destroy; override;
    { Follows the window list: a button for each window it shows. }
    procedure WindowsChanged;
    { Takes an EventNotificationIconChanged. }
    procedure NotificationIconChanged(const Message: TWindowMessage);
    { Moves to the bottom of the display, now this place and size. }
    procedure PlaceOnDisplay(DisplayLeft, DisplayTop, DisplayWidth, DisplayHeight: LongInt);
    { The taskbar's menu's Task Manager was chosen. }
    property OnTaskManagerChosen: TTaskbarEvent read FOnTaskManagerChosen write FOnTaskManagerChosen;
  end;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Windowing.Theme,
  Windowing.Connection,
  Windowing.Windows,
  Windowing.Shell,
  Windowing.SettingsChanges,
  Controls.Popups,
  Desktop.Clock,
  Desktop.Settings,
  Desktop.VolumePopup,
  Desktop.NetworkPopup,
  Desktop.Report;

const
  ClockTimer = 1;
  ClockCheckMilliseconds = 1000;
  { Logical units: around and between the parts, the buttons' height. }
  Margin = 3;
  Gap = 4;
  ButtonHeight = 24;
  MaximumButtonWidth = 160;

constructor TTaskbarWindow.CreateTaskbar(WindowList: TWindowList; DisplayLeft, DisplayTop, DisplayWidth,
  DisplayHeight: LongInt);
begin
  FWindowList := WindowList;
  FButtons := TList.Create;
  inherited Create('Taskbar', DisplayLeft, DisplayTop + DisplayHeight - TaskbarHeight, DisplayWidth, TaskbarHeight,
    WindowTopmost or WindowNoActivate);
  FStartButton := TStartButton.Create(Root);
  FStartButton.Text := 'Start';
  FStartButton.OnClick := @StartClicked;
  FStartMenu := TStartMenu.Create;
  FStartMenu.OnClosed := @StartMenuClosed;
  FNotificationArea := TNotificationArea.Create(Root);
  Hints.OnShown := @HintShown;
  FNotificationArea.OnIconClicked := @IconClicked;
  ClockFormat := RememberedClockFormat;
  FNotificationArea.SetClock(ClockText);
  SubscribeToSettings(DesktopSettingsGroup, @ClockSettingsChanged);
  SubscribeToSettings(TimeSettingsGroup, @ClockSettingsChanged);
  FVolumeIndicator := TVolumeIndicator.Create;
  FVolumeIndicator.Refresh;
  FNetworkIndicator := TNetworkIndicator.Create;
  FNetworkIndicator.Refresh;
  ArrangeControls;
  StartTimer(ClockTimer, ClockCheckMilliseconds);
end;

destructor TTaskbarWindow.Destroy;
begin
  UnsubscribeFromSettings(@ClockSettingsChanged);
  FStartMenu.Free;
  FContextMenu.Free;
  FTaskbarMenu.Free;
  FButtons.Free;
  FVolumeIndicator.Free;
  FNetworkIndicator.Free;
  inherited Destroy;
end;

function TTaskbarWindow.ButtonCount: LongInt;
begin
  Result := FButtons.Count;
end;

function TTaskbarWindow.Button(Index: LongInt): TTaskButton;
begin
  Result := TTaskButton(FButtons[Index]);
end;

function TTaskbarWindow.ButtonFor(WindowId: LongWord): TTaskButton;
var
  Index: LongInt;
begin
  for Index := 0 to ButtonCount - 1 do
    if Button(Index).WindowId = WindowId then
      Exit(Button(Index));
  Result := nil;
end;

procedure TTaskbarWindow.PlaceOnDisplay(DisplayLeft, DisplayTop, DisplayWidth, DisplayHeight: LongInt);
begin
  MoveTo(DisplayLeft, DisplayTop + DisplayHeight - TaskbarHeight);
  if (ClientWidth <> DisplayWidth) or (ClientHeight <> TaskbarHeight) then
    SetClientSize(DisplayWidth, TaskbarHeight);
end;

procedure TTaskbarWindow.ArrangeControls;
var
  StartWidth: LongInt;
  AreaWidth: LongInt;
  ButtonsLeft: LongInt;
  Room: LongInt;
  Width: LongInt;
  Index: LongInt;
  Top: LongInt;
begin
  if FStartButton = nil then
    Exit;
  Top := (TaskbarHeight - ButtonHeight) div 2;
  StartWidth := FStartButton.PreferredWidth;
  FStartButton.SetBounds(Margin, Top, StartWidth, ButtonHeight);
  AreaWidth := FNotificationArea.PreferredWidth;
  FNotificationArea.SetBounds(ClientWidth - Margin - AreaWidth, Top, AreaWidth, ButtonHeight);
  ButtonsLeft := Margin + StartWidth + Gap;
  Room := ClientWidth - Margin - AreaWidth - Gap - ButtonsLeft;
  if ButtonCount > 0 then
  begin
    Width := Room div ButtonCount - Gap;
    if Width > MaximumButtonWidth then
      Width := MaximumButtonWidth;
    for Index := 0 to ButtonCount - 1 do
      Button(Index).SetBounds(ButtonsLeft + Index * (Width + Gap), Top, Width, ButtonHeight);
  end;
  Invalidate;
  TellPlaces;
end;

procedure TTaskbarWindow.TellPlaces;
var
  Index: LongInt;
  Bounds: TRectangle;
begin
  Bounds := FStartButton.PixelBounds;
  SayPlace('start', Self, (Bounds.Left + Bounds.Right) div 2, (Bounds.Top + Bounds.Bottom) div 2);
  for Index := 0 to ButtonCount - 1 do
  begin
    Bounds := Button(Index).PixelBounds;
    SayPlace('task-' + Button(Index).Text, Self, (Bounds.Left + Bounds.Right) div 2, (Bounds.Top + Bounds.Bottom) div 2);
    Bounds := OffsetRectangle(Button(Index).IconBox, Bounds.Left, Bounds.Top);
    SayPlace('task-icon-' + Button(Index).Text, Self, (Bounds.Left + Bounds.Right) div 2,
      (Bounds.Top + Bounds.Bottom) div 2);
  end;
  for Index := 0 to FNotificationArea.IconCount - 1 do
  begin
    Bounds := OffsetRectangle(FNotificationArea.IconBounds(Index), FNotificationArea.PixelBounds.Left,
      FNotificationArea.PixelBounds.Top);
    SayPlace(Format('notification-%u', [FNotificationArea.Icons[Index].Number]), Self,
      (Bounds.Left + Bounds.Right) div 2, (Bounds.Top + Bounds.Bottom) div 2);
  end;
  Bounds := OffsetRectangle(FNotificationArea.ClockBounds, FNotificationArea.PixelBounds.Left,
    FNotificationArea.PixelBounds.Top);
  SayPlace('clock', Self, (Bounds.Left + Bounds.Right) div 2, (Bounds.Top + Bounds.Bottom) div 2);
end;

procedure TTaskbarWindow.Resized;
begin
  inherited Resized;
  ArrangeControls;
end;

function TTaskbarWindow.WindowHasButton(WindowId: LongWord): Boolean;
var
  Index: LongInt;
begin
  Index := FWindowList.IndexOf(WindowId);
  Result := (Index >= 0) and FWindowList.HasButton(Index);
end;

procedure TTaskbarWindow.WindowsChanged;
var
  Index: LongInt;
  Entry: TTaskWindow;
  TaskButton: TTaskButton;
  Ordered: TList;
begin
  { Buttons of windows that went (or have no button now) go. }
  for Index := ButtonCount - 1 downto 0 do
    if not WindowHasButton(Button(Index).WindowId) then
    begin
      TaskButton := Button(Index);
      FButtons.Delete(Index);
      TaskButton.Free;
    end;
  { The rest follow the list's order, new ones made. }
  Ordered := TList.Create;
  for Index := 0 to FWindowList.Count - 1 do
  begin
    if not FWindowList.HasButton(Index) then
      Continue;
    Entry := FWindowList[Index];
    TaskButton := ButtonFor(Entry.Id);
    if TaskButton = nil then
    begin
      TaskButton := TTaskButton.Create(Root);
      TaskButton.WindowId := Entry.Id;
      TaskButton.OnClick := @TaskClicked;
      TaskButton.OnContextMenu := @TaskContextMenu;
    end;
    TaskButton.ShowState(Entry.Title, (Entry.Flags and ShellWindowActive) <> 0,
      (Entry.Flags and ShellWindowMinimized) <> 0, Entry.IconVersion);
    Ordered.Add(TaskButton);
  end;
  FButtons.Free;
  FButtons := Ordered;
  ArrangeControls;
end;

procedure TTaskbarWindow.NotificationIconChanged(const Message: TWindowMessage);
begin
  FNotificationArea.TakeChange(Message);
  { The icon under the pointer may be another one now. }
  Hints.Dismiss;
  ArrangeControls;
end;

procedure TTaskbarWindow.StartClicked(Sender: TControl);
begin
  if FStartButton.Down then
    Exit;
  FStartButton.Down := True;
  FStartMenu.Open(Self, ScreenLeft + FStartButton.Bounds.Left, ScreenTop);
end;

procedure TTaskbarWindow.StartMenuClosed(Sender: TControl);
begin
  FStartButton.Down := False;
end;

procedure TTaskbarWindow.TaskClicked(Sender: TControl);
var
  TaskButton: TTaskButton;
begin
  TaskButton := TTaskButton(Sender);
  if TaskButton.Active then
    ManageWindow(TaskButton.WindowId, ManageMinimize)
  else
    ManageWindow(TaskButton.WindowId, ManageActivate);
end;

procedure TTaskbarWindow.TaskContextMenu(Sender: TControl; X, Y: LongInt; PressedButton: LongWord);
var
  TaskButton: TTaskButton;
  Index: LongInt;
  Flags: LongWord;
  Item: TMenuItem;
  List: TMenuList;
  MenuWindow: TWindow;
begin
  TaskButton := TTaskButton(Sender);
  Index := FWindowList.IndexOf(TaskButton.WindowId);
  if Index < 0 then
    Exit;
  Flags := FWindowList[Index].Flags;
  FContextWindowId := TaskButton.WindowId;
  FContextMenu.Free;
  FContextMenu := TMenuItem.Create('');
  Item := FContextMenu.Add('&Restore');
  Item.Tag := ManageRestore;
  Item.Enabled := (Flags and (ShellWindowMinimized or ShellWindowMaximized)) <> 0;
  Item := FContextMenu.Add('Mi&nimize');
  Item.Tag := ManageMinimize;
  Item.Enabled := (Flags and ShellWindowMinimized) = 0;
  Item := FContextMenu.Add('Ma&ximize');
  Item.Tag := ManageMaximize;
  Item.Enabled := ((Flags and ShellWindowMaximized) = 0) and ((Flags and ShellWindowResizable) <> 0);
  FContextMenu.AddSeparator;
  Item := FContextMenu.Add('&Close');
  Item.Tag := ManageClose;
  List := ShowPopupMenu(Self, FContextMenu, ScreenLeft + Unscaled(TaskButton.PixelBounds.Left + X),
    ScreenTop + Unscaled(TaskButton.PixelBounds.Top + Y), @ContextChosen);
  MenuWindow := TWindow(List.Host.OwnerWindow);
  MenuWindow.PrepareToReceive;
  for Index := 0 to FContextMenu.Count - 1 do
    if not FContextMenu[Index].IsSeparator then
      SayPlace('context-' + LowerCase(FContextMenu[Index].Caption), MenuWindow, Scaled(40),
        Scaled(PopupMenuItemTop(FContextMenu, Index) + Theme.MenuItemHeight div 2));
end;

procedure TTaskbarWindow.ContextChosen(Item: TMenuItem);
begin
  Say('context ' + LowerCase(Item.Caption));
  ManageWindow(FContextWindowId, LongWord(Item.Tag));
end;

{ A right click let go on the taskbar itself, where no button is. }
procedure TTaskbarWindow.PointerUp(X, Y: LongInt; ReleasedButton: LongWord);
begin
  inherited PointerUp(X, Y, ReleasedButton);
  if (ReleasedButton = ButtonRight) and (Root.ControlAt(X, Y) = Root) then
    ShowTaskbarMenu(X, Y);
end;

procedure TTaskbarWindow.ShowTaskbarMenu(X, Y: LongInt);
var
  List: TMenuList;
  MenuWindow: TWindow;
  MenuWidth: LongInt;
  MenuHeight: LongInt;
begin
  FTaskbarMenu.Free;
  FTaskbarMenu := TMenuItem.Create('');
  FTaskbarMenu.Add('Task &Manager', @TaskManagerChosen);
  { Above the taskbar, which is at the bottom of the display. }
  MeasurePopupMenu(FTaskbarMenu, MenuWidth, MenuHeight);
  List := ShowPopupMenu(Self, FTaskbarMenu, ScreenLeft + Unscaled(X), ScreenTop - MenuHeight);
  MenuWindow := TWindow(List.Host.OwnerWindow);
  MenuWindow.PrepareToReceive;
  SayPlace('taskbar-task-manager', MenuWindow, Scaled(40), Scaled(PopupMenuItemTop(FTaskbarMenu, 0) +
    Theme.MenuItemHeight div 2));
end;

procedure TTaskbarWindow.TaskManagerChosen(Item: TMenuItem);
begin
  Say('context task manager');
  if Assigned(FOnTaskManagerChosen) then
    FOnTaskManagerChosen();
end;

procedure TTaskbarWindow.HintShown(Sender: TControl; const Text: string);
begin
  Say('tooltip ' + Text);
end;

procedure TTaskbarWindow.TimerFired(TimerId: LongWord);
begin
  if TimerId = ClockTimer then
  begin
    FNotificationArea.SetClock(ClockText);
    FVolumeIndicator.Refresh;
    FNetworkIndicator.Refresh;
  end;
end;

{ The clock's format, or the time zone: shown at once, with the room the
  clock now needs. }
procedure TTaskbarWindow.ClockSettingsChanged(const Group: string; const Changes: TSettingChanges);
begin
  if (Group = DesktopSettingsGroup) and not ChangesInclude(Changes, ClockFormatSetting) then
    Exit;
  ClockFormat := RememberedClockFormat;
  FNotificationArea.SetClock(ClockText);
  ArrangeControls;
end;

procedure TTaskbarWindow.OpenVolumePopup(Left: LongInt);
var
  VolumeControl: TVolumePopup;
begin
  VolumeControl := TVolumePopup.CreateVolumePopup(Self, Left, ScreenTop);
  VolumeControl.Open;
end;

procedure TTaskbarWindow.OpenNetworkPopup(Left: LongInt);
var
  NetworkList: TNetworkPopup;
begin
  NetworkList := TNetworkPopup.CreateNetworkPopup(Self, Left, ScreenTop);
  NetworkList.Open;
end;

procedure TTaskbarWindow.IconClicked(Sender: TControl);
var
  Index: LongInt;
  Icon: TRectangle;
  Picture: LongWord;
  Left: LongInt;
begin
  Index := FNotificationArea.Clicked;
  if Index < 0 then
    Exit;
  Picture := FNotificationArea.Icons[Index].Picture;
  Icon := OffsetRectangle(FNotificationArea.IconBounds(Index), FNotificationArea.PixelBounds.Left,
    FNotificationArea.PixelBounds.Top);
  Left := ScreenLeft + Unscaled((Icon.Left + Icon.Right) div 2);
  if Picture in [NotificationPictureVolume, NotificationPictureVolumeMuted] then
    OpenVolumePopup(Left)
  else if IsNetworkPicture(Picture) then
    OpenNetworkPopup(Left);
end;

procedure TTaskbarWindow.CloseRequested;
begin
  { The taskbar stays as long as the desktop runs. }
end;

end.
