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
  Keep-alive: the connection the last response left open, kept for the
  next request to the same scheme, host and port (a redirection on the
  same server, the next URL of the command line, the next file of a
  recursion). As GNU wget, one connection is kept; a request elsewhere
  closes it.
}
unit Wget.ConnectionPool;

{$mode objfpc}
{$H+}

interface

uses
  Wget.Connections,
  Wget.Urls;

type
  TConnectionPool = class
  private
    FConnection: TConnection;
    FKey: string;
  public
    destructor Destroy; override;
    { The kept connection to the URL's server (now the caller's), or nil;
      a connection kept for another server is closed. }
    function Take(constref Url: TUrl): TConnection;
    { Keeps Connection (open, between requests) for the URL's server. }
    procedure Keep(constref Url: TUrl; Connection: TConnection);
    procedure CloseAll;
  end;

implementation

uses
  SysUtils;

function ServerKey(constref Url: TUrl): string;
begin
  Result := FormatUrl(Url);
  Result := Copy(Result, 1, Length(Result) - Length(Url.Path));
end;

destructor TConnectionPool.Destroy;
begin
  CloseAll;
  inherited Destroy;
end;

function TConnectionPool.Take(constref Url: TUrl): TConnection;
begin
  Result := nil;
  if FConnection = nil then
    Exit;
  if FKey = ServerKey(Url) then
  begin
    Result := FConnection;
    FConnection := nil;
    Exit;
  end;
  CloseAll;
end;

procedure TConnectionPool.Keep(constref Url: TUrl; Connection: TConnection);
begin
  if Connection = FConnection then
    Exit;
  CloseAll;
  FConnection := Connection;
  FKey := ServerKey(Url);
end;

procedure TConnectionPool.CloseAll;
begin
  FreeAndNil(FConnection);
  FKey := '';
end;

end.
