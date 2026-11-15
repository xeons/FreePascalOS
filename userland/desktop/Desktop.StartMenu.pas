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
  The Start menu: the programs (Desktop.Programs), then Shut down.

  It opens above the Start button, its bottom on the taskbar's top edge
  (libcontrols' pop-up menu, measured first so it can be placed so).
  Shut down asks first, in a message box, then calls the system's
  shutdown (every program is asked to end, the disks written out, the
  machine powered off; only root may). Logging off comes with sessions
  (step 7). Where each item is on the screen is said when it opens
  ("place start-COMMAND X Y", "place start-shutdown X Y").
}
unit Desktop.StartMenu;

{$mode objfpc}
{$H+}

interface

uses
  Controls.Base,
  Controls.Window,
  Controls.Menus;

type
  TStartMenu = class
  private
    FMenu: TMenuItem;
    FOnClosed: TControlEvent;
    procedure ProgramChosen(Item: TMenuItem);
    procedure ShutDownChosen(Item: TMenuItem);
    procedure TellPlaces(List: TMenuList);
  public
    constructor Create;
    destructor Destroy; override;
    { Opens it for Owner (the taskbar) with its bottom left corner at
      (Left, Bottom), screen logical units. }
    procedure Open(Owner: TControlWindow; Left, Bottom: LongInt);
    { When it closes, chosen from or not. }
    property OnClosed: TControlEvent read FOnClosed write FOnClosed;
  end;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Kernel,
  Sys.Errors,
  Windowing.Theme,
  Windowing.Connection,
  Windowing.Windows,
  Controls.Popups,
  Controls.Dialogs,
  Controls.MessageBoxes,
  Desktop.Programs,
  Desktop.Report;

const
  { The Shut down item's tag: past the programs. }
  ShutDownTag = -1;

constructor TStartMenu.Create;
var
  Index: LongInt;
  Item: TMenuItem;
begin
  inherited Create;
  FMenu := TMenuItem.Create('');
  for Index := 0 to DesktopProgramCount - 1 do
  begin
    Item := FMenu.Add(DesktopPrograms[Index].Caption, @ProgramChosen);
    Item.Tag := Index;
  end;
  FMenu.AddSeparator;
  Item := FMenu.Add('&Shut down...', @ShutDownChosen);
  Item.Tag := ShutDownTag;
end;

destructor TStartMenu.Destroy;
begin
  FMenu.Free;
  inherited Destroy;
end;

procedure TStartMenu.TellPlaces(List: TMenuList);
var
  Popup: TWindow;
  Index: LongInt;
  Name: string;
  Top: LongInt;
begin
  Popup := TWindow(List.Host.OwnerWindow);
  Popup.PrepareToReceive;
  for Index := 0 to FMenu.Count - 1 do
  begin
    if FMenu[Index].IsSeparator then
      Continue;
    if FMenu[Index].Tag = ShutDownTag then
      Name := 'start-shutdown'
    else
      Name := 'start-' + string(DesktopPrograms[FMenu[Index].Tag].Command);
    Top := PopupMenuItemTop(FMenu, Index);
    SayPlace(Name, Popup, Scaled(40), Scaled(Top + Theme.MenuItemHeight div 2));
  end;
end;

procedure TStartMenu.Open(Owner: TControlWindow; Left, Bottom: LongInt);
var
  Width: LongInt;
  Height: LongInt;
  List: TMenuList;
begin
  Owner.PrepareToReceive;
  MeasurePopupMenu(FMenu, Width, Height);
  List := ShowPopupMenu(Owner, FMenu, Left, Bottom - Height);
  TPopupWindow(List.Host.OwnerWindow).OnDismiss := FOnClosed;
  TellPlaces(List);
end;

procedure TStartMenu.ProgramChosen(Item: TMenuItem);
begin
  Say('menu ' + Item.Caption);
  StartDesktopProgram(Item.Tag);
end;

procedure TStartMenu.ShutDownChosen(Item: TMenuItem);
var
  Status: Int64;
begin
  Say('asking shut down');
  if ShowMessageBox('Shut down', 'Shut the computer down now? Every program will be asked to end.', MessageYesNo,
     SignQuestion) <> ResultYes then
  begin
    Say('shut down cancelled');
    Exit;
  end;
  Say('shutting down');
  Status := KernelShutdown(ShutdownPowerOff);
  if Status < 0 then
    ShowMessageBox('Shut down', 'The computer could not be shut down: ' + string(ErrorMessage(ErrorCodeOf(Status))) +
      '.', MessageOk, SignError);
end;

end.
