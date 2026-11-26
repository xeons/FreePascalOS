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
  The shell: puts the desktop together and keeps it in step with the
  display server.

  A desktop window covers each display (the icons on the first), the
  taskbar runs along the bottom of the first display, and that strip is
  kept out of the display's work area, so maximized windows stop above
  it. What the server tells the shell (Windowing.Shell) goes to the
  window list, which the taskbar follows, and to the notification area;
  when the displays are laid out again (a new scale or mode) the
  desktops and the taskbar are placed again. The taskbar shows the
  volume's notification icon (Desktop.VolumeIndicator) through the same
  interface as any program.

  Ctrl+Shift+Escape is the shell's for the whole desktop (a key it takes
  from the display server): it opens the task manager, or brings the
  one it opened before forward, as do the Start menu's entry and the
  taskbar's own menu. Super+L and Ctrl+Alt+L lock the screen
  (Desktop.Locking), as the Start menu's Lock does.

  Asked to end (the user logs off, the system shuts down), the shell
  simply ends: its windows hold nothing to save, and its end tells the
  session manager the session is over.
}
unit Desktop.Shell;

{$mode objfpc}
{$H+}

interface

uses
  Windowing.Protocol,
  Desktop.WindowList,
  Desktop.DesktopWindow,
  Desktop.Taskbar;

type
  TShell = class
  private
    FWindowList: TWindowList;
    FTaskbar: TTaskbarWindow;
    FDesktops: array of TDesktopWindow;
    { The task manager the shell started last (0: none). }
    FTaskManagerProcessId: QWord;
    procedure LayOut;
    procedure PlaceDesktop(Number: LongInt; Left, Top, Width, Height: LongInt);
    procedure ShellEvent(const Message: TWindowMessage);
    procedure WindowsChanged;
    procedure EndRequested(Reason: LongWord);
    procedure OpenTaskManager;
  public
    { Builds the desktop; the program is the shell already. }
    constructor Create;
    destructor Destroy; override;
  end;

implementation

uses
  Abi.SystemCalls,
  Sys.Notifications,
  Sys.PriorityClasses,
  Windowing.Displays,
  Windowing.Shell,
  Windowing.EndRequests,
  Windowing.Windows,
  Controls.Keys,
  Desktop.Programs,
  Desktop.Locking,
  Desktop.EndTask,
  Desktop.Report;

procedure TShell.EndRequested(Reason: LongWord);
begin
  Say('desktop: asked to end (' + EndReasonName(Reason) + ')');
  QuitMessageLoop(0);
end;

constructor TShell.Create;
begin
  inherited Create;
  FWindowList := TWindowList.Create;
  FWindowList.OnChange := @WindowsChanged;
  OnShellEvent := @ShellEvent;
  OnEndRequested := @EndRequested;
  RegisterHotkey(KeyEscape, ModifierControl or ModifierShift, True);
  RegisterHotkey(KeyL, ModifierSuper, True);
  RegisterHotkey(KeyL, ModifierControl or ModifierAlt, True);
  { The programs offered on the desktop and in the Start menu. }
  LoadDesktopPrograms;
  LayOut;
  FTaskbar.OnTaskManagerChosen := @OpenTaskManager;
end;

destructor TShell.Destroy;
var
  Index: LongInt;
begin
  OnShellEvent := nil;
  OnEndRequested := nil;
  FTaskbar.Free;
  for Index := 0 to High(FDesktops) do
    FDesktops[Index].Free;
  FWindowList.Free;
  inherited Destroy;
end;

procedure TShell.PlaceDesktop(Number: LongInt; Left, Top, Width, Height: LongInt);
var
  Desktop: TDesktopWindow;
begin
  if Number >= Length(FDesktops) then
  begin
    SetLength(FDesktops, Number + 1);
    Desktop := TDesktopWindow.CreateDesktop(Number, Left, Top, Width, Height, Number = 0);
    FDesktops[Number] := Desktop;
    Desktop.Show;
    Desktop.TellPlaces;
    Exit;
  end;
  Desktop := FDesktops[Number];
  Desktop.MoveTo(Left, Top);
  if (Desktop.ClientWidth <> Width) or (Desktop.ClientHeight <> Height) then
    Desktop.SetClientSize(Width, Height);
end;

procedure TShell.LayOut;
var
  Number: LongInt;
  Display: TDisplayInformation;
  First: TDisplayInformation;
begin
  if not DescribeDisplay(0, First) then
    Exit;
  Number := 0;
  while DescribeDisplay(Number, Display) do
  begin
    PlaceDesktop(Number, Display.Left, Display.Top, Display.LogicalWidth, Display.LogicalHeight);
    Inc(Number);
  end;
  if FTaskbar = nil then
  begin
    FTaskbar := TTaskbarWindow.CreateTaskbar(FWindowList, First.Left, First.Top, First.LogicalWidth,
      First.LogicalHeight);
    FTaskbar.Show;
  end
  else
    FTaskbar.PlaceOnDisplay(First.Left, First.Top, First.LogicalWidth, First.LogicalHeight);
  SetWorkArea(0, First.Left, First.Top, First.LogicalWidth, First.LogicalHeight - TaskbarHeight);
end;

procedure TShell.ShellEvent(const Message: TWindowMessage);
begin
  case Message.Kind of
    EventShellWindowChanged:
      FWindowList.TakeChange(Message);
    EventShellWindowGone:
      FWindowList.Remove(Message.Window);
    EventShellEndTaskOffered:
      OfferToEndTask(Message);
    EventDisplaysChanged:
      LayOut;
    EventNotificationIconChanged:
      if FTaskbar <> nil then
        FTaskbar.NotificationIconChanged(Message);
    EventHotkey:
      if Message.Code = KeyEscape then
      begin
        Say('hotkey task manager');
        OpenTaskManager;
      end
      else if Message.Code = KeyL then
      begin
        Say('hotkey lock');
        LockDesktop;
      end;
  end;
end;

procedure TShell.OpenTaskManager;
var
  Index: LongInt;
begin
  { One is enough: the one already open comes forward. }
  if FTaskManagerProcessId <> 0 then
  begin
    Index := FWindowList.IndexOfProcess(FTaskManagerProcessId);
    if Index >= 0 then
    begin
      ManageWindow(FWindowList[Index].Id, ManageActivate);
      Exit;
    end;
  end;
  { It must get the processor and memory whatever a runaway program
    takes: the desktop's own Interactive class (Kernel.PriorityClasses),
    which the desktop may pass on to it. }
  if StartCommand('taskmanager', '', 'Task Manager', FTaskManagerProcessId) then
    SetPriorityClass(FTaskManagerProcessId, PriorityClassInteractive);
end;

procedure TShell.WindowsChanged;
begin
  if FTaskbar <> nil then
    FTaskbar.WindowsChanged;
end;

end.
