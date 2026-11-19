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
  The robots.txt of each server a recursion visits, fetched once (into
  the server's folder, as GNU wget keeps it) before the first link
  there is followed. A server without one (or that cannot be asked)
  allows everything.
}
unit Wget.RobotsCache;

{$mode objfpc}
{$H+}

interface

uses
  Wget.LocalPaths,
  Wget.Robots,
  Wget.Sessions,
  Wget.Urls;

type
  TRobotsCache = class
  private
    FSession: TWgetSession;
    FLayout: TLocalLayout;
    FKeys: array of string;
    FRules: array of TRobotRules;
    function RulesFor(constref Url: TUrl): TRobotRules;
  public
    constructor Create(Session: TWgetSession; constref Layout: TLocalLayout);
    { True if the server's robots.txt lets wget fetch the URL. }
    function Allows(constref Url: TUrl): Boolean;
  end;

implementation

uses
  SysUtils,
  Wget.FileText,
  Wget.Transfer;

const
  AgentToken = 'wget';

function ServerKey(constref Url: TUrl): string;
begin
  Result := FormatUrl(Url);
  Result := Copy(Result, 1, Length(Result) - Length(Url.Path));
end;

constructor TRobotsCache.Create(Session: TWgetSession; constref Layout: TLocalLayout);
begin
  inherited Create;
  FSession := Session;
  FLayout := Layout;
end;

function TRobotsCache.RulesFor(constref Url: TUrl): TRobotRules;
var
  Key: string;
  Index: Integer;
  Request: TFetchRequest;
  Outcome: TFetchResult;
  Text: string;
begin
  Result := nil;
  Key := ServerKey(Url);
  for Index := 0 to High(FKeys) do
    if FKeys[Index] = Key then
      Exit(FRules[Index]);
  Request := Default(TFetchRequest);
  Request.Url := Url;
  Request.Url.Path := '/robots.txt';
  Request.HasOutput := True;
  Request.Output := LocalPathFor(Request.Url, FLayout);
  MakeFolders(FolderOf(Request.Output));
  FetchUrl(FSession, Request, Outcome);
  if Outcome.Saved and ReadFileText(Request.Output, Text) then
    Result := ParseRobots(Text, AgentToken);
  SetLength(FKeys, Length(FKeys) + 1);
  SetLength(FRules, Length(FRules) + 1);
  FKeys[High(FKeys)] := Key;
  FRules[High(FRules)] := Result;
end;

function TRobotsCache.Allows(constref Url: TUrl): Boolean;
begin
  Result := RobotsAllow(RulesFor(Url), Url.Path);
end;

end.
