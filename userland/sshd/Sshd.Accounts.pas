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
  Who may log in over SSH, by the system's accounts (Util.Logins,
  Util.Passwords):

  - an account that exists, whose password is not locked ("!" in
    /etc/shadow) and whose shell is not /bin/false; root only when
    PermitRootLogin is yes;
  - publickey: a key listed in ~/.ssh/authorized_keys (read as root).
    A line with options before its key (command=, from=, ...) is not
    taken, since the options are not carried out;
  - password: the account's password, never an empty one. A wrong one
    is answered after a second, so passwords cannot be tried quickly.
}
unit Sshd.Accounts;

{$mode objfpc}{$H+}

interface

uses
  Ssh.UserAuthentication,
  Sshd.Configuration;

type
  TSystemAccountPolicy = class(TSshAccountPolicy)
  private
    FConfiguration: TSshdConfiguration;
    function MayLogIn(const User: string): Boolean;
  public
    constructor Create(const Configuration: TSshdConfiguration);
    function PublicKeyAuthenticationAllowed: Boolean; override;
    function PasswordAuthenticationAllowed: Boolean; override;
    function PublicKeyIsAuthorized(const User, Blob: string): Boolean; override;
    function PasswordIsRight(const User, Password: string): Boolean; override;
    procedure Note(const Text: string); override;
  end;

implementation

uses
  SysUtils,
  Classes,
  Sys.Processes,
  Util.Accounts,
  Util.Logins,
  Util.Passwords,
  Ssh.PublicKeys,
  Sshd.Log;

const
  PauseAfterWrongPasswordMilliseconds = 1000;
  LockedShell = '/bin/false';

constructor TSystemAccountPolicy.Create(const Configuration: TSshdConfiguration);
begin
  inherited Create;
  FConfiguration := Configuration;
end;

function TSystemAccountPolicy.PublicKeyAuthenticationAllowed: Boolean;
begin
  Result := FConfiguration.PublicKeyAuthentication;
end;

function TSystemAccountPolicy.PasswordAuthenticationAllowed: Boolean;
begin
  Result := FConfiguration.PasswordAuthentication;
end;

function TSystemAccountPolicy.MayLogIn(const User: string): Boolean;
var
  Account: TLoginAccount;
  Check: TPasswordCheck;
begin
  Result := False;
  if not FindLoginAccount(User, Account) then
    Exit;
  if (Account.Identity.UserId = RootId) and not FConfiguration.PermitRootLogin then
    Exit;
  if Account.Shell = LockedShell then
    Exit;
  Check := CheckPassword(Account.Name, '');
  Result := (Check <> PasswordLocked) and (Check <> PasswordUnknownUser);
end;

function TSystemAccountPolicy.PublicKeyIsAuthorized(const User, Blob: string): Boolean;
var
  Account: TLoginAccount;
  Lines: TStringList;
  Path, ListedBlob: string;
  HasOptions: Boolean;
  Index: Integer;
begin
  Result := False;
  if not MayLogIn(User) or not FindLoginAccount(User, Account) then
    Exit;
  Path := IncludeTrailingPathDelimiter(Account.Home) + '.ssh/authorized_keys';
  if not FileExists(Path) then
    Exit;
  Lines := TStringList.Create;
  try
    try
      Lines.LoadFromFile(Path);
    except
      on Error: Exception do
      begin
        Note('cannot read ' + Path + ': ' + Error.Message);
        Exit;
      end;
    end;
    for Index := 0 to Lines.Count - 1 do
      if ParseAuthorizedKeyLine(Lines[Index], ListedBlob, HasOptions) and (ListedBlob = Blob) then
      begin
        if HasOptions then
        begin
          Note(Format('%s line %d: options are not supported; the key is not taken', [Path, Index + 1]));
          Continue;
        end;
        Exit(True);
      end;
  finally
    Lines.Free;
  end;
end;

function TSystemAccountPolicy.PasswordIsRight(const User, Password: string): Boolean;
var
  Account: TLoginAccount;
begin
  Result := (Password <> '') and MayLogIn(User) and FindLoginAccount(User, Account) and
    Util.Logins.PasswordIsRight(Account, PChar(Password));
  if not Result then
    SleepMilliseconds(PauseAfterWrongPasswordMilliseconds);
end;

procedure TSystemAccountPolicy.Note(const Text: string);
begin
  LogLine(Text);
end;

end.
