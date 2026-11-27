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
  The dialogs the Options panes open: Advanced JavaScript Settings,
  Languages, cookie Exceptions, Cookies (the cookie jar: search, remove,
  remove all), Saved Passwords (show passwords, remove), Connection
  Settings and Certificate Manager (libtls's trust store).
}
unit Browser.Options.Dialogs;

{$mode objfpc}
{$H+}

interface

uses
  Windowing.Windows,
  Browser.Settings;

procedure EditScriptOptions(Owner: TWindow; var MoveWindows, RaiseWindows, DisableMenus, ChangeStatus: Boolean);
procedure EditLanguages(Owner: TWindow; var Languages: string);
{ Allowed and Blocked: hosts, comma separated. }
procedure EditCookieExceptions(Owner: TWindow; var Allowed, Blocked: string);
procedure ShowCookies(Owner: TWindow);
procedure ShowSavedPasswords(Owner: TWindow);
procedure EditConnectionSettings(Owner: TWindow; var Mode: TProxyMode; var Host: string; var Port: LongInt;
  var NoProxyFor: string);
procedure ShowCertificates(Owner: TWindow);

implementation

uses
  SysUtils,
  DateUtils,
  Controls.Base,
  Controls.Panels,
  Controls.Labels,
  Controls.EditBox,
  Controls.Buttons,
  Controls.Toggles,
  Controls.ListBox,
  Controls.ListView,
  Controls.NumericUpDown,
  Controls.Dialogs,
  Controls.CommonDialogs,
  Controls.MessageBoxes,
  WebView.Network,
  Browser.Application,
  Browser.Passwords;

function AddLabelTo(Parent: TControl; const Text: string; Left, Top, Width: LongInt): TLabel;
begin
  Result := TLabel.Create(Parent);
  Result.Text := Text;
  Result.SetBounds(Left, Top, Width, 18);
end;

function AddCheckTo(Parent: TControl; const Text: string; Left, Top, Width: LongInt; Checked: Boolean): TCheckBox;
begin
  Result := TCheckBox.Create(Parent);
  Result.Text := Text;
  Result.SetBounds(Left, Top, Width, 20);
  Result.Checked := Checked;
end;

function AddButtonTo(Parent: TControl; const Text: string; Left, Top, Width: LongInt; Handler: TControlEvent): TButton;
begin
  Result := TButton.Create(Parent);
  Result.Text := Text;
  Result.SetBounds(Left, Top, Width, 23);
  Result.OnClick := Handler;
end;

type
  TOptionsDialog = class(TCommonDialog)
  public
    procedure AddOk(Width, Height: LongInt);
  end;

procedure TOptionsDialog.AddOk(Width, Height: LongInt);
begin
  AddOkAndCancel(Width, Height);
end;

{ ---- Advanced JavaScript Settings ---- }

procedure EditScriptOptions(Owner: TWindow; var MoveWindows, RaiseWindows, DisableMenus, ChangeStatus: Boolean);
const
  Width = 380;
  Height = 170;
var
  Dialog: TOptionsDialog;
  Moving, Raising, Menus, Status: TCheckBox;
begin
  Dialog := TOptionsDialog.CreateDialog('Advanced JavaScript Settings', Width, Height, Owner);
  try
    AddLabelTo(Dialog.Root, 'Allow scripts to:', DialogMargin, DialogMargin, 300);
    Moving := AddCheckTo(Dialog.Root, '&Move or resize existing windows', 20, 30, 340, MoveWindows);
    Raising := AddCheckTo(Dialog.Root, '&Raise or lower windows', 20, 52, 340, RaiseWindows);
    Menus := AddCheckTo(Dialog.Root, '&Disable or replace context menus', 20, 74, 340, DisableMenus);
    Status := AddCheckTo(Dialog.Root, '&Change status bar text', 20, 96, 340, ChangeStatus);
    Dialog.AddOk(Width, Height);
    if Dialog.Execute then
    begin
      MoveWindows := Moving.Checked;
      RaiseWindows := Raising.Checked;
      DisableMenus := Menus.Checked;
      ChangeStatus := Status.Checked;
    end;
  finally
    Dialog.Free;
  end;
end;

{ ---- Languages ---- }

type
  TLanguagesDialog = class(TOptionsDialog)
  public
    List: TListBox;
    Choice: TEditBox;
    procedure UpClicked(Sender: TControl);
    procedure DownClicked(Sender: TControl);
    procedure RemoveClicked(Sender: TControl);
    procedure AddClicked(Sender: TControl);
  end;

procedure TLanguagesDialog.UpClicked(Sender: TControl);
var
  Index: LongInt;
begin
  Index := List.ItemIndex;
  if Index > 0 then
  begin
    List.Items.Exchange(Index, Index - 1);
    List.ItemIndex := Index - 1;
  end;
end;

procedure TLanguagesDialog.DownClicked(Sender: TControl);
var
  Index: LongInt;
begin
  Index := List.ItemIndex;
  if (Index >= 0) and (Index < List.Items.Count - 1) then
  begin
    List.Items.Exchange(Index, Index + 1);
    List.ItemIndex := Index + 1;
  end;
end;

procedure TLanguagesDialog.RemoveClicked(Sender: TControl);
begin
  if List.ItemIndex >= 0 then
    List.Items.Delete(List.ItemIndex);
end;

procedure TLanguagesDialog.AddClicked(Sender: TControl);
begin
  if (Trim(Choice.Text) <> '') and (List.Items.IndexOf(LowerCase(Trim(Choice.Text))) < 0) then
    List.Items.Add(LowerCase(Trim(Choice.Text)));
  Choice.Text := '';
end;

procedure EditLanguages(Owner: TWindow; var Languages: string);
const
  Width = 400;
  Height = 300;
var
  Dialog: TLanguagesDialog;
  Parts: TStringArray;
  Index: Integer;
begin
  Dialog := TLanguagesDialog.CreateDialog('Languages', Width, Height, Owner);
  try
    AddLabelTo(Dialog.Root, 'Languages in order of preference (as sent to sites):', DialogMargin, DialogMargin, 380);
    Dialog.List := TListBox.Create(Dialog.Root);
    Dialog.List.SetBounds(DialogMargin, 30, 260, 180);
    Parts := Languages.Split([',']);
    for Index := 0 to High(Parts) do
      if Trim(Parts[Index]) <> '' then
        Dialog.List.Items.Add(Trim(Parts[Index]));
    AddButtonTo(Dialog.Root, 'Move &Up', 280, 30, 110, @Dialog.UpClicked);
    AddButtonTo(Dialog.Root, 'Move &Down', 280, 58, 110, @Dialog.DownClicked);
    AddButtonTo(Dialog.Root, '&Remove', 280, 86, 110, @Dialog.RemoveClicked);
    Dialog.Choice := TEditBox.Create(Dialog.Root);
    Dialog.Choice.SetBounds(DialogMargin, 218, 260, 22);
    Dialog.Choice.Placeholder := 'A language tag (fr, de-ch...)';
    AddButtonTo(Dialog.Root, '&Add', 280, 218, 110, @Dialog.AddClicked);
    Dialog.AddOk(Width, Height);
    if Dialog.Execute then
      Languages := string.Join(', ', Dialog.List.Items.ToStringArray);
  finally
    Dialog.Free;
  end;
end;

{ ---- cookie exceptions ---- }

type
  TExceptionsDialog = class(TOptionsDialog)
  public
    Site: TEditBox;
    List: TListView;
    procedure AddRule(const Status: string);
    procedure BlockClicked(Sender: TControl);
    procedure AllowClicked(Sender: TControl);
    procedure RemoveClicked(Sender: TControl);
    procedure RemoveAllClicked(Sender: TControl);
  end;

procedure TExceptionsDialog.AddRule(const Status: string);
var
  Host: string;
  Row: LongInt;
begin
  Host := LowerCase(Trim(Site.Text));
  if Host = '' then
    Exit;
  for Row := List.RowCount - 1 downto 0 do
    if List.Cells[Row, 0] = Host then
      List.DeleteRow(Row);
  List.AddRow([Host, Status]);
  Site.Text := '';
end;

procedure TExceptionsDialog.BlockClicked(Sender: TControl);
begin
  AddRule('Block');
end;

procedure TExceptionsDialog.AllowClicked(Sender: TControl);
begin
  AddRule('Allow');
end;

procedure TExceptionsDialog.RemoveClicked(Sender: TControl);
begin
  if List.ItemIndex >= 0 then
    List.DeleteRow(List.ItemIndex);
end;

procedure TExceptionsDialog.RemoveAllClicked(Sender: TControl);
begin
  List.Clear;
end;

procedure EditCookieExceptions(Owner: TWindow; var Allowed, Blocked: string);
const
  Width = 440;
  Height = 340;
var
  Dialog: TExceptionsDialog;
  Parts: TStringArray;
  Index: Integer;
  Row: LongInt;
begin
  Dialog := TExceptionsDialog.CreateDialog('Exceptions - Cookies', Width, Height, Owner);
  try
    AddLabelTo(Dialog.Root, 'Sites always or never allowed to use cookies:', DialogMargin, DialogMargin, 420);
    AddLabelTo(Dialog.Root, 'Address of web site:', DialogMargin, 32, 150);
    Dialog.Site := TEditBox.Create(Dialog.Root);
    Dialog.Site.SetBounds(DialogMargin, 52, Width - 2 * DialogMargin, 22);
    AddButtonTo(Dialog.Root, '&Block', Width - DialogMargin - 160, 80, 75, @Dialog.BlockClicked);
    AddButtonTo(Dialog.Root, '&Allow', Width - DialogMargin - 80, 80, 75, @Dialog.AllowClicked);
    Dialog.List := TListView.Create(Dialog.Root);
    Dialog.List.SetBounds(DialogMargin, 110, Width - 2 * DialogMargin, 160);
    Dialog.List.AddColumn('Site', 280);
    Dialog.List.AddColumn('Status', 100);
    Parts := Allowed.Split([',', ' '], TStringSplitOptions.ExcludeEmpty);
    for Index := 0 to High(Parts) do
      Dialog.List.AddRow([Parts[Index], 'Allow']);
    Parts := Blocked.Split([',', ' '], TStringSplitOptions.ExcludeEmpty);
    for Index := 0 to High(Parts) do
      Dialog.List.AddRow([Parts[Index], 'Block']);
    AddButtonTo(Dialog.Root, '&Remove Site', DialogMargin, 276, 110, @Dialog.RemoveClicked);
    AddButtonTo(Dialog.Root, 'Remove All &Sites', DialogMargin + 116, 276, 130, @Dialog.RemoveAllClicked);
    Dialog.AddOk(Width, Height);
    if Dialog.Execute then
    begin
      Allowed := '';
      Blocked := '';
      for Row := 0 to Dialog.List.RowCount - 1 do
        if Dialog.List.Cells[Row, 1] = 'Allow' then
          Allowed := Allowed + Dialog.List.Cells[Row, 0] + ','
        else
          Blocked := Blocked + Dialog.List.Cells[Row, 0] + ',';
    end;
  finally
    Dialog.Free;
  end;
end;

{ ---- the cookie jar ---- }

type
  TCookiesDialog = class(TDialog)
  public
    Search: TEditBox;
    List: TListView;
    Details: TLabel;
    Cookies: TCookieInfoList;
    procedure Fill;
    procedure SearchChanged(Sender: TControl);
    procedure RowChosen(Sender: TControl);
    procedure RemoveClicked(Sender: TControl);
    procedure RemoveAllClicked(Sender: TControl);
  end;

procedure TCookiesDialog.Fill;
var
  Index: Integer;
  Row: LongInt;
  Needle: string;
begin
  Cookies := ListCookies;
  List.Clear;
  Needle := LowerCase(Trim(Search.Text));
  for Index := 0 to High(Cookies) do
  begin
    if (Needle <> '') and (Pos(Needle, LowerCase(Cookies[Index].Host + ' ' + Cookies[Index].Name)) = 0) then
      Continue;
    Row := List.AddRow([Cookies[Index].Host, Cookies[Index].Name]);
    List.Items[Row].Data := Pointer(PtrInt(Index + 1));
  end;
  Details.Text := IntToStr(List.RowCount) + ' cookies';
end;

procedure TCookiesDialog.SearchChanged(Sender: TControl);
begin
  Fill;
end;

procedure TCookiesDialog.RowChosen(Sender: TControl);
var
  Index: PtrInt;
  Expires: string;
begin
  if List.ItemIndex < 0 then
    Exit;
  Index := PtrInt(List.Items[List.ItemIndex].Data) - 1;
  if (Index < 0) or (Index > High(Cookies)) then
    Exit;
  if Cookies[Index].Expires = 0 then
    Expires := 'at end of session'
  else
    Expires := FormatDateTime('yyyy-mm-dd hh:nn', UnixToDateTime(Cookies[Index].Expires));
  Details.Text := 'Name: ' + Cookies[Index].Name + '   Content: ' + Copy(Cookies[Index].Value, 1, 40) + '   Path: ' +
    Cookies[Index].Path + '   Expires: ' + Expires + BoolToStr(Cookies[Index].Secure, '   (secure only)', '');
end;

procedure TCookiesDialog.RemoveClicked(Sender: TControl);
var
  Index: PtrInt;
begin
  if List.ItemIndex < 0 then
    Exit;
  Index := PtrInt(List.Items[List.ItemIndex].Data) - 1;
  if (Index >= 0) and (Index <= High(Cookies)) then
    RemoveCookie(Cookies[Index].Host, Cookies[Index].Name, Cookies[Index].Path);
  Fill;
end;

procedure TCookiesDialog.RemoveAllClicked(Sender: TControl);
begin
  ClearCookies;
  Fill;
end;

procedure ShowCookies(Owner: TWindow);
const
  Width = 520;
  Height = 400;
var
  Dialog: TCookiesDialog;
begin
  Dialog := TCookiesDialog.CreateDialog('Cookies', Width, Height, Owner);
  try
    AddLabelTo(Dialog.Root, '&Search:', DialogMargin, DialogMargin + 3, 60);
    Dialog.Search := TEditBox.Create(Dialog.Root);
    Dialog.Search.SetBounds(70, DialogMargin, Width - 70 - DialogMargin, 22);
    Dialog.Search.OnChange := @Dialog.SearchChanged;
    AddLabelTo(Dialog.Root, 'The following cookies are stored on your computer:', DialogMargin, 40, 400);
    Dialog.List := TListView.Create(Dialog.Root);
    Dialog.List.SetBounds(DialogMargin, 60, Width - 2 * DialogMargin, 230);
    Dialog.List.AddColumn('Site', 260);
    Dialog.List.AddColumn('Cookie Name', 220);
    Dialog.List.OnChange := @Dialog.RowChosen;
    Dialog.Details := AddLabelTo(Dialog.Root, '', DialogMargin, 296, Width - 2 * DialogMargin);
    AddButtonTo(Dialog.Root, '&Remove Cookie', DialogMargin, 330, 120, @Dialog.RemoveClicked);
    AddButtonTo(Dialog.Root, 'Remove &All Cookies', DialogMargin + 126, 330, 140, @Dialog.RemoveAllClicked);
    Dialog.AddButton('&Close', ResultOk, Width - DialogMargin - 75, Height - DialogMargin - 23, 75, 23, True, True);
    Dialog.Fill;
    Dialog.ShowModal;
  finally
    Dialog.Free;
  end;
end;

{ ---- saved passwords ---- }

type
  TPasswordsDialog = class(TDialog)
  public
    List: TListView;
    Shown: Boolean;
    ShowButton: TButton;
    procedure Fill;
    procedure RemoveClicked(Sender: TControl);
    procedure RemoveAllClicked(Sender: TControl);
    procedure ShowClicked(Sender: TControl);
  end;

procedure TPasswordsDialog.Fill;
var
  Index: Integer;
  Store: TPasswordStore;
begin
  Store := BrowserApp.Passwords;
  List.Clear;
  for Index := 0 to Store.Count - 1 do
    if Shown then
      List.AddRow([Store.Logins[Index].Site, Store.Logins[Index].UserName, Store.Logins[Index].Password])
    else
      List.AddRow([Store.Logins[Index].Site, Store.Logins[Index].UserName]);
end;

procedure TPasswordsDialog.RemoveClicked(Sender: TControl);
begin
  if List.ItemIndex >= 0 then
    BrowserApp.Passwords.Remove(List.ItemIndex);
  Fill;
end;

procedure TPasswordsDialog.RemoveAllClicked(Sender: TControl);
begin
  if ShowMessageBox('Remove All Passwords', 'Are you sure you wish to remove all passwords?', MessageYesNo,
    SignQuestion, Self) = ResultYes then
    BrowserApp.Passwords.Clear;
  Fill;
end;

procedure TPasswordsDialog.ShowClicked(Sender: TControl);
begin
  if not Shown and (ShowMessageBox('Show Passwords', 'Are you sure you wish to show your passwords?', MessageYesNo,
    SignQuestion, Self) <> ResultYes) then
    Exit;
  Shown := not Shown;
  if Shown then
    ShowButton.Text := 'Hide &Passwords'
  else
    ShowButton.Text := 'Show &Passwords';
  Fill;
end;

procedure ShowSavedPasswords(Owner: TWindow);
const
  Width = 520;
  Height = 340;
var
  Dialog: TPasswordsDialog;
begin
  Dialog := TPasswordsDialog.CreateDialog('Saved Passwords', Width, Height, Owner);
  try
    AddLabelTo(Dialog.Root, 'Passwords for the following sites are stored on your computer:', DialogMargin,
      DialogMargin, 480);
    Dialog.List := TListView.Create(Dialog.Root);
    Dialog.List.SetBounds(DialogMargin, 32, Width - 2 * DialogMargin, 230);
    Dialog.List.AddColumn('Site', 220);
    Dialog.List.AddColumn('Username', 130);
    Dialog.List.AddColumn('Password', 130);
    AddButtonTo(Dialog.Root, '&Remove', DialogMargin, 270, 90, @Dialog.RemoveClicked);
    AddButtonTo(Dialog.Root, 'Remove &All', DialogMargin + 96, 270, 100, @Dialog.RemoveAllClicked);
    Dialog.ShowButton := AddButtonTo(Dialog.Root, 'Show &Passwords', Width - DialogMargin - 130, 270, 130,
      @Dialog.ShowClicked);
    Dialog.AddButton('&Close', ResultOk, Width - DialogMargin - 75, Height - DialogMargin - 23, 75, 23, True, True);
    Dialog.Fill;
    Dialog.ShowModal;
  finally
    Dialog.Free;
  end;
end;

{ ---- Connection Settings ---- }

procedure EditConnectionSettings(Owner: TWindow; var Mode: TProxyMode; var Host: string; var Port: LongInt;
  var NoProxyFor: string);
const
  Width = 460;
  Height = 250;
var
  Dialog: TOptionsDialog;
  Panel: TPanel;
  NoProxy, System, Manual: TRadioButton;
  HostEdit, ExceptEdit: TEditBox;
  PortEdit: TNumericUpDown;
begin
  Dialog := TOptionsDialog.CreateDialog('Connection Settings', Width, Height, Owner);
  try
    AddLabelTo(Dialog.Root, 'Configure Proxies to Access the Internet', DialogMargin, DialogMargin, 400);
    Panel := TPanel.Create(Dialog.Root);
    Panel.Edge := PanelFlat;
    Panel.SetBounds(DialogMargin, 32, Width - 2 * DialogMargin, 70);
    NoProxy := TRadioButton.Create(Panel);
    NoProxy.Text := 'No pro&xy';
    NoProxy.SetBounds(0, 0, 300, 20);
    System := TRadioButton.Create(Panel);
    System.Text := 'Use &system proxy settings';
    System.SetBounds(0, 22, 300, 20);
    Manual := TRadioButton.Create(Panel);
    Manual.Text := '&Manual proxy configuration:';
    Manual.SetBounds(0, 44, 300, 20);
    NoProxy.Checked := Mode = ProxyNone;
    System.Checked := Mode = ProxySystem;
    Manual.Checked := Mode = ProxyManual;
    AddLabelTo(Dialog.Root, 'HTTP Pro&xy:', 30, 110, 90);
    HostEdit := TEditBox.Create(Dialog.Root);
    HostEdit.SetBounds(120, 106, 200, 22);
    HostEdit.Text := Host;
    AddLabelTo(Dialog.Root, '&Port:', 330, 110, 40);
    PortEdit := TNumericUpDown.Create(Dialog.Root);
    PortEdit.SetBounds(370, 106, 80, 22);
    PortEdit.Minimum := 1;
    PortEdit.Maximum := 65535;
    PortEdit.Value := Port;
    AddLabelTo(Dialog.Root, 'No Proxy &for:', 30, 140, 90);
    ExceptEdit := TEditBox.Create(Dialog.Root);
    ExceptEdit.SetBounds(120, 136, 330, 22);
    ExceptEdit.Text := NoProxyFor;
    AddLabelTo(Dialog.Root, 'The browser connects directly for now; these are kept for the network service.', 30, 166,
      420);
    Dialog.AddOk(Width, Height);
    if Dialog.Execute then
    begin
      if NoProxy.Checked then
        Mode := ProxyNone
      else if Manual.Checked then
        Mode := ProxyManual
      else
        Mode := ProxySystem;
      Host := Trim(HostEdit.Text);
      Port := Round(PortEdit.Value);
      NoProxyFor := Trim(ExceptEdit.Text);
    end;
  finally
    Dialog.Free;
  end;
end;

{ ---- Certificate Manager ---- }

procedure ShowCertificates(Owner: TWindow);
const
  Width = 600;
  Height = 420;
var
  Dialog: TDialog;
  List: TListView;
  Certificates: TCertificateSummaryList;
  Index: Integer;
  Name: string;
begin
  Dialog := TDialog.CreateDialog('Certificate Manager', Width, Height, Owner);
  try
    AddLabelTo(Dialog.Root, 'You have certificates on file that identify these certificate authorities:', DialogMargin,
      DialogMargin, 560);
    List := TListView.Create(Dialog.Root);
    List.SetBounds(DialogMargin, 32, Width - 2 * DialogMargin, Height - 80);
    List.AddColumn('Certificate Name', 260);
    List.AddColumn('Organization', 160);
    List.AddColumn('Expires On', 120);
    Certificates := SystemTrustSummaries;
    for Index := 0 to High(Certificates) do
    begin
      Name := Certificates[Index].CommonName;
      if Name = '' then
        Name := Certificates[Index].Subject;
      List.AddRow([Name, Certificates[Index].Organization, Certificates[Index].ValidUntil]);
    end;
    List.SortByColumn(0, True);
    Dialog.AddButton('&OK', ResultOk, Width - DialogMargin - 75, Height - DialogMargin - 23, 75, 23, True, True);
    Dialog.ShowModal;
  finally
    Dialog.Free;
  end;
end;

end.
