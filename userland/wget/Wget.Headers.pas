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
  The head of an HTTP/1.x response (RFC 9112): the status line and the
  header fields wget acts on - Content-Length, Transfer-Encoding,
  Content-Range, Content-Type, Content-Encoding, Location, Connection,
  Set-Cookie and WWW-Authenticate (the last two kept as given, each
  field on its own).

  The head is given whole (up to and including the empty line). Field
  names compare without regard to case; values have their surrounding
  white space removed. Malformed status lines, a Content-Length that is
  not a number, two Content-Lengths that differ, and transfer codings
  other than chunked are refused, as RFC 9112 says, since they make it
  impossible to know where the body ends.

  Plain Pascal (the RTL only), checked on the host by tools/WgetTest.
}
unit Wget.Headers;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

const
  MaximumHeadLength = 64 * 1024;

type
  THeadTextList = array of string;

  THttpResponseHead = record
    MajorVersion, MinorVersion: Integer;
    StatusCode: Integer;
    Reason: string;
    { -1 when not given. }
    ContentLength: Int64;
    Chunked: Boolean;
    HasContentRange: Boolean;
    RangeStart, RangeEnd: Int64;
    { -1 for "*". }
    RangeTotal: Int64;
    ContentType: string;
    HasLocation: Boolean;
    Location: string;
    { "Connection: close", or "keep-alive" (which an HTTP/1.0 server
      must say for the connection to stay). }
    ConnectionClose: Boolean;
    ConnectionKeepAlive: Boolean;
    { Lower case ("gzip"); '' for none (identity). }
    ContentEncoding: string;
    SetCookies: THeadTextList;
    Challenges: THeadTextList;
  end;

  THeadParseResult = (HeadParsed, HeadMalformed, HeadUnsupportedCoding);

{ Head is the response head (status line, fields, empty line). }
function ParseResponseHead(const Head: string; out Response: THttpResponseHead): THeadParseResult;
{ Where the head ends in Data (just after the empty line), or 0 when
  the empty line has not arrived yet. Bare LF line ends are accepted. }
function FindHeadEnd(Data: PChar; Length: PtrUInt): PtrUInt;
{ "bytes 100-199/1000" (or "/*"). }
function ParseContentRange(const Value: string; out First, Last, Total: Int64): Boolean;
{ True if the connection may carry another request after this
  response (whose body has a known end): HTTP/1.1 unless "close",
  HTTP/1.0 only with "keep-alive". }
function ConnectionPersists(constref Response: THttpResponseHead): Boolean;
{ True for codes that never have a body (1xx, 204, 304). }
function StatusHasNoBody(StatusCode: Integer): Boolean;
function StatusIsRedirect(StatusCode: Integer): Boolean;

implementation

uses
  SysUtils,
  StrUtils;

const
  Blanks = [' ', #9];
  Digits = ['0'..'9'];

function FindHeadEnd(Data: PChar; Length: PtrUInt): PtrUInt;
var
  Index: PtrUInt;
begin
  Index := 0;
  while Index < Length do
  begin
    if Data[Index] = #10 then
    begin
      if (Index + 1 < Length) and (Data[Index + 1] = #10) then
        Exit(Index + 2);
      if (Index + 2 < Length) and (Data[Index + 1] = #13) and (Data[Index + 2] = #10) then
        Exit(Index + 3);
    end;
    Inc(Index);
  end;
  Result := 0;
end;

{ Decimal digits only, 1 to 18 of them. }
function ParseDecimal(const Text: string; out Value: Int64): Boolean;
var
  Character: Char;
begin
  Value := 0;
  if (Text = '') or (Length(Text) > 18) then
    Exit(False);
  for Character in Text do
  begin
    if not (Character in Digits) then
      Exit(False);
    Value := Value * 10 + (Ord(Character) - Ord('0'));
  end;
  Result := True;
end;

{ The digits of Value from Position on; Position moves past them. }
function TakeDigits(const Value: string; var Position: Integer): string;
var
  Start: Integer;
begin
  Start := Position;
  while (Position <= Length(Value)) and (Value[Position] in Digits) do
    Inc(Position);
  Result := Copy(Value, Start, Position - Start);
end;

{ The character at Position, or #0 past the end. }
function CharacterAt(const Value: string; Position: Integer): Char;
begin
  if Position <= Length(Value) then
    Result := Value[Position]
  else
    Result := #0;
end;

function ParseContentRange(const Value: string; out First, Last, Total: Int64): Boolean;
var
  Position: Integer;
begin
  First := 0;
  Last := 0;
  Total := -1;
  Result := False;
  if not StartsText('bytes ', Value) then
    Exit;
  Position := 7;
  while CharacterAt(Value, Position) = ' ' do
    Inc(Position);
  if not ParseDecimal(TakeDigits(Value, Position), First) or (CharacterAt(Value, Position) <> '-') then
    Exit;
  Inc(Position);
  if not ParseDecimal(TakeDigits(Value, Position), Last) or (CharacterAt(Value, Position) <> '/') then
    Exit;
  Inc(Position);
  if CharacterAt(Value, Position) = '*' then
  begin
    Total := -1;
    Inc(Position);
  end
  else
  begin
    if not ParseDecimal(TakeDigits(Value, Position), Total) then
      Exit;
    if Last >= Total then
      Exit;
  end;
  Result := (Position > Length(Value)) and (First <= Last);
end;

function ConnectionPersists(constref Response: THttpResponseHead): Boolean;
begin
  if Response.ConnectionClose then
    Exit(False);
  if (Response.MajorVersion = 1) and (Response.MinorVersion = 0) then
    Exit(Response.ConnectionKeepAlive);
  Result := True;
end;

function StatusHasNoBody(StatusCode: Integer): Boolean;
begin
  Result := ((StatusCode >= 100) and (StatusCode < 200)) or (StatusCode = 204) or (StatusCode = 304);
end;

function StatusIsRedirect(StatusCode: Integer): Boolean;
begin
  Result := (StatusCode = 301) or (StatusCode = 302) or (StatusCode = 303) or (StatusCode = 307) or
    (StatusCode = 308);
end;

function DigitValue(Character: Char): Integer;
begin
  Result := Ord(Character) - Ord('0');
end;

{ "HTTP/1.1 200 OK" }
function ParseStatusLine(const Line: string; var Response: THttpResponseHead): Boolean;
begin
  Result := False;
  if (Length(Line) < 12) or not StartsText('http/', Line) then
    Exit;
  if not (Line[6] in Digits) or (Line[7] <> '.') or not (Line[8] in Digits) or (Line[9] <> ' ') then
    Exit;
  Response.MajorVersion := DigitValue(Line[6]);
  Response.MinorVersion := DigitValue(Line[8]);
  if Response.MajorVersion <> 1 then
    Exit;
  if not (Line[10] in ['1'..'5']) or not (Line[11] in Digits) or not (Line[12] in Digits) then
    Exit;
  Response.StatusCode := DigitValue(Line[10]) * 100 + DigitValue(Line[11]) * 10 + DigitValue(Line[12]);
  if Length(Line) = 12 then
    Response.Reason := ''
  else if Line[13] <> ' ' then
    Exit
  else
    Response.Reason := Copy(Line, 14, MaxInt);
  Result := True;
end;

{ Text without the blanks around it. }
function TrimBlanks(const Text: string): string;
var
  First, Last: Integer;
begin
  First := 1;
  Last := Length(Text);
  while (First <= Last) and (Text[First] in Blanks) do
    Inc(First);
  while (Last >= First) and (Text[Last] in Blanks) do
    Dec(Last);
  Result := Copy(Text, First, Last - First + 1);
end;

{ The last transfer coding in a comma separated list is "chunked"; any
  other coding (gzip, ...) is not supported. }
function ReadTransferEncoding(const Value: string; var Response: THttpResponseHead): Boolean;
var
  Coding: string;
begin
  Result := False;
  for Coding in SplitString(Value, ',') do
  begin
    if TrimBlanks(Coding) = '' then
      Continue;
    if not SameText(TrimBlanks(Coding), 'chunked') then
      Exit;
    if Response.Chunked then
      { chunked twice }
      Exit;
    Response.Chunked := True;
  end;
  Result := Response.Chunked;
end;

procedure AppendText(var List: THeadTextList; const Value: string);
begin
  SetLength(List, Length(List) + 1);
  List[High(List)] := Value;
end;

{ "close", "keep-alive" among the comma separated options. }
procedure ReadConnectionOptions(const Value: string; var Response: THttpResponseHead);
var
  Option: string;
begin
  for Option in SplitString(Value, ',') do
    if SameText(TrimBlanks(Option), 'close') then
      Response.ConnectionClose := True
    else if SameText(TrimBlanks(Option), 'keep-alive') then
      Response.ConnectionKeepAlive := True;
end;

{ The codings in the order applied; "identity" is none. Only one coding
  is kept (a second makes it "unsupported", left as it is). }
procedure ReadContentEncoding(const Value: string; var Response: THttpResponseHead);
var
  Coding: string;
begin
  for Coding in SplitString(Value, ',') do
  begin
    if (TrimBlanks(Coding) = '') or SameText(TrimBlanks(Coding), 'identity') then
      Continue;
    if Response.ContentEncoding = '' then
      Response.ContentEncoding := LowerCase(TrimBlanks(Coding))
    else
      Response.ContentEncoding := Response.ContentEncoding + ',' + LowerCase(TrimBlanks(Coding));
  end;
end;

{ One "Name: value" line into Response. }
function ParseField(const Line: string; var Response: THttpResponseHead): THeadParseResult;
var
  NameEnd: Integer;
  Name, Value: string;
  ContentLength: Int64;
begin
  Result := HeadMalformed;
  { Folded lines (obsolete) are refused. }
  if Line[1] in Blanks then
    Exit;
  NameEnd := 1;
  while (NameEnd <= Length(Line)) and (Line[NameEnd] <> ':') do
  begin
    if Line[NameEnd] in Blanks then
      Exit;
    Inc(NameEnd);
  end;
  if (NameEnd = 1) or (NameEnd > Length(Line)) then
    Exit;
  Name := Copy(Line, 1, NameEnd - 1);
  Value := TrimBlanks(Copy(Line, NameEnd + 1, MaxInt));

  if SameText(Name, 'content-length') then
  begin
    if not ParseDecimal(Value, ContentLength) then
      Exit;
    if (Response.ContentLength >= 0) and (Response.ContentLength <> ContentLength) then
      Exit;
    Response.ContentLength := ContentLength;
  end
  else if SameText(Name, 'transfer-encoding') then
  begin
    if not ReadTransferEncoding(Value, Response) then
      Exit(HeadUnsupportedCoding);
  end
  else if SameText(Name, 'content-range') then
    Response.HasContentRange := ParseContentRange(Value, Response.RangeStart, Response.RangeEnd,
      Response.RangeTotal)
  else if SameText(Name, 'content-type') then
    Response.ContentType := Value
  else if SameText(Name, 'location') then
  begin
    Response.HasLocation := Value <> '';
    Response.Location := Value;
  end
  else if SameText(Name, 'connection') then
    ReadConnectionOptions(Value, Response)
  else if SameText(Name, 'content-encoding') then
    ReadContentEncoding(Value, Response)
  else if SameText(Name, 'set-cookie') then
    AppendText(Response.SetCookies, Value)
  else if SameText(Name, 'www-authenticate') then
    AppendText(Response.Challenges, Value);
  Result := HeadParsed;
end;

function ParseResponseHead(const Head: string; out Response: THttpResponseHead): THeadParseResult;
var
  LineStart, LineEnd, ContentEnd: Integer;
  Line: string;
  IsFirstLine: Boolean;
begin
  Response := Default(THttpResponseHead);
  Response.ContentLength := -1;
  Response.RangeTotal := -1;
  Result := HeadMalformed;
  if Length(Head) > MaximumHeadLength then
    Exit;
  LineStart := 1;
  IsFirstLine := True;
  while LineStart <= Length(Head) do
  begin
    LineEnd := PosEx(#10, Head, LineStart);
    if LineEnd = 0 then
      Exit;
    ContentEnd := LineEnd;
    if (ContentEnd > LineStart) and (Head[ContentEnd - 1] = #13) then
      Dec(ContentEnd);
    if ContentEnd = LineStart then
      Break;
    Line := Copy(Head, LineStart, ContentEnd - LineStart);
    LineStart := LineEnd + 1;
    if IsFirstLine then
    begin
      if not ParseStatusLine(Line, Response) then
        Exit;
      IsFirstLine := False;
      Continue;
    end;
    Result := ParseField(Line, Response);
    if Result <> HeadParsed then
      Exit;
    Result := HeadMalformed;
  end;
  if IsFirstLine then
    Exit;
  { A chunked body's length comes from its chunks (RFC 9112 6.3). }
  if Response.Chunked then
    Response.ContentLength := -1;
  Result := HeadParsed;
end;

end.
