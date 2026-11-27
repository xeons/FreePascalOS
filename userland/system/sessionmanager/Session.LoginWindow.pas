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
  The login window: a user name, a password (shown as dots) and OK, in
  the middle of the first display, before anyone has logged in, under
  a heading (Controls.HeaderBands: gold where the theme bands panels).

  OK (or Enter) hands the name and the password (the password box's own
  buffer, Controls.PasswordBox: never a string) to OnLogin, which says
  whether they were right; when they were not, the window says so,
  empties the password and puts the keyboard there. The window cannot
  be closed: there is nothing behind it to go back to.
}
unit Session.LoginWindow;

{$mode objfpc}
{$H+}

interface

uses
  Controls.Base,
  Controls.Window,
  Controls.Labels,
  Controls.EditBox,
  Controls.PasswordBox,
  Controls.Buttons,
  Controls.HeaderBands;

type
  { True if Name and Password let the user in. }
  TLoginEvent = function(const Name: string; Password: PChar): Boolean of object;

  TLoginWindow = class(TControlWindow)
  private
    FNameBox: TEditBox;
    FPasswordBox: TPasswordBox;
    FMessage: TLabel;
    FOk: TButton;
    FOnLogin: TLoginEvent;
    procedure OkClicked(Sender: TControl);
    procedure TellPlaces;
  protected
    procedure CloseRequested; override;
  public
    constructor Create;
    { Shows it afresh: empty boxes, the keyboard in the user name. }
    procedure Present;
    property OnLogin: TLoginEvent read FOnLogin write FOnLogin;
  end;

implementation

uses
  Windowing.Protocol,
  Windowing.Connection,
  Session.Report;

const
  WindowWidth = 360;
  WindowHeight = 172;

constructor TLoginWindow.Create;
var
  Caption: TLabel;
  Heading: THeaderBand;
begin
  inherited Create('Log in to FreePascalOS', (Unscaled(ScreenWidth) - WindowWidth) div 2,
    (Unscaled(ScreenHeight) - WindowHeight) div 2, WindowWidth, WindowHeight, WindowFramed);
  { The heading: a gold band across the top where the theme bands its
    panels, otherwise a label. }
  Heading := THeaderBand.Create(Root);
  Heading.Text := 'Type your user name and password.';
  if THeaderBand.ThemeBands then
    Heading.SetBounds(0, 0, WindowWidth, 36)
  else
    Heading.SetBounds(16, 14, 328, 20);
  Caption := TLabel.Create(Root);
  Caption.Text := '&User name:';
  Caption.SetBounds(16, 46, 90, 20);
  FNameBox := TEditBox.Create(Root);
  FNameBox.SetBounds(112, 44, 230, 22);
  FNameBox.MaximumLength := 32;
  Caption := TLabel.Create(Root);
  Caption.Text := '&Password:';
  Caption.SetBounds(16, 78, 90, 20);
  FPasswordBox := TPasswordBox.Create(Root);
  FPasswordBox.SetBounds(112, 76, 230, 22);
  FMessage := TLabel.Create(Root);
  FMessage.SetBounds(16, 108, 328, 20);
  FOk := TButton.Create(Root);
  FOk.Text := '&OK';
  FOk.IsDefault := True;
  FOk.SetBounds(267, 136, 75, 23);
  FOk.OnClick := @OkClicked;
  DefaultControl := FOk;
end;

procedure TLoginWindow.TellPlaces;
begin
  SayPlace('login-user-name', Self, Scaled(200), Scaled(55));
  SayPlace('login-password', Self, Scaled(200), Scaled(87));
  SayPlace('login-ok', Self, Scaled(304), Scaled(147));
end;

procedure TLoginWindow.Present;
begin
  FNameBox.Text := '';
  FPasswordBox.Clear;
  FMessage.Text := '';
  Show;
  Activate;
  FNameBox.SetFocus;
  TellPlaces;
  Say('login window shown');
end;

procedure TLoginWindow.OkClicked(Sender: TControl);
var
  Name: string;
  Accepted: Boolean;
begin
  Name := FNameBox.Text;
  if Name = '' then
  begin
    FPasswordBox.Clear;
    FNameBox.SetFocus;
    Exit;
  end;
  Accepted := Assigned(FOnLogin) and FOnLogin(Name, FPasswordBox.Password);
  FPasswordBox.Clear;
  if Accepted then
    Exit;
  FMessage.Text := 'The user name or password is not right.';
  FPasswordBox.SetFocus;
end;

procedure TLoginWindow.CloseRequested;
begin
  { Nothing to close to: the window stays. }
end;

end.
