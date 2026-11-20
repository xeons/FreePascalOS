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
  wget's credentials provider for libhttp's authenticator: the host's
  entry in ~/.netrc (Wget.Netrc), read the first time a server asks.
  Credentials given on the command line go to the authenticator
  directly and win.
}
unit Wget.Credentials;

{$mode objfpc}
{$H+}

interface

type
  TNetrcCredentials = class
  private
    FLoaded: Boolean;
    FText: string;
    function NetrcText: string;
  public
    function Lookup(const Host, Realm: string; out User, Password: string): Boolean;
  end;

implementation

uses
  Classes,
  SysUtils,
  Sys.Environment,
  Wget.Netrc;

function ExcludeTrailingSlash(const Path: string): string;
begin
  Result := Path;
  while (Length(Result) > 1) and (Result[Length(Result)] = '/') do
    SetLength(Result, Length(Result) - 1);
end;

function TNetrcCredentials.NetrcText: string;
var
  Lines: TStringList;
  Home: string;
begin
  if not FLoaded then
  begin
    FLoaded := True;
    FText := '';
    Home := GetVariable('HOME');
    if Home <> '' then
    begin
      Lines := TStringList.Create;
      try
        try
          Lines.LoadFromFile(ExcludeTrailingSlash(Home) + '/.netrc');
          FText := Lines.Text;
        except
          on EStreamError do
            FText := '';
        end;
      finally
        Lines.Free;
      end;
    end;
  end;
  Result := FText;
end;

function TNetrcCredentials.Lookup(const Host, Realm: string; out User, Password: string): Boolean;
begin
  Result := FindNetrcCredentials(NetrcText, Host, User, Password);
end;

end.
