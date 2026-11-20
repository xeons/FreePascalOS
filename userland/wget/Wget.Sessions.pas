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
  settings, libhttp's client (its connections: as GNU wget, one kept
  alive at a time, an HTTP/2 one shared by every request to its
  server), the cookie jar (read from --load-cookies at the start,
  written to --save-cookies at the end) and the authenticator (how
  each server wants to be authenticated, the credentials given or from
  ~/.netrc).
}
unit Wget.Sessions;

{$mode objfpc}
{$H+}

interface

uses
  Http.Authentication,
  Http.Client,
  Http.Cookies,
  Wget.Credentials,
  Wget.Observer,
  Wget.Settings;

type
  TWgetSession = class
  private
    FSettings: TWgetSettings;
    FCookies: TCookieJar;
    FAuthenticator: TAuthenticator;
    FNetrc: TNetrcCredentials;
    FObserver: TWgetObserver;
    FClient: THttpClient;
  public
    constructor Create(constref Settings: TWgetSettings);
    destructor Destroy; override;
    { --load-cookies; False (said why) if the file cannot be read. }
    function LoadCookies: Boolean;
    { --save-cookies; False (said why) if the file cannot be written. }
    function SaveCookies: Boolean;
    property Settings: TWgetSettings read FSettings;
    property Cookies: TCookieJar read FCookies;
    property Authenticator: TAuthenticator read FAuthenticator;
    property Client: THttpClient read FClient;
    property Observer: TWgetObserver read FObserver;
  end;

{ Seconds since 1970 (UTC), for cookies. }
function CurrentUnixTime: Int64;

implementation

uses
  Classes,
  SysUtils,
  Sys.Time,
  Util.Messages,
  Http.CookieFiles,
  Http.Observers,
  Http.SocketConnector;

function CurrentUnixTime: Int64;
begin
  Result := Int64(CurrentTime);
end;

function ClientSettingsOf(constref Settings: TWgetSettings): THttpClientSettings;
begin
  Result := DefaultClientSettings;
  Result.UserAgent := Settings.UserAgent;
  Result.TimeoutMilliseconds := Settings.TimeoutMilliseconds;
  Result.VerifyCertificates := Settings.VerifyCertificates;
  Result.HasTrustFile := Settings.HasTrustFile;
  Result.TrustFile := Settings.TrustFile;
  Result.CipherSuites := Settings.CipherSuites;
  Result.AllowHttp2 := Settings.Http2;
  { wget asks for gzip itself, and only with --compression. }
  Result.AcceptEncoding := '';
end;

constructor TWgetSession.Create(constref Settings: TWgetSettings);
var
  Provider: TCredentialsProvider;
begin
  inherited Create;
  FSettings := Settings;
  FCookies := TCookieJar.Create;
  FNetrc := TNetrcCredentials.Create;
  Provider := nil;
  if Settings.UseNetrc then
    Provider := @FNetrc.Lookup;
  FAuthenticator := TAuthenticator.Create(Settings.User, Settings.Password, Settings.HasUser, Provider);
  FObserver := TWgetObserver.Create(Settings.Quiet, Settings.ShowServerResponse);
  FClient := CreateSystemClient(ClientSettingsOf(Settings));
  FClient.ObserverObject := FObserver;
  FClient.Authenticator := FAuthenticator;
  if Settings.UseCookies then
    FClient.Cookies := FCookies;
  { As GNU wget: one connection kept, closed for a request elsewhere. }
  FClient.Pool.MaximumIdle := 1;
  FClient.Pool.MaximumIdlePerOrigin := 1;
  FClient.Pool.IdleTimeout := High(QWord) div 2;
end;

destructor TWgetSession.Destroy;
begin
  FClient.Free;
  FObserver.Free;
  FAuthenticator.Free;
  FNetrc.Free;
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
