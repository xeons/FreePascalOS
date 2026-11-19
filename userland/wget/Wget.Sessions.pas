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
  What one run of wget keeps from one request to the next: the
  settings, the cookie jar (read from --load-cookies at the start,
  written to --save-cookies at the end), the connection kept alive and
  how each server wants to be authenticated.
}
unit Wget.Sessions;

{$mode objfpc}
{$H+}

interface

uses
  Wget.Authentication,
  Wget.ConnectionPool,
  Wget.Cookies,
  Wget.Settings;

type
  TWgetSession = class
  private
    FSettings: TWgetSettings;
    FCookies: TCookieJar;
    FConnections: TConnectionPool;
    FAuthenticator: TAuthenticator;
  public
    constructor Create(constref Settings: TWgetSettings);
    destructor Destroy; override;
    { --load-cookies; False (said why) if the file cannot be read. }
    function LoadCookies: Boolean;
    { --save-cookies; False (said why) if the file cannot be written. }
    function SaveCookies: Boolean;
    property Settings: TWgetSettings read FSettings;
    property Cookies: TCookieJar read FCookies;
    property Connections: TConnectionPool read FConnections;
    property Authenticator: TAuthenticator read FAuthenticator;
  end;

{ Seconds since 1970 (UTC), for cookies. }
function CurrentUnixTime: Int64;

implementation

uses
  Classes,
  SysUtils,
  Sys.Time,
  Util.Messages,
  Wget.CookieFiles;

function CurrentUnixTime: Int64;
begin
  Result := Int64(CurrentTime);
end;

constructor TWgetSession.Create(constref Settings: TWgetSettings);
begin
  inherited Create;
  FSettings := Settings;
  FCookies := TCookieJar.Create;
  FConnections := TConnectionPool.Create;
  FAuthenticator := TAuthenticator.Create(Settings.User, Settings.Password, Settings.HasUser, Settings.UseNetrc);
end;

destructor TWgetSession.Destroy;
begin
  FConnections.Free;
  FAuthenticator.Free;
  FCookies.Free;
  inherited Destroy;
end;

function TWgetSession.LoadCookies: Boolean;
var
  Lines: TStringList;
begin
  Result := True;
  if FSettings.LoadCookiesFile = '' then
    Exit;
  Lines := TStringList.Create;
  try
    try
      Lines.LoadFromFile(FSettings.LoadCookiesFile);
      LoadCookieText(FCookies, Lines.Text, CurrentUnixTime);
    except
      on EStreamError do
      begin
        Report(Format('cannot read the cookies in ''%s''', [FSettings.LoadCookiesFile]));
        Result := False;
      end;
    end;
  finally
    Lines.Free;
  end;
end;

function TWgetSession.SaveCookies: Boolean;
var
  Stream: TFileStream;
  Text: string;
begin
  Result := True;
  if FSettings.SaveCookiesFile = '' then
    Exit;
  Text := SaveCookieText(FCookies, FSettings.KeepSessionCookies, CurrentUnixTime);
  try
    Stream := TFileStream.Create(FSettings.SaveCookiesFile, fmCreate);
    try
      if Text <> '' then
        Stream.WriteBuffer(Text[1], Length(Text));
    finally
      Stream.Free;
    end;
  except
    on EStreamError do
    begin
      Report(Format('cannot write the cookies to ''%s''', [FSettings.SaveCookiesFile]));
      Result := False;
    end;
  end;
end;

end.
