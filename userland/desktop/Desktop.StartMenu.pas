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
  The Start menu: the programs (Desktop.Programs) in a submenu for each
  category that has any (Accessories, Graphics, ... in
  TProgramCategory's order; in each, by name), then Lock, Log off,
  Suspend and Shut down.

  Lock and Suspend act at once (Desktop.Locking: the session manager
  shows the lock screen, or suspends the computer, locking it first if
  the user wants it locked on resume).

  It opens above the Start button, its bottom on the taskbar's top edge
  (libcontrols' pop-up menu, measured first so it can be placed so).
  Both ask first, in a message box, then ask the session manager
  (Windowing.Sessions), which logged the user in: logging off ends every
  program of the session and brings the login window back; shutting
  down turns the computer off (every service stopped in order, every
  program asked to end, the disks written out). A desktop started by
  hand, with no session manager, ends itself to log off and calls the
  system's shutdown itself (only root may). Where each item is on the
  screen is said when its menu opens: "place start-category-NAME X Y"
  (NAME the category's, in lower case: start-category-accessories),
  "place start-lock X Y", "place start-logoff X Y", "place
  start-suspend X Y", "place start-shutdown X Y" when the Start menu
  does, "place start-COMMAND X Y" for each program when its category's
  submenu does.
}
unit Desktop.StartMenu;

{$mode objfpc}
{$H+}

interface

uses
  Controls.Base,
  Controls.Window,
  Controls.ImageList,
  Controls.Menus;

type
  TStartMenu = class
  private
    FMenu: TMenuItem;
    FImages: TImageList;
    FOnClosed: TControlEvent;
    procedure SetItemIcon(Item: TMenuItem; const IconName: string);
    procedure AddPrograms;
    procedure ProgramChosen(Item: TMenuItem);
    procedure ShutDownChosen(Item: TMenuItem);
    procedure LogOffChosen(Item: TMenuItem);
    procedure LockChosen(Item: TMenuItem);
    procedure SuspendChosen(Item: TMenuItem);
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
  Windowing.Sessions,
  Controls.Icons,
  Controls.IconTheme,
  Configuration.ProgramInfo,
  Desktop.Programs,
  Desktop.Locking,
  Desktop.Report;

const
  { The tags of Log off and Shut down: past the programs (whose tags are
    their indexes in DesktopPrograms). }
  ShutDownTag = -1;
  LogOffTag = -2;
  LockTag = -3;
  SuspendTag = -4;
  { A category's submenu: this less the category's number. }
  FirstCategoryTag = -100;

  { The icon beside each category's submenu. }
  CategoryIconNames: array[TProgramCategory] of string = ('folder', 'folder', 'folder-pictures', 'folder-public',
    'folder-music', 'folder-projects', 'app-system-info', 'app-settings');

function CategoryTag(Category: TProgramCategory): PtrInt;
begin
  Result := FirstCategoryTag - Ord(Category);
end;

function IsCategoryTag(Tag: PtrInt): Boolean;
begin
  Result := (Tag <= FirstCategoryTag) and (Tag > FirstCategoryTag - 1 - Ord(High(TProgramCategory)));
end;

function CategoryOfTag(Tag: PtrInt): TProgramCategory;
begin
  Result := TProgramCategory(FirstCategoryTag - Tag);
end;

constructor TStartMenu.Create;
var
  Item: TMenuItem;
begin
  inherited Create;
  FMenu := TMenuItem.Create('');
  FMenu.OnOpened := @TellPlaces;
  { The band down its side, where the theme draws one. }
  FMenu.SideBand := 'FreePascalOS';
  { Each item with its icon from the theme (none without it). }
  FImages := TImageList.Create(SmallIconSize, SmallIconSize);
  FMenu.Images := FImages;
  AddPrograms;
  if FMenu.Count > 0 then
    FMenu.AddSeparator;
  Item := FMenu.Add('Loc&k', @LockChosen);
  Item.Tag := LockTag;
  SetItemIcon(Item, 'action-lock');
  Item := FMenu.Add('&Log off...', @LogOffChosen);
  Item.Tag := LogOffTag;
  SetItemIcon(Item, 'action-log-off');
  Item := FMenu.Add('S&uspend', @SuspendChosen);
  Item.Tag := SuspendTag;
  SetItemIcon(Item, 'action-suspend');
  Item := FMenu.Add('&Shut down...', @ShutDownChosen);
  Item.Tag := ShutDownTag;
  SetItemIcon(Item, 'action-shut-down');
end;

destructor TStartMenu.Destroy;
begin
  FMenu.Free;
  FImages.Free;
  inherited Destroy;
end;

procedure TStartMenu.SetItemIcon(Item: TMenuItem; const IconName: string);
begin
  Item.ImageIndex := AddThemeIcon(FImages, IconName);
end;

{ A submenu for each category with programs, holding them in order
  (DesktopPrograms is sorted by category, then name). }
procedure TStartMenu.AddPrograms;
var
  Index: LongInt;
  Category: TProgramCategory;
  Submenu: TMenuItem;
  Item: TMenuItem;
begin
  Submenu := nil;
  for Index := 0 to DesktopProgramCount - 1 do
  begin
    Category := DesktopPrograms[Index].Category;
    if (Submenu = nil) or (CategoryOfTag(Submenu.Tag) <> Category) then
    begin
      Submenu := FMenu.Add(ProgramCategoryNames[Category]);
      Submenu.Tag := CategoryTag(Category);
      Submenu.OnOpened := @TellPlaces;
      SetItemIcon(Submenu, CategoryIconNames[Category]);
    end;
    Item := Submenu.Add(DesktopPrograms[Index].Caption, @ProgramChosen);
    Item.Tag := Index;
    SetItemIcon(Item, DesktopPrograms[Index].IconName);
    if Item.ImageIndex < 0 then
      SetItemIcon(Item, DesktopPrograms[Index].ThemeIconName);
  end;
end;

{ The name an item's place is said under. }
function PlaceName(Item: TMenuItem): string;
begin
  if Item.Tag = ShutDownTag then
    Result := 'start-shutdown'
  else if Item.Tag = LogOffTag then
    Result := 'start-logoff'
  else if Item.Tag = LockTag then
    Result := 'start-lock'
  else if Item.Tag = SuspendTag then
    Result := 'start-suspend'
  else if IsCategoryTag(Item.Tag) then
    Result := 'start-category-' + LowerCase(ProgramCategoryNames[CategoryOfTag(Item.Tag)])
  else if (Item.Tag >= 0) and (Item.Tag < DesktopProgramCount) then
    Result := 'start-' + DesktopPrograms[Item.Tag].Command
  else
    Result := '';
end;

{ The Start menu or a category's submenu has opened in List. }
procedure TStartMenu.TellPlaces(List: TMenuList);
var
  Popup: TWindow;
  Menu: TMenuItem;
  Index: LongInt;
  Name: string;
  Top: LongInt;
begin
  Popup := TWindow(List.Host.OwnerWindow);
  Popup.PrepareToReceive;
  Menu := List.Menu;
  for Index := 0 to Menu.Count - 1 do
  begin
    if Menu[Index].IsSeparator then
      Continue;
    Name := PlaceName(Menu[Index]);
    if Name = '' then
      Continue;
    Top := PopupMenuItemTop(Menu, Index);
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
  { Its places are said as it opens (TellPlaces). }
  List := ShowPopupMenu(Owner, FMenu, Left, Bottom - Height);
  TPopupWindow(List.Host.OwnerWindow).OnDismiss := FOnClosed;
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
  { The session manager runs as root; without one (a desktop started by
    hand) the shutdown is the desktop's own to ask for. }
  if AskSessionManager(SessionRequestPowerOff) = ErrorNone then
    Exit;
  Status := KernelShutdown(ShutdownPowerOff);
  if Status < 0 then
    ShowMessageBox('Shut down', 'The computer could not be shut down: ' + string(ErrorMessage(ErrorCodeOf(Status))) +
      '.', MessageOk, SignError);
end;

procedure TStartMenu.LockChosen(Item: TMenuItem);
begin
  Say('menu Lock');
  LockDesktop;
end;

procedure TStartMenu.SuspendChosen(Item: TMenuItem);
begin
  Say('menu Suspend');
  SuspendComputer;
end;

procedure TStartMenu.LogOffChosen(Item: TMenuItem);
begin
  Say('asking log off');
  if ShowMessageBox('Log off', 'Log off now? Every program you started will be ended.', MessageYesNo,
     SignQuestion) <> ResultYes then
  begin
    Say('log off cancelled');
    Exit;
  end;
  Say('logging off');
  { The session manager ends the whole session, this desktop with it;
    without one, the desktop ends on its own. }
  if AskSessionManager(SessionRequestLogOff) <> ErrorNone then
    QuitMessageLoop(0);
end;

end.
