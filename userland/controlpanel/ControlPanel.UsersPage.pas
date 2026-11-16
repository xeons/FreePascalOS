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
  The Users page: the people's accounts (root and the ids from 1000;
  the system's own, like nobody, are left out), with their full names
  and groups, and buttons to add a user, remove one, change a password
  and change a user's full name and groups.

  Each change is made at once, when its dialog is accepted, by the
  system settings service (Util.AccountChanges, as useradd, userdel and
  usermod do): as an administrator, except an ordinary user's own
  password and full name, which their own password proves. The page
  never waits for Apply.
}
unit ControlPanel.UsersPage;

{$mode objfpc}
{$H+}

interface

uses
  Controls.Base,
  Controls.Window,
  Controls.Buttons,
  Controls.ListView,
  ControlPanel.Pages;

type
  TUsersPage = class(TSettingsPage)
  private
    FList: TListView;
    FNames: array of string;
    FAddButton: TButton;
    FRemoveButton: TButton;
    FPasswordButton: TButton;
    FPropertiesButton: TButton;
    procedure AddClicked(Sender: TControl);
    procedure RemoveClicked(Sender: TControl);
    procedure PasswordClicked(Sender: TControl);
    procedure PropertiesClicked(Sender: TControl);
    function ChosenUser(out Name: string): Boolean;
    procedure SayDone(const What: string; Error: LongInt; const Name: string);
  protected
    procedure LoadSettings; override;
  public
    constructor CreatePage(AParent: TControl; AWindow: TControlWindow; const ATitle: string); override;
    function PageName: string; override;
    procedure TellPlaces; override;
  end;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.SystemSettings,
  Windowing.Connection,
  Controls.MessageBoxes,
  Util.Accounts,
  Util.AccountChanges,
  ControlPanel.Administrator,
  ControlPanel.UserDialogs,
  ControlPanel.Report;

const
  ButtonWidth = 100;
  ButtonHeight = 23;
  FirstPersonId = 1000;
  NobodyId = 65534;

constructor TUsersPage.CreatePage(AParent: TControl; AWindow: TControlWindow; const ATitle: string);
var
  Top: LongInt;
  Left: LongInt;

  function MakeButton(const Caption: string; Handler: TControlEvent): TButton;
  begin
    Result := TButton.Create(Self);
    Result.Text := Caption;
    Result.SetBounds(Left, Top, ButtonWidth, ButtonHeight);
    Result.OnClick := Handler;
    Left := Left + ButtonWidth + 6;
  end;

begin
  inherited CreatePage(AParent, AWindow, ATitle);
  FList := TListView.Create(Self);
  FList.SetBounds(PageMargin, 28, PageWidth - 2 * PageMargin, PageHeight - 28 - PageMargin - ButtonHeight - 10);
  FList.AddColumn('User', 90);
  FList.AddColumn('Full name', 160);
  FList.AddColumn('Groups', 160);
  Top := PageHeight - PageMargin - ButtonHeight;
  Left := PageMargin;
  FAddButton := MakeButton('&Add...', @AddClicked);
  FRemoveButton := MakeButton('Re&move...', @RemoveClicked);
  FPasswordButton := MakeButton('&Password...', @PasswordClicked);
  FPropertiesButton := MakeButton('P&roperties...', @PropertiesClicked);
end;

function TUsersPage.PageName: string;
begin
  Result := 'users';
end;

function GroupListOf(UserId: LongWord): string;
var
  GroupId: LongWord;
  Name: string;
begin
  Result := '';
  for GroupId in GroupsOfUser(UserId) do
  begin
    if not FindGroupName(GroupId, Name) then
      Continue;
    if Result <> '' then
      Result := Result + ', ';
    Result := Result + Name;
  end;
end;

procedure TUsersPage.LoadSettings;
var
  Index: LongInt;
  UserId: LongWord;
  Name: string;
  Chosen: string;
begin
  Chosen := '';
  if (FList.ItemIndex >= 0) and (FList.ItemIndex <= High(FNames)) then
    Chosen := FNames[FList.ItemIndex];
  RecheckAccountFiles;
  FList.Clear;
  FNames := nil;
  Index := 0;
  while UserAt(Index, UserId) do
  begin
    Inc(Index);
    if (UserId <> RootId) and ((UserId < FirstPersonId) or (UserId >= NobodyId)) then
      Continue;
    Name := UserNameOf(UserId);
    FList.AddRow([Name, string(FullNameOf(UserId)), GroupListOf(UserId)]);
    SetLength(FNames, Length(FNames) + 1);
    FNames[High(FNames)] := Name;
  end;
  for Index := 0 to High(FNames) do
    if FNames[Index] = Chosen then
      FList.ItemIndex := Index;
end;

function TUsersPage.ChosenUser(out Name: string): Boolean;
begin
  Name := '';
  Result := (FList.ItemIndex >= 0) and (FList.ItemIndex <= High(FNames));
  if Result then
    Name := FNames[FList.ItemIndex]
  else
    ShowMessageBox('Users', 'Choose a user in the list first.', MessageOk, SignInformation, Window);
end;

procedure TUsersPage.SayDone(const What: string; Error: LongInt; const Name: string);
begin
  if Error = ErrorNone then
    Say(What + ' ' + Name)
  else if Error <> ErrorInterrupted then
    ShowMessageBox('Users', 'The change could not be made. ' + RefusalText(Error), MessageOk, SignError, Window);
  Load;
  TellPlaces;
end;

procedure TUsersPage.AddClicked(Sender: TControl);
var
  User: TNewUser;
  Request: TSystemSettingsRequest;
begin
  if not AskForNewUser(Window, User) then
    Exit;
  Request := NewSystemSettingsRequest(SystemRequestAddUser);
  SetRequestText(@Request.UserName[0], SystemNameCapacity, PChar(User.Name));
  SetRequestText(@Request.FullName[0], SystemTextCapacity, PChar(User.FullName));
  SetRequestText(@Request.Password[0], SystemPasswordCapacity, PChar(User.Password));
  if User.Administrator then
    Request.Flags := SystemFlagAdministrator;
  SayDone('user-added', SendAsAdministrator(Window, Request), User.Name);
end;

procedure TUsersPage.RemoveClicked(Sender: TControl);
var
  Name: string;
  UserId: LongWord;
  RemoveHome: Boolean;
  Request: TSystemSettingsRequest;
begin
  if not ChosenUser(Name) or not FindUserId(Name, UserId) then
    Exit;
  if not AskToRemoveUser(Window, Name, string(HomeDirectoryOf(UserId)), RemoveHome) then
    Exit;
  Request := NewSystemSettingsRequest(SystemRequestRemoveUser);
  SetRequestText(@Request.UserName[0], SystemNameCapacity, PChar(Name));
  if RemoveHome then
    Request.Flags := SystemFlagRemoveHome;
  SayDone('user-removed', SendAsAdministrator(Window, Request), Name);
end;

procedure TUsersPage.PasswordClicked(Sender: TControl);
var
  Name: string;
  Own: Boolean;
  Current: string;
  NewPassword: string;
  Request: TSystemSettingsRequest;
  Error: LongInt;
begin
  if not ChosenUser(Name) then
    Exit;
  { An ordinary user's own password: the present one proves it is them. }
  Own := not RunningAsRoot and (UserNameOf(CurrentRealUserId) <> nil) and
    (string(UserNameOf(CurrentRealUserId)) = Name);
  if not AskForNewPassword(Window, Name, Own, Current, NewPassword) then
    Exit;
  Request := NewSystemSettingsRequest(SystemRequestSetPassword);
  SetRequestText(@Request.UserName[0], SystemNameCapacity, PChar(Name));
  SetRequestText(@Request.Password[0], SystemPasswordCapacity, PChar(NewPassword));
  if Own then
    Error := SendWithPassword(Request, Current)
  else
    Error := SendAsAdministrator(Window, Request);
  SayDone('password-changed', Error, Name);
end;

procedure TUsersPage.PropertiesClicked(Sender: TControl);
var
  Name: string;
  UserId: LongWord;
  PrimaryGroup: LongWord;
  Properties: TUserProperties;
  AllGroups: TGroupNames;
  Index: LongInt;
  GroupId: LongWord;
  Request: TSystemSettingsRequest;
  Error: LongInt;
  OldFullName: string;
begin
  if not ChosenUser(Name) or not FindUserId(Name, UserId) then
    Exit;
  if not PrimaryGroupOf(UserId, PrimaryGroup) then
    PrimaryGroup := UserId;
  AllGroups := nil;
  Index := 0;
  while GroupAt(Index, GroupId) do
  begin
    Inc(Index);
    if (GroupId = PrimaryGroup) or (GroupId >= NobodyId) then
      Continue;
    SetLength(AllGroups, Length(AllGroups) + 1);
    AllGroups[High(AllGroups)] := GroupNameOf(GroupId);
  end;
  Properties.FullName := FullNameOf(UserId);
  OldFullName := Properties.FullName;
  Properties.Groups := SupplementaryGroupsOf(Name);
  if not AskForProperties(Window, Name, AllGroups, Properties) then
    Exit;
  Error := ErrorNone;
  if Properties.FullName <> OldFullName then
  begin
    Request := NewSystemSettingsRequest(SystemRequestSetFullName);
    SetRequestText(@Request.UserName[0], SystemNameCapacity, PChar(Name));
    SetRequestText(@Request.FullName[0], SystemTextCapacity, PChar(Properties.FullName));
    Error := SendAsAdministrator(Window, Request);
  end;
  if Error = ErrorNone then
  begin
    Request := NewSystemSettingsRequest(SystemRequestSetGroups);
    SetRequestText(@Request.UserName[0], SystemNameCapacity, PChar(Name));
    SetRequestText(@Request.Text[0], SystemTextCapacity, PChar(JoinGroupList(Properties.Groups)));
    Error := SendAsAdministrator(Window, Request);
  end;
  SayDone('user-changed', Error, Name);
end;

procedure TUsersPage.TellPlaces;
var
  Index: LongInt;
begin
  for Index := 0 to High(FNames) do
    SayPlace('user-row-' + FNames[Index], Window, FList, Scaled(30), FList.RowMiddle(Index));
  SayControlPlace('users-add', Window, FAddButton);
  SayControlPlace('users-remove', Window, FRemoveButton);
  SayControlPlace('users-password', Window, FPasswordButton);
  SayControlPlace('users-properties', Window, FPropertiesButton);
end;

end.
