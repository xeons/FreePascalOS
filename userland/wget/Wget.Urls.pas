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
  The URLs wget fetches (RFC 3986, http and https only):

    [http:// | https://]host[:port][/path][?query][#fragment]

  A URL without a scheme is http. The host is a name, an IPv4 address
  or an IPv6 address in brackets ([::1]:8080; kept without them in
  Host, and put back in the Host header); user names are refused, and
  so are IPv6 zones (fe80::1%25eth0). The fragment is dropped;
  characters that may not appear in a request line (controls, spaces,
  bytes above 127) are percent-encoded. A redirect's Location is
  resolved against the URL it came from, relative paths and dot
  segments included. The file a URL is saved to is the last segment of
  its path, decoded, or index.html.

  Plain Pascal over fixed buffers, so tools/WgetTest checks it on the
  host.
}
unit Wget.Urls;

{$mode objfpc}
{$pointermath on}

interface

const
  MaximumHostLength = 255;
  MaximumPathLength = 4095;

type
  TUrlScheme = (SchemeHttp, SchemeHttps);

  TUrl = record
    Scheme: TUrlScheme;
    Host: array[0..MaximumHostLength] of Char;
    Port: Word;
    { From the first "/" on, the query included; at least "/". }
    Path: array[0..MaximumPathLength] of Char;
  end;

function ParseUrl(Text: PChar; out Url: TUrl): Boolean;
{ Reference (absolute, "//host/...", "/path" or a relative path)
  against Base. False when the result is not an http or https URL. }
function ResolveUrl(constref Base: TUrl; Reference: PChar; out Resolved: TUrl): Boolean;
function DefaultPort(Scheme: TUrlScheme): Word;
{ "https://host:port/path" (the port only when not the default). }
procedure FormatUrl(constref Url: TUrl; Buffer: PChar; Capacity: PtrUInt);
{ True if the URL's host is an IPv6 address (it has a colon). }
function UrlHostIsIpv6(constref Url: TUrl): Boolean;
{ The Host header: the host (an IPv6 address in brackets), and the port
  when not the default. }
procedure FormatHostHeader(constref Url: TUrl; Buffer: PChar; Capacity: PtrUInt);
{ The local file name: the last path segment, decoded, or
  "index.html"; never with a "/" or a leading dot only. }
procedure DefaultFileName(constref Url: TUrl; Buffer: PChar; Capacity: PtrUInt);

implementation

function TextLength(Text: PChar): PtrUInt;
begin
  Result := 0;
  if Text <> nil then
    while Text[Result] <> #0 do
      Inc(Result);
end;

function LowerCharacter(Character: Char): Char;
begin
  if Character in ['A'..'Z'] then
    Result := Chr(Ord(Character) + 32)
  else
    Result := Character;
end;

function StartsWithIgnoringCase(Text, Prefix: PChar): Boolean;
var
  Index: PtrUInt;
begin
  Index := 0;
  while Prefix[Index] <> #0 do
  begin
    if LowerCharacter(Text[Index]) <> LowerCharacter(Prefix[Index]) then
      Exit(False);
    Inc(Index);
  end;
  Result := True;
end;

{ Appends Text to a buffer of Capacity characters at Position; False
  when it does not fit. }
function AppendLimited(Buffer: PChar; Capacity: PtrUInt; var Position: PtrUInt; Text: PChar;
  Count: PtrUInt): Boolean;
var
  Index: PtrUInt;
begin
  if Position + Count + 1 > Capacity then
    Exit(False);
  Index := 0;
  while Index < Count do
  begin
    Buffer[Position] := Text[Index];
    Inc(Position);
    Inc(Index);
  end;
  Buffer[Position] := #0;
  Result := True;
end;

function DefaultPort(Scheme: TUrlScheme): Word;
begin
  if Scheme = SchemeHttps then
    Result := 443
  else
    Result := 80;
end;

const
  HexDigits: array[0..15] of Char = '0123456789ABCDEF';

{ Copies a path, percent-encoding what may not be sent as it is. }
function CopyEncodedPath(Source: PChar; Count: PtrUInt; Destination: PChar; Capacity: PtrUInt): Boolean;
var
  Index, Position: PtrUInt;
  Character: Byte;
  Encoded: array[0..2] of Char;
begin
  Position := 0;
  Destination[0] := #0;
  Index := 0;
  while Index < Count do
  begin
    Character := Ord(Source[Index]);
    if (Character <= 32) or (Character >= 127) or (Chr(Character) in ['"', '<', '>', '\', '^', '`', '{', '|', '}'])
    then
    begin
      Encoded[0] := '%';
      Encoded[1] := HexDigits[Character shr 4];
      Encoded[2] := HexDigits[Character and 15];
      if not AppendLimited(Destination, Capacity, Position, @Encoded[0], 3) then
        Exit(False);
    end
    else if not AppendLimited(Destination, Capacity, Position, @Source[Index], 1) then
      Exit(False);
    Inc(Index);
  end;
  Result := True;
end;

{ "[ipv6]" at the start of the authority: the address (hexadecimal
  digits, colons and dots) goes into Url.Host without the brackets;
  HostEnd is where what follows the closing bracket begins. }
function ParseBracketedHost(Text: PChar; Count: PtrUInt; var Url: TUrl; out HostEnd: PtrUInt): Boolean;
var
  Closing: PtrUInt;
  Index: PtrUInt;
begin
  Result := False;
  Closing := 1;
  while (Closing < Count) and (Text[Closing] <> ']') do
    Inc(Closing);
  if (Closing >= Count) or (Closing = 1) or (Closing - 1 > MaximumHostLength) then
    Exit;
  for Index := 1 to Closing - 1 do
  begin
    if not (Text[Index] in ['0'..'9', 'a'..'f', 'A'..'F', ':', '.']) then
      Exit;
    Url.Host[Index - 1] := LowerCharacter(Text[Index]);
  end;
  Url.Host[Closing - 1] := #0;
  HostEnd := Closing + 1;
  Result := (HostEnd = Count) or (Text[HostEnd] = ':');
end;

{ A name or an IPv4 address up to the port's colon. }
function ParsePlainHost(Text: PChar; Count: PtrUInt; var Url: TUrl; out HostEnd: PtrUInt): Boolean;
var
  Index: PtrUInt;
begin
  Result := False;
  HostEnd := 0;
  while (HostEnd < Count) and (Text[HostEnd] <> ':') do
    Inc(HostEnd);
  if (HostEnd = 0) or (HostEnd > MaximumHostLength) then
    Exit;
  for Index := 0 to HostEnd - 1 do
  begin
    if not (Text[Index] in ['a'..'z', 'A'..'Z', '0'..'9', '-', '.', '_']) then
      Exit;
    Url.Host[Index] := LowerCharacter(Text[Index]);
  end;
  Url.Host[HostEnd] := #0;
  Result := True;
end;

function ParseAuthority(Text: PChar; Count: PtrUInt; var Url: TUrl): Boolean;
var
  HostEnd: PtrUInt;
  Index: PtrUInt;
  Port: LongWord;
begin
  Result := False;
  if Count = 0 then
    Exit;
  { No user names. }
  for Index := 0 to Count - 1 do
    if Text[Index] = '@' then
      Exit;
  if Text[0] = '[' then
  begin
    if not ParseBracketedHost(Text, Count, Url, HostEnd) then
      Exit;
  end
  else if not ParsePlainHost(Text, Count, Url, HostEnd) then
    Exit;
  Url.Port := DefaultPort(Url.Scheme);
  if HostEnd < Count then
  begin
    { ":port", 1 to 65535; an empty port means the default. }
    Port := 0;
    Index := HostEnd + 1;
    if Index < Count then
    begin
      while Index < Count do
      begin
        if not (Text[Index] in ['0'..'9']) then
          Exit;
        Port := Port * 10 + LongWord(Ord(Text[Index]) - Ord('0'));
        if Port > 65535 then
          Exit;
        Inc(Index);
      end;
      if Port = 0 then
        Exit;
      Url.Port := Port;
    end;
  end;
  Result := True;
end;

function ParseUrl(Text: PChar; out Url: TUrl): Boolean;
var
  Position: PChar;
  AuthorityEnd, PathEnd: PtrUInt;
begin
  FillChar(Url, SizeOf(Url), 0);
  Result := False;
  if (Text = nil) or (Text[0] = #0) then
    Exit;
  Url.Scheme := SchemeHttp;
  Position := Text;
  if StartsWithIgnoringCase(Position, 'https://') then
  begin
    Url.Scheme := SchemeHttps;
    Position := Position + 8;
  end
  else if StartsWithIgnoringCase(Position, 'http://') then
    Position := Position + 7
  else
  begin
    { Another scheme ("ftp:") is refused; "host:port" is not a scheme. }
    AuthorityEnd := 0;
    while Position[AuthorityEnd] in ['a'..'z', 'A'..'Z', '0'..'9', '+', '-', '.'] do
      Inc(AuthorityEnd);
    if (Position[AuthorityEnd] = ':') and (Position[AuthorityEnd + 1] = '/') and
       (Position[AuthorityEnd + 2] = '/') then
      Exit;
  end;
  AuthorityEnd := 0;
  while not (Position[AuthorityEnd] in [#0, '/', '?', '#']) do
    Inc(AuthorityEnd);
  if not ParseAuthority(Position, AuthorityEnd, Url) then
    Exit;
  Position := Position + AuthorityEnd;
  PathEnd := 0;
  while not (Position[PathEnd] in [#0, '#']) do
    Inc(PathEnd);
  if PathEnd = 0 then
  begin
    Url.Path[0] := '/';
    Url.Path[1] := #0;
    Exit(True);
  end;
  if Position[0] = '?' then
  begin
    { "host?query": the path is "/". }
    Url.Path[0] := '/';
    Result := CopyEncodedPath(Position, PathEnd, @Url.Path[1], MaximumPathLength);
    Exit;
  end;
  Result := CopyEncodedPath(Position, PathEnd, @Url.Path[0], MaximumPathLength + 1);
end;

{ RFC 3986 section 5.2.4, in place on a path that starts with "/" (the
  query, if any, left alone). }
procedure RemoveDotSegments(Path: PChar);
var
  Output: array[0..MaximumPathLength] of Char;
  Input, OutputLength, QueryStart, SegmentEnd: PtrUInt;
  PathLength: PtrUInt;
begin
  PathLength := TextLength(Path);
  QueryStart := 0;
  while (QueryStart < PathLength) and (Path[QueryStart] <> '?') do
    Inc(QueryStart);
  OutputLength := 0;
  Input := 0;
  while Input < QueryStart do
  begin
    { Path[Input] is "/" here. }
    SegmentEnd := Input + 1;
    while (SegmentEnd < QueryStart) and (Path[SegmentEnd] <> '/') do
      Inc(SegmentEnd);
    if (SegmentEnd - Input = 2) and (Path[Input + 1] = '.') then
    begin
      { "/." }
      if SegmentEnd = QueryStart then
      begin
        Output[OutputLength] := '/';
        Inc(OutputLength);
      end;
    end
    else if (SegmentEnd - Input = 3) and (Path[Input + 1] = '.') and (Path[Input + 2] = '.') then
    begin
      { "/..": drop the last output segment. }
      while (OutputLength > 0) and (Output[OutputLength - 1] <> '/') do
        Dec(OutputLength);
      if OutputLength > 0 then
        Dec(OutputLength);
      if SegmentEnd = QueryStart then
      begin
        Output[OutputLength] := '/';
        Inc(OutputLength);
      end;
    end
    else
    begin
      Move(Path[Input], Output[OutputLength], SegmentEnd - Input);
      OutputLength := OutputLength + SegmentEnd - Input;
    end;
    Input := SegmentEnd;
  end;
  if OutputLength = 0 then
  begin
    Output[0] := '/';
    OutputLength := 1;
  end;
  Move(Path[QueryStart], Output[OutputLength], PathLength - QueryStart);
  OutputLength := OutputLength + PathLength - QueryStart;
  Move(Output[0], Path[0], OutputLength);
  Path[OutputLength] := #0;
end;

function ResolveUrl(constref Base: TUrl; Reference: PChar; out Resolved: TUrl): Boolean;
var
  Merged: array[0..2 * MaximumPathLength + 2] of Char;
  Position, DirectoryEnd, Index: PtrUInt;
  Scheme: array[0..15] of Char;
  ReferenceLength: PtrUInt;
begin
  Resolved := Base;
  Result := False;
  if (Reference = nil) or (Reference[0] = #0) then
    Exit;
  ReferenceLength := TextLength(Reference);
  if StartsWithIgnoringCase(Reference, 'http://') or StartsWithIgnoringCase(Reference, 'https://') then
    Exit(ParseUrl(Reference, Resolved));
  { Another scheme: refused. }
  Index := 0;
  while Reference[Index] in ['a'..'z', 'A'..'Z', '0'..'9', '+', '-', '.'] do
    Inc(Index);
  if (Index > 0) and (Reference[Index] = ':') then
    Exit;
  if (Reference[0] = '/') and (Reference[1] = '/') then
  begin
    { Network path: the base's scheme. }
    if Base.Scheme = SchemeHttps then
      Scheme := 'https:'
    else
      Scheme := 'http:';
    Position := 0;
    Merged[0] := #0;
    if not AppendLimited(@Merged[0], SizeOf(Merged), Position, @Scheme[0], TextLength(@Scheme[0])) or
       not AppendLimited(@Merged[0], SizeOf(Merged), Position, Reference, ReferenceLength) then
      Exit;
    Exit(ParseUrl(@Merged[0], Resolved));
  end;

  Position := 0;
  Merged[0] := #0;
  if Reference[0] = '/' then
  begin
    if not AppendLimited(@Merged[0], SizeOf(Merged), Position, Reference, ReferenceLength) then
      Exit;
  end
  else if Reference[0] = '?' then
  begin
    { The base path with a new query. }
    Index := 0;
    while (Base.Path[Index] <> #0) and (Base.Path[Index] <> '?') do
      Inc(Index);
    if not AppendLimited(@Merged[0], SizeOf(Merged), Position, @Base.Path[0], Index) or
       not AppendLimited(@Merged[0], SizeOf(Merged), Position, Reference, ReferenceLength) then
      Exit;
  end
  else
  begin
    { The base path up to its last "/", then the reference. }
    Index := 0;
    DirectoryEnd := 0;
    while (Base.Path[Index] <> #0) and (Base.Path[Index] <> '?') do
    begin
      if Base.Path[Index] = '/' then
        DirectoryEnd := Index + 1;
      Inc(Index);
    end;
    if not AppendLimited(@Merged[0], SizeOf(Merged), Position, @Base.Path[0], DirectoryEnd) or
       not AppendLimited(@Merged[0], SizeOf(Merged), Position, Reference, ReferenceLength) then
      Exit;
  end;
  { Drop a fragment. }
  Index := 0;
  while (Merged[Index] <> #0) and (Merged[Index] <> '#') do
    Inc(Index);
  if not CopyEncodedPath(@Merged[0], Index, @Resolved.Path[0], MaximumPathLength + 1) then
    Exit;
  RemoveDotSegments(@Resolved.Path[0]);
  Result := True;
end;

function UrlHostIsIpv6(constref Url: TUrl): Boolean;
var
  Index: PtrUInt;
begin
  Index := 0;
  while Url.Host[Index] <> #0 do
  begin
    if Url.Host[Index] = ':' then
      Exit(True);
    Inc(Index);
  end;
  Result := False;
end;

procedure FormatHostHeader(constref Url: TUrl; Buffer: PChar; Capacity: PtrUInt);
var
  Position: PtrUInt;
  Digits: array[0..7] of Char;
  DigitCount: Integer;
  Port: LongWord;
  Index: Integer;
begin
  Position := 0;
  if Capacity = 0 then
    Exit;
  Buffer[0] := #0;
  if UrlHostIsIpv6(Url) then
  begin
    AppendLimited(Buffer, Capacity, Position, '[', 1);
    AppendLimited(Buffer, Capacity, Position, @Url.Host[0], TextLength(@Url.Host[0]));
    AppendLimited(Buffer, Capacity, Position, ']', 1);
  end
  else
    AppendLimited(Buffer, Capacity, Position, @Url.Host[0], TextLength(@Url.Host[0]));
  if Url.Port <> DefaultPort(Url.Scheme) then
  begin
    Port := Url.Port;
    DigitCount := 0;
    repeat
      Digits[DigitCount] := Chr(Ord('0') + Port mod 10);
      Port := Port div 10;
      Inc(DigitCount);
    until Port = 0;
    AppendLimited(Buffer, Capacity, Position, ':', 1);
    for Index := DigitCount - 1 downto 0 do
      AppendLimited(Buffer, Capacity, Position, @Digits[Index], 1);
  end;
end;

procedure FormatUrl(constref Url: TUrl; Buffer: PChar; Capacity: PtrUInt);
var
  Position: PtrUInt;
  HostPart: array[0..MaximumHostLength + 8] of Char;
begin
  Position := 0;
  if Capacity = 0 then
    Exit;
  Buffer[0] := #0;
  if Url.Scheme = SchemeHttps then
    AppendLimited(Buffer, Capacity, Position, 'https://', 8)
  else
    AppendLimited(Buffer, Capacity, Position, 'http://', 7);
  FormatHostHeader(Url, @HostPart[0], SizeOf(HostPart));
  AppendLimited(Buffer, Capacity, Position, @HostPart[0], TextLength(@HostPart[0]));
  AppendLimited(Buffer, Capacity, Position, @Url.Path[0], TextLength(@Url.Path[0]));
end;

function HexValue(Character: Char): Integer;
begin
  case Character of
    '0'..'9': Result := Ord(Character) - Ord('0');
    'a'..'f': Result := Ord(Character) - Ord('a') + 10;
    'A'..'F': Result := Ord(Character) - Ord('A') + 10;
  else
    Result := -1;
  end;
end;

procedure DefaultFileName(constref Url: TUrl; Buffer: PChar; Capacity: PtrUInt);
const
  IndexName: PChar = 'index.html';
var
  SegmentStart, SegmentEnd, Index, Position: PtrUInt;
  Character: Char;
  Decoded: Integer;
begin
  if Capacity = 0 then
    Exit;
  SegmentEnd := 0;
  while (Url.Path[SegmentEnd] <> #0) and (Url.Path[SegmentEnd] <> '?') do
    Inc(SegmentEnd);
  SegmentStart := SegmentEnd;
  while (SegmentStart > 0) and (Url.Path[SegmentStart - 1] <> '/') do
    Dec(SegmentStart);
  Position := 0;
  Buffer[0] := #0;
  Index := SegmentStart;
  while Index < SegmentEnd do
  begin
    Character := Url.Path[Index];
    if (Character = '%') and (Index + 2 < SegmentEnd) and (HexValue(Url.Path[Index + 1]) >= 0) and
       (HexValue(Url.Path[Index + 2]) >= 0) then
    begin
      Decoded := HexValue(Url.Path[Index + 1]) * 16 + HexValue(Url.Path[Index + 2]);
      { Never a "/", a NUL or a control character in a file name: those
        stay encoded. }
      if (Decoded >= 32) and (Decoded <> Ord('/')) and (Decoded <> 127) then
      begin
        Character := Chr(Decoded);
        Index := Index + 2;
      end;
    end;
    AppendLimited(Buffer, Capacity, Position, @Character, 1);
    Inc(Index);
  end;
  if (Position = 0) or ((Position = 1) and (Buffer[0] = '.')) or
     ((Position = 2) and (Buffer[0] = '.') and (Buffer[1] = '.')) then
  begin
    Position := 0;
    AppendLimited(Buffer, Capacity, Position, IndexName, TextLength(IndexName));
  end;
end;

end.
