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
  identity encoding, a Range when continuing, "Connection: close" - one
  request per connection, so a body without a length ends with the
  connection), and the response head read off the connection (interim
  1xx responses skipped). With -S the head is shown, each line
  indented by two spaces, as GNU wget does.
}
unit Wget.Requests;

{$mode objfpc}
{$pointermath on}

interface

uses
  Wget.Connections,
  Wget.Headers,
  Wget.Settings,
  Wget.Urls;

type
  THeadOutcome = (HeadReceived, HeadConnectionFailed, HeadNoData, HeadInvalid, HeadTooLarge,
    HeadUnsupportedEncoding);

{ RangeStart > 0 asks for the rest of the resource from there. }
function SendRequest(var Connection: TConnection; constref Url: TUrl; constref Settings: TWgetSettings;
  RangeStart: Int64): Boolean;
{ Leaves the bytes after the head in the connection's buffer. }
function ReceiveResponseHead(var Connection: TConnection; constref Settings: TWgetSettings;
  out Response: THttpResponseHead): THeadOutcome;

implementation

uses
  Runtime.Text,
  Sys.Format,
  Sys.Streams,
  Sys.Text,
  Sys.Memory;

function SendRequest(var Connection: TConnection; constref Url: TUrl; constref Settings: TWgetSettings;
  RangeStart: Int64): Boolean;
var
  Builder: TTextBuilder;
  HostHeader: array[0..MaximumHostLength + 8] of Char;
  Request: PChar;
begin
  FormatHostHeader(Url, @HostHeader[0], SizeOf(HostHeader));
  BeginText(Builder);
  AppendFormatted(Builder, 'GET %s HTTP/1.1'#13#10, [ArgumentText(@Url.Path[0])]);
  AppendFormatted(Builder, 'Host: %s'#13#10, [ArgumentText(@HostHeader[0])]);
  AppendFormatted(Builder, 'User-Agent: %s'#13#10, [ArgumentText(Settings.UserAgent)]);
  AppendText(Builder, 'Accept: */*'#13#10);
  AppendText(Builder, 'Accept-Encoding: identity'#13#10);
  if RangeStart > 0 then
    AppendFormatted(Builder, 'Range: bytes=%d-'#13#10, [ArgumentNumber(RangeStart)]);
  AppendText(Builder, 'Connection: close'#13#10);
  AppendText(Builder, #13#10);
  Request := FinishText(Builder);
  Result := SendToConnection(Connection, Request, TextLength(Request));
  FreeMemory(Request);
end;

procedure ShowHead(Head: PChar; Length: PtrUInt);
var
  LineStart, LineEnd, ContentEnd: PtrUInt;
begin
  LineStart := 0;
  while LineStart < Length do
  begin
    LineEnd := LineStart;
    while (LineEnd < Length) and (Head[LineEnd] <> #10) do
      Inc(LineEnd);
    ContentEnd := LineEnd;
    if (ContentEnd > LineStart) and (Head[ContentEnd - 1] = #13) then
      Dec(ContentEnd);
    if ContentEnd > LineStart then
    begin
      WriteText(StandardError, '  ');
      WriteBytes(StandardError, Head + LineStart, ContentEnd - LineStart);
      WriteCharacter(StandardError, #10);
    end;
    LineStart := LineEnd + 1;
  end;
end;

function ReceiveResponseHead(var Connection: TConnection; constref Settings: TWgetSettings;
  out Response: THttpResponseHead): THeadOutcome;
var
  HeadLength: PtrUInt;
  Received: Int64;
  Head: PChar;
  Parsed: THeadParseResult;
begin
  FillChar(Response, SizeOf(Response), 0);
  while True do
  begin
    { Gather bytes until the empty line that ends the head. }
    repeat
      Head := PChar(@Connection.Buffer[Connection.BufferStart]);
      HeadLength := FindHeadEnd(Head, Connection.BufferEnd - Connection.BufferStart);
      if HeadLength > 0 then
        Break;
      if Connection.BufferEnd - Connection.BufferStart >= ConnectionBufferSize then
        Exit(HeadTooLarge);
      Received := FillConnectionBuffer(Connection);
      if Received < 0 then
        Exit(HeadConnectionFailed);
      if Received = 0 then
        Exit(HeadNoData);
    until False;

    Head := PChar(@Connection.Buffer[Connection.BufferStart]);
    if Settings.ShowServerResponse and not Settings.Quiet then
      ShowHead(Head, HeadLength);
    Parsed := ParseResponseHead(Head, HeadLength, Response);
    ConsumeConnectionBuffer(Connection, HeadLength);
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
