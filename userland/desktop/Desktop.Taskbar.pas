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
  when the minute changes; a notification icon's tooltip shows when the
  pointer has rested on it for a moment.
}
unit Desktop.Taskbar;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
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
    procedure HoverChanged(Sender: TControl);
    procedure ShowHoveredTooltip;
    procedure TellPlaces;
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
  Controls.Popups,
  Controls.Tooltips,
  Desktop.Clock,
  Desktop.Report;

const
  ClockTimer = 1;
  TooltipTimer = 2;
  ClockCheckMilliseconds = 1000;
  TooltipDelayMilliseconds = 500;
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
  FNotificationArea.OnHoverChanged := @HoverChanged;
  FNotificationArea.SetClock(ClockText);
  ArrangeControls;
  StartTimer(ClockTimer, ClockCheckMilliseconds);
end;

destructor TTaskbarWindow.Destroy;
begin
  HideTooltip;
  FStartMenu.Free;
  FContextMenu.Free;
  FTaskbarMenu.Free;
  FButtons.Free;
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
      (Entry.Flags and ShellWindowMinimized) <> 0);
    Ordered.Add(TaskButton);
  end;
  FButtons.Free;
  FButtons := Ordered;
  ArrangeControls;
end;

procedure TTaskbarWindow.NotificationIconChanged(const Message: TWindowMessage);
begin
  FNotificationArea.TakeChange(Message);
  HideTooltip;
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

procedure TTaskbarWindow.HoverChanged(Sender: TControl);
begin
  HideTooltip;
  StopTimer(TooltipTimer);
  if FNotificationArea.Hovered >= 0 then
    StartTimer(TooltipTimer, TooltipDelayMilliseconds);
end;

procedure TTaskbarWindow.ShowHoveredTooltip;
var
  Index: LongInt;
  Icon: TRectangle;
begin
  Index := FNotificationArea.Hovered;
  if Index < 0 then
    Exit;
  Icon := FNotificationArea.IconBounds(Index);
  Icon := OffsetRectangle(Icon, FNotificationArea.PixelBounds.Left, FNotificationArea.PixelBounds.Top);
  ShowTooltip(Self, FNotificationArea.Icons[Index].Tooltip, ScreenLeft + Unscaled((Icon.Left + Icon.Right) div 2),
    ScreenTop);
  Say('tooltip ' + FNotificationArea.Icons[Index].Tooltip);
end;

procedure TTaskbarWindow.TimerFired(TimerId: LongWord);
begin
  if TimerId = ClockTimer then
    FNotificationArea.SetClock(ClockText)
  else if TimerId = TooltipTimer then
  begin
    StopTimer(TooltipTimer);
    ShowHoveredTooltip;
  end;
end;

procedure TTaskbarWindow.CloseRequested;
begin
  { The taskbar stays as long as the desktop runs. }
end;

end.
