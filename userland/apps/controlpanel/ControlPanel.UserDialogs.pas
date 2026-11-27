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
  The Users page's dialogs: a new user (name, full name, password twice,
  administrator or not), a new password (with the present one, for
  one's own account as an ordinary user), a user's properties (full
  name and groups), and removing a user (with their home or without).
  Each checks what was typed before it ends with OK (a valid name,
  passwords that match), and says where its boxes are when it appears
  ("place user-NAME X Y"), the first box having the keyboard.
}
unit ControlPanel.UserDialogs;

{$mode objfpc}
{$H+}

interface

uses
  Windowing.Windows,
  Util.AccountChanges;

type
  TNewUser = record
    Name: string;
    FullName: string;
    Password: string;
    Administrator: Boolean;
  end;

  TUserProperties = record
    FullName: string;
    Groups: TGroupNames;
  end;

function AskForNewUser(Owner: TWindow; out User: TNewUser): Boolean;
{ AskCurrent: ask for the present password too (Current). }
function AskForNewPassword(Owner: TWindow; const UserName: string; AskCurrent: Boolean;
  out Current, NewPassword: string): Boolean;
{ Properties holds what the user has, and what was chosen after. Every
  group of AllGroups but the user's primary group is offered. }
function AskForProperties(Owner: TWindow; const UserName: string; const AllGroups: TGroupNames;
  var Properties: TUserProperties): Boolean;
function AskToRemoveUser(Owner: TWindow; const UserName, Home: string; out RemoveHome: Boolean): Boolean;

implementation

uses
  SysUtils,
  Controls.Base,
  Controls.Labels,
  Controls.EditBox,
  Controls.Toggles,
  Controls.CommonDialogs,
  Controls.MessageBoxes,
  ControlPanel.Report;

const
  FieldLeft = DialogMargin + 132;
  FieldHeight = 22;
  FieldGap = 30;

type
  TFieldDialog = class(TCommonDialog)
  private
    FWidth: LongInt;
    FFirstBox: TEditBox;
  protected
    function AddField(const Caption: string; Top: LongInt; HidesText: Boolean): TEditBox;
    procedure Showing; override;
  public
    constructor CreateFieldDialog(AOwner: TWindow; const ATitle: string; Width, Height: LongInt);
  end;

  TNewUserDialog = class(TFieldDialog)
  private
    FName: TEditBox;
    FFullName: TEditBox;
    FPassword: TEditBox;
    FRepeated: TEditBox;
    FAdministrator: TCheckBox;
  protected
    function Accept: Boolean; override;
    procedure Showing; override;
  public
    constructor CreateNewUserDialog(AOwner: TWindow);
  end;

  TPasswordChangeDialog = class(TFieldDialog)
  private
    FCurrent: TEditBox;
    FPassword: TEditBox;
    FRepeated: TEditBox;
  protected
    function Accept: Boolean; override;
    procedure Showing; override;
  public
    constructor CreatePasswordChangeDialog(AOwner: TWindow; const UserName: string; AskCurrent: Boolean);
  end;

  TPropertiesDialog = class(TFieldDialog)
  private
    FFullName: TEditBox;
    FGroupNames: TGroupNames;
    FGroupBoxes: array of TCheckBox;
  protected
    function Accept: Boolean; override;
    procedure Showing; override;
  public
    constructor CreatePropertiesDialog(AOwner: TWindow; const UserName: string; const AllGroups: TGroupNames;
      const Properties: TUserProperties);
    function ChosenGroups: TGroupNames;
  end;

  TRemoveUserDialog = class(TCommonDialog)
  private
    FHomeBox: TCheckBox;
  protected
    procedure Showing; override;
  public
    constructor CreateRemoveUserDialog(AOwner: TWindow; const UserName, Home: string);
  end;

{ --- TFieldDialog ---------------------------------------------------------- }

constructor TFieldDialog.CreateFieldDialog(AOwner: TWindow; const ATitle: string; Width, Height: LongInt);
begin
  inherited CreateDialog(ATitle, Width, Height, AOwner);
  FWidth := Width;
  AddOkAndCancel(Width, Height);
end;

function TFieldDialog.AddField(const Caption: string; Top: LongInt; HidesText: Boolean): TEditBox;
var
  CaptionLabel: TLabel;
begin
  CaptionLabel := TLabel.Create(Root);
  CaptionLabel.Text := Caption;
  CaptionLabel.SetBounds(DialogMargin, Top + 3, FieldLeft - DialogMargin - 4, 16);
  Result := TEditBox.Create(Root);
  Result.HidesText := HidesText;
  Result.SetBounds(FieldLeft, Top, FWidth - FieldLeft - DialogMargin, FieldHeight);
  if FFirstBox = nil then
    FFirstBox := Result;
end;

procedure TFieldDialog.Showing;
begin
  if FFirstBox <> nil then
    FocusControl(FFirstBox);
  inherited Showing;
  Say('dialog ' + Title);
  SayControlPlace('user-ok', Self, OkButton);
end;

{ --- A new user ------------------------------------------------------------- }

constructor TNewUserDialog.CreateNewUserDialog(AOwner: TWindow);
const
  Width = 400;
  Height = 214;
begin
  inherited CreateFieldDialog(AOwner, 'Add a User', Width, Height);
  FName := AddField('&User name:', DialogMargin, False);
  FFullName := AddField('&Full name:', DialogMargin + FieldGap, False);
  FPassword := AddField('&Password:', DialogMargin + 2 * FieldGap, True);
  FRepeated := AddField('&Confirm password:', DialogMargin + 3 * FieldGap, True);
  FAdministrator := TCheckBox.Create(Root);
  FAdministrator.Text := '&Administrator (a member of wheel)';
  FAdministrator.SetBounds(FieldLeft, DialogMargin + 4 * FieldGap, Width - FieldLeft - DialogMargin, 20);
end;

procedure TNewUserDialog.Showing;
begin
  inherited Showing;
  SayControlPlace('user-name', Self, FName);
  SayControlPlace('user-full-name', Self, FFullName);
  SayControlPlace('user-password', Self, FPassword);
  SayControlPlace('user-repeated', Self, FRepeated);
  SayControlPlace('user-administrator', Self, FAdministrator);
end;

function TNewUserDialog.Accept: Boolean;
begin
  Result := False;
  if not IsValidUserName(Trim(FName.Text)) then
  begin
    ShowMessageBox('Add a User', 'A user name starts with a small letter and holds small letters, digits, _ and -' +
      ' (31 at most).', MessageOk, SignWarning, Self);
    Exit;
  end;
  if not IsValidFullName(FFullName.Text) then
  begin
    ShowMessageBox('Add a User', 'A full name may not hold a colon.', MessageOk, SignWarning, Self);
    Exit;
  end;
  if FPassword.Text <> FRepeated.Text then
  begin
    ShowMessageBox('Add a User', 'The passwords do not match.', MessageOk, SignWarning, Self);
    Exit;
  end;
  Result := True;
end;

function AskForNewUser(Owner: TWindow; out User: TNewUser): Boolean;
var
  Dialog: TNewUserDialog;
begin
  User.Name := '';
  User.FullName := '';
  User.Password := '';
  User.Administrator := False;
  Dialog := TNewUserDialog.CreateNewUserDialog(Owner);
  try
    Result := Dialog.Execute;
    if Result then
    begin
      User.Name := Trim(Dialog.FName.Text);
      User.FullName := Dialog.FFullName.Text;
      User.Password := Dialog.FPassword.Text;
      User.Administrator := Dialog.FAdministrator.Checked;
    end;
  finally
    Dialog.Free;
  end;
end;

{ --- A new password ---------------------------------------------------------- }

constructor TPasswordChangeDialog.CreatePasswordChangeDialog(AOwner: TWindow; const UserName: string;
  AskCurrent: Boolean);
const
  Width = 380;
var
  Top: LongInt;
  Height: LongInt;
begin
  if AskCurrent then
    Height := 148
  else
    Height := 118;
  inherited CreateFieldDialog(AOwner, 'Password of ' + UserName, Width, Height);
  Top := DialogMargin;
  if AskCurrent then
  begin
    FCurrent := AddField('&Present password:', Top, True);
    Top := Top + FieldGap;
  end;
  FPassword := AddField('&New password:', Top, True);
  FRepeated := AddField('&Confirm password:', Top + FieldGap, True);
end;

procedure TPasswordChangeDialog.Showing;
begin
  inherited Showing;
  if FCurrent <> nil then
    SayControlPlace('user-current', Self, FCurrent);
  SayControlPlace('user-password', Self, FPassword);
  SayControlPlace('user-repeated', Self, FRepeated);
end;

function TPasswordChangeDialog.Accept: Boolean;
begin
  Result := FPassword.Text = FRepeated.Text;
  if not Result then
    ShowMessageBox('Password', 'The passwords do not match.', MessageOk, SignWarning, Self);
end;

function AskForNewPassword(Owner: TWindow; const UserName: string; AskCurrent: Boolean;
  out Current, NewPassword: string): Boolean;
var
  Dialog: TPasswordChangeDialog;
begin
  Current := '';
  NewPassword := '';
  Dialog := TPasswordChangeDialog.CreatePasswordChangeDialog(Owner, UserName, AskCurrent);
  try
    Result := Dialog.Execute;
    if Result then
    begin
      if Dialog.FCurrent <> nil then
        Current := Dialog.FCurrent.Text;
      NewPassword := Dialog.FPassword.Text;
    end;
  finally
    Dialog.Free;
  end;
end;

{ --- Properties ----------------------------------------------------------------- }

function Contains(const Groups: TGroupNames; const Name: string): Boolean;
var
  Index: LongInt;
begin
  for Index := 0 to High(Groups) do
    if Groups[Index] = Name then
      Exit(True);
  Result := False;
end;

constructor TPropertiesDialog.CreatePropertiesDialog(AOwner: TWindow; const UserName: string;
  const AllGroups: TGroupNames; const Properties: TUserProperties);
const
  Width = 360;
  GroupRowHeight = 22;
var
  Height: LongInt;
  Index: LongInt;
  Box: TCheckBox;
  Caption: TLabel;
  Top: LongInt;
begin
  FGroupNames := AllGroups;
  Height := DialogMargin + FieldGap + 22 + Length(AllGroups) * GroupRowHeight + DialogMargin + DialogButtonHeight +
    DialogMargin;
  inherited CreateFieldDialog(AOwner, 'Properties of ' + UserName, Width, Height);
  FFullName := AddField('&Full name:', DialogMargin, False);
  FFullName.Text := Properties.FullName;
  Caption := TLabel.Create(Root);
  Caption.Text := 'Member of:';
  Caption.SetBounds(DialogMargin, DialogMargin + FieldGap + 3, FieldLeft - DialogMargin - 4, 16);
  Top := DialogMargin + FieldGap;
  SetLength(FGroupBoxes, Length(AllGroups));
  for Index := 0 to High(AllGroups) do
  begin
    Box := TCheckBox.Create(Root);
    Box.Text := AllGroups[Index];
    Box.SetBounds(FieldLeft, Top + Index * GroupRowHeight, Width - FieldLeft - DialogMargin, 20);
    Box.Checked := Contains(Properties.Groups, AllGroups[Index]);
    FGroupBoxes[Index] := Box;
  end;
end;

procedure TPropertiesDialog.Showing;
var
  Index: LongInt;
begin
  inherited Showing;
  SayControlPlace('user-full-name', Self, FFullName);
  for Index := 0 to High(FGroupBoxes) do
    SayControlPlace('user-group-' + FGroupNames[Index], Self, FGroupBoxes[Index]);
end;

function TPropertiesDialog.Accept: Boolean;
begin
  Result := IsValidFullName(FFullName.Text);
  if not Result then
    ShowMessageBox('Properties', 'A full name may not hold a colon.', MessageOk, SignWarning, Self);
end;

function TPropertiesDialog.ChosenGroups: TGroupNames;
var
  Index: LongInt;
begin
  Result := nil;
  for Index := 0 to High(FGroupBoxes) do
    if FGroupBoxes[Index].Checked then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := FGroupNames[Index];
    end;
end;

function AskForProperties(Owner: TWindow; const UserName: string; const AllGroups: TGroupNames;
  var Properties: TUserProperties): Boolean;
var
  Dialog: TPropertiesDialog;
begin
  Dialog := TPropertiesDialog.CreatePropertiesDialog(Owner, UserName, AllGroups, Properties);
  try
    Result := Dialog.Execute;
    if Result then
    begin
      Properties.FullName := Dialog.FFullName.Text;
      Properties.Groups := Dialog.ChosenGroups;
    end;
  finally
    Dialog.Free;
  end;
end;

{ --- Removing a user ------------------------------------------------------------ }

constructor TRemoveUserDialog.CreateRemoveUserDialog(AOwner: TWindow; const UserName, Home: string);
const
  Width = 380;
  Height = 108;
var
  Question: TLabel;
begin
  inherited CreateDialog('Remove a User', Width, Height, AOwner);
  Question := TLabel.Create(Root);
  Question.ShowsMnemonic := False;
  Question.Text := 'Remove the account ' + UserName + '?';
  Question.SetBounds(DialogMargin, DialogMargin, Width - 2 * DialogMargin, 18);
  FHomeBox := TCheckBox.Create(Root);
  FHomeBox.Text := 'Remove the &home folder ' + Home + ' too';
  FHomeBox.SetBounds(DialogMargin, DialogMargin + 26, Width - 2 * DialogMargin, 20);
  AddOkAndCancel(Width, Height);
end;

procedure TRemoveUserDialog.Showing;
begin
  inherited Showing;
  Say('dialog ' + Title);
  SayControlPlace('user-remove-home', Self, FHomeBox);
  SayControlPlace('user-ok', Self, OkButton);
end;

function AskToRemoveUser(Owner: TWindow; const UserName, Home: string; out RemoveHome: Boolean): Boolean;
var
  Dialog: TRemoveUserDialog;
begin
  RemoveHome := False;
  Dialog := TRemoveUserDialog.CreateRemoveUserDialog(Owner, UserName, Home);
  try
    Result := Dialog.Execute;
    RemoveHome := Dialog.FHomeBox.Checked;
  finally
    Dialog.Free;
  end;
end;

end.
