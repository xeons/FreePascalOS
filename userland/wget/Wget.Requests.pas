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
  One HTTP/1.1 exchange: the GET request (Host, User-Agent, Accept,
  Accept-Encoding, a Range when continuing, Cookie and Authorization
  when there are any, and "Connection: Keep-Alive", or "close" with
  --no-http-keep-alive), and the response head read off the connection
  (interim 1xx responses skipped). With -S the head is shown, each line
  indented by two spaces, as GNU wget does.
}
unit Wget.Requests;

{$mode objfpc}
{$H+}

interface

uses
  Wget.Connections,
  Http.ResponseHeads,
  Wget.Settings,
  Wget.Urls;

type
  { What a request carries besides the URL. }
  TRequestExtras = record
    { "identity" or "gzip". }
    AcceptEncoding: string;
    KeepAlive: Boolean;
    { '' for none. }
    Cookie: string;
    Authorization: string;
  end;

  THeadOutcome = (HeadReceived, HeadConnectionFailed, HeadNoData, HeadInvalid, HeadTooLarge,
    HeadUnsupportedEncoding);

{ RangeStart > 0 asks for the rest of the resource from there. }
function SendRequest(Connection: TConnection; constref Url: TUrl; constref Settings: TWgetSettings;
  RangeStart: Int64; constref Extras: TRequestExtras): Boolean;
{ Leaves the bytes after the head in the connection's buffer. }
function ReceiveResponseHead(Connection: TConnection; constref Settings: TWgetSettings;
  out Response: THttpResponseHead): THeadOutcome;

implementation

uses
  SysUtils,
  Sys.Streams;

const
  LineEnd = #13#10;

function SendRequest(Connection: TConnection; constref Url: TUrl; constref Settings: TWgetSettings;
  RangeStart: Int64; constref Extras: TRequestExtras): Boolean;
var
  Request: string;
begin
  Request := 'GET ' + Url.Path + ' HTTP/1.1' + LineEnd +
    'Host: ' + FormatHostHeader(Url) + LineEnd +
    'User-Agent: ' + Settings.UserAgent + LineEnd +
    'Accept: */*' + LineEnd +
    'Accept-Encoding: ' + Extras.AcceptEncoding + LineEnd;
  if RangeStart > 0 then
    Request := Request + 'Range: bytes=' + IntToStr(RangeStart) + '-' + LineEnd;
  if Extras.Authorization <> '' then
    Request := Request + 'Authorization: ' + Extras.Authorization + LineEnd;
  if Extras.Cookie <> '' then
    Request := Request + 'Cookie: ' + Extras.Cookie + LineEnd;
  if Extras.KeepAlive then
    Request := Request + 'Connection: Keep-Alive' + LineEnd + LineEnd
  else
    Request := Request + 'Connection: close' + LineEnd + LineEnd;
  Result := Connection.Send(Request);
end;

{ Each line that is not empty, indented by two spaces. }
procedure ShowHead(const Head: string);
var
  Line: string;
begin
  for Line in Head.Split([#10]) do
    if (Line <> '') and (Line <> #13) then
    begin
      if Line[Length(Line)] = #13 then
        PrintErrorStringLine('  ' + Copy(Line, 1, Length(Line) - 1))
      else
        PrintErrorStringLine('  ' + Line);
    end;
end;

function ReceiveResponseHead(Connection: TConnection; constref Settings: TWgetSettings;
  out Response: THttpResponseHead): THeadOutcome;
var
  HeadLength: PtrUInt;
  Received: Int64;
  Head: string;
  Parsed: THeadParseResult;
begin
  Response := Default(THttpResponseHead);
  while True do
  begin
    { Gather bytes until the empty line that ends the head. }
    repeat
      HeadLength := FindHeadEnd(Connection.BufferedData, Connection.BufferedCount);
      if HeadLength > 0 then
        Break;
      if Connection.BufferedCount >= ConnectionBufferSize then
        Exit(HeadTooLarge);
      Received := Connection.FillBuffer;
      if Received < 0 then
        Exit(HeadConnectionFailed);
      if Received = 0 then
        Exit(HeadNoData);
    until False;

    SetString(Head, Connection.BufferedData, HeadLength);
    if Settings.ShowServerResponse and not Settings.Quiet then
      ShowHead(Head);
    Parsed := ParseResponseHead(Head, Response);
    Connection.ConsumeBuffer(HeadLength);
    if Parsed = HeadUnsupportedCoding then
      Exit(HeadUnsupportedEncoding);
    if Parsed <> HeadParsed then
      Exit(HeadInvalid);
    { 100 Continue and other interim responses come before the real one. }
    if (Response.StatusCode >= 100) and (Response.StatusCode < 200) then
      Continue;
    Exit(HeadReceived);
  end;
end;

end.
