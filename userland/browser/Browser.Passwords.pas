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
  Saved passwords (Options > Security > Saved Passwords): a site, a
  user name and a password each, kept in passwords.txt in the profile
  (which only the user may read: the settings folder is theirs). Not
  encrypted: there is no master password yet. Plain logic, checked on
  the host.
}
unit Browser.Passwords;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes;

type
  TSavedLogin = record
    Site: string;
    UserName: string;
    Password: string;
  end;

  TPasswordStore = class
  private
    FPath: string;
    FLogins: array of TSavedLogin;
    function GetLogin(Index: Integer): TSavedLogin;
    function GetCount: Integer;
  public
    constructor Create(const Path: string);
    procedure Load;
    procedure Save;
    { Adds or replaces the login for Site and UserName. }
    procedure Remember(const Site, UserName, Password: string);
    procedure Remove(Index: Integer);
    procedure Clear;
    function IndexOf(const Site, UserName: string): Integer;
    property Count: Integer read GetCount;
    property Logins[Index: Integer]: TSavedLogin read GetLogin;
  end;

implementation

uses
  Browser.TextFiles;

constructor TPasswordStore.Create(const Path: string);
begin
  inherited Create;
  FPath := Path;
end;

function TPasswordStore.GetLogin(Index: Integer): TSavedLogin;
begin
  Result := FLogins[Index];
end;

function TPasswordStore.GetCount: Integer;
begin
  Result := Length(FLogins);
end;

procedure TPasswordStore.Load;
var
  Lines: TStringList;
  Index: Integer;
  Fields: TStringArray;
begin
  FLogins := nil;
  Lines := ReadLines(FPath);
  try
    for Index := 0 to Lines.Count - 1 do
    begin
      Fields := Lines[Index].Split([#9]);
      if (Length(Fields) < 3) or (Fields[0] = '') then
        Continue;
      SetLength(FLogins, Length(FLogins) + 1);
      FLogins[High(FLogins)].Site := Fields[0];
      FLogins[High(FLogins)].UserName := Fields[1];
      FLogins[High(FLogins)].Password := Fields[2];
    end;
  finally
    Lines.Free;
  end;
end;

procedure TPasswordStore.Save;
var
  Lines: TStringList;
  Index: Integer;
begin
  Lines := TStringList.Create;
  try
    for Index := 0 to High(FLogins) do
      Lines.Add(JoinFields([FLogins[Index].Site, FLogins[Index].UserName, FLogins[Index].Password]));
    WriteLines(Lines, FPath);
  finally
    Lines.Free;
  end;
end;

function TPasswordStore.IndexOf(const Site, UserName: string): Integer;
var
  Index: Integer;
begin
  for Index := 0 to High(FLogins) do
    if SameText(FLogins[Index].Site, Site) and (FLogins[Index].UserName = UserName) then
      Exit(Index);
  Result := -1;
end;

procedure TPasswordStore.Remember(const Site, UserName, Password: string);
var
  Index: Integer;
begin
  Index := IndexOf(Site, UserName);
  if Index < 0 then
  begin
    SetLength(FLogins, Length(FLogins) + 1);
    Index := High(FLogins);
  end;
  FLogins[Index].Site := Site;
  FLogins[Index].UserName := UserName;
  FLogins[Index].Password := Password;
  Save;
end;

procedure TPasswordStore.Remove(Index: Integer);
var
  Place: Integer;
begin
  if (Index < 0) or (Index > High(FLogins)) then
    Exit;
  for Place := Index to High(FLogins) - 1 do
    FLogins[Place] := FLogins[Place + 1];
  SetLength(FLogins, Length(FLogins) - 1);
  Save;
end;

procedure TPasswordStore.Clear;
begin
  FLogins := nil;
  Save;
end;

end.
