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
  Content-Range, Content-Type, Location and Connection.

  The head is given whole (up to and including the empty line). Field
  names compare without regard to case; values have their surrounding
  white space removed. Malformed status lines, a Content-Length that is
  not a number, two Content-Lengths that differ, and transfer codings
  other than chunked are refused, as RFC 9112 says, since they make it
  impossible to know where the body ends.

  Plain Pascal, checked on the host by tools/WgetTest.
}
unit Wget.Headers;

{$mode objfpc}
{$pointermath on}

interface

const
  MaximumHeadLength = 64 * 1024;
  FieldValueCapacity = 4096;

type
  THttpResponseHead = record
    MajorVersion, MinorVersion: Integer;
    StatusCode: Integer;
    Reason: array[0..127] of Char;
    { -1 when not given. }
    ContentLength: Int64;
    Chunked: Boolean;
    HasContentRange: Boolean;
    RangeStart, RangeEnd: Int64;
    { -1 for "*". }
    RangeTotal: Int64;
    ContentType: array[0..127] of Char;
    HasLocation: Boolean;
    Location: array[0..FieldValueCapacity - 1] of Char;
    ConnectionClose: Boolean;
  end;

  THeadParseResult = (HeadParsed, HeadMalformed, HeadUnsupportedCoding);

{ Head points at the response head (status line, fields, empty line). }
function ParseResponseHead(Head: PChar; Length: PtrUInt; out Response: THttpResponseHead): THeadParseResult;
{ Where the head ends in Data (just after the empty line), or 0 when
  the empty line has not arrived yet. Bare LF line ends are accepted. }
function FindHeadEnd(Data: PChar; Length: PtrUInt): PtrUInt;
{ "bytes 100-199/1000" (or "/*"). }
function ParseContentRange(Value: PChar; out First, Last, Total: Int64): Boolean;
{ True for codes that never have a body (1xx, 204, 304). }
function StatusHasNoBody(StatusCode: Integer): Boolean;
function StatusIsRedirect(StatusCode: Integer): Boolean;

implementation

function LowerCharacter(Character: Char): Char;
begin
  if Character in ['A'..'Z'] then
    Result := Chr(Ord(Character) + 32)
  else
    Result := Character;
end;

{ Name[0..Count) equals Expected (lower case) without regard to case. }
function NameIs(Name: PChar; Count: PtrUInt; Expected: PChar): Boolean;
var
  Index: PtrUInt;
begin
  Index := 0;
  while Index < Count do
  begin
    if (Expected[Index] = #0) or (LowerCharacter(Name[Index]) <> Expected[Index]) then
      Exit(False);
    Inc(Index);
  end;
  Result := Expected[Count] = #0;
end;

procedure CopyValue(Source: PChar; Count: PtrUInt; Destination: PChar; Capacity: PtrUInt);
var
  Index: PtrUInt;
begin
  Index := 0;
  while (Index < Count) and (Index + 1 < Capacity) do
  begin
    Destination[Index] := Source[Index];
    Inc(Index);
  end;
  Destination[Index] := #0;
end;

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

function ParseDecimal(Text: PChar; Count: PtrUInt; out Value: Int64): Boolean;
var
  Index: PtrUInt;
begin
  Value := 0;
  if (Count = 0) or (Count > 18) then
    Exit(False);
  for Index := 0 to Count - 1 do
  begin
    if not (Text[Index] in ['0'..'9']) then
      Exit(False);
    Value := Value * 10 + (Ord(Text[Index]) - Ord('0'));
  end;
  Result := True;
end;

function ParseContentRange(Value: PChar; out First, Last, Total: Int64): Boolean;
var
  Position, Start: PtrUInt;
begin
  First := 0;
  Last := 0;
  Total := -1;
  Result := False;
  if not NameIs(Value, 6, 'bytes ') then
    Exit;
  Position := 6;
  while Value[Position] = ' ' do
    Inc(Position);
  Start := Position;
  while Value[Position] in ['0'..'9'] do
    Inc(Position);
  if (Value[Position] <> '-') or not ParseDecimal(Value + Start, Position - Start, First) then
    Exit;
  Inc(Position);
  Start := Position;
  while Value[Position] in ['0'..'9'] do
    Inc(Position);
  if (Value[Position] <> '/') or not ParseDecimal(Value + Start, Position - Start, Last) then
    Exit;
  Inc(Position);
  if Value[Position] = '*' then
  begin
    Total := -1;
    Inc(Position);
  end
  else
  begin
    Start := Position;
    while Value[Position] in ['0'..'9'] do
      Inc(Position);
    if not ParseDecimal(Value + Start, Position - Start, Total) then
      Exit;
    if Last >= Total then
      Exit;
  end;
  Result := (Value[Position] = #0) and (First <= Last);
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

{ "HTTP/1.1 200 OK" }
function ParseStatusLine(Line: PChar; Count: PtrUInt; var Response: THttpResponseHead): Boolean;
var
  Position: PtrUInt;
begin
  Result := False;
  if (Count < 12) or not NameIs(Line, 5, 'http/') then
    Exit;
  if not (Line[5] in ['0'..'9']) or (Line[6] <> '.') or not (Line[7] in ['0'..'9']) or (Line[8] <> ' ') then
    Exit;
  Response.MajorVersion := Ord(Line[5]) - Ord('0');
  Response.MinorVersion := Ord(Line[7]) - Ord('0');
  if Response.MajorVersion <> 1 then
    Exit;
  if not (Line[9] in ['1'..'5']) or not (Line[10] in ['0'..'9']) or not (Line[11] in ['0'..'9']) then
    Exit;
  Response.StatusCode := (Ord(Line[9]) - Ord('0')) * 100 + (Ord(Line[10]) - Ord('0')) * 10 + (Ord(Line[11]) -
    Ord('0'));
  Position := 12;
  if Position < Count then
  begin
    if Line[Position] <> ' ' then
      Exit;
    Inc(Position);
  end;
  CopyValue(Line + Position, Count - Position, @Response.Reason[0], SizeOf(Response.Reason));
  Result := True;
end;

{ The last transfer coding in a comma separated list is "chunked"; any
  other coding (gzip, ...) is not supported. }
function ReadTransferEncoding(Value: PChar; Count: PtrUInt; var Response: THttpResponseHead): Boolean;
var
  Start, Finish: PtrUInt;
begin
  Result := False;
  Start := 0;
  while Start < Count do
  begin
    while (Start < Count) and (Value[Start] in [' ', #9, ',']) do
      Inc(Start);
    if Start >= Count then
      Break;
    Finish := Start;
    while (Finish < Count) and (Value[Finish] <> ',') do
      Inc(Finish);
    while (Finish > Start) and (Value[Finish - 1] in [' ', #9]) do
      Dec(Finish);
    if not NameIs(Value + Start, Finish - Start, 'chunked') then
      Exit;
    if Response.Chunked then
      { chunked twice }
      Exit;
    Response.Chunked := True;
    Start := Finish;
    while (Start < Count) and (Value[Start] <> ',') do
      Inc(Start);
  end;
  Result := Response.Chunked;
end;

function ParseResponseHead(Head: PChar; Length: PtrUInt; out Response: THttpResponseHead): THeadParseResult;
var
  LineStart, LineEnd, NameEnd, ValueStart, ValueEnd: PtrUInt;
  ContentLength: Int64;
  IsFirstLine: Boolean;
  RangeText: array[0..127] of Char;
begin
  FillChar(Response, SizeOf(Response), 0);
  Response.ContentLength := -1;
  Response.RangeTotal := -1;
  Result := HeadMalformed;
  if Length > MaximumHeadLength then
    Exit;
  LineStart := 0;
  IsFirstLine := True;
  while LineStart < Length do
  begin
    LineEnd := LineStart;
    while (LineEnd < Length) and (Head[LineEnd] <> #10) do
      Inc(LineEnd);
    if LineEnd >= Length then
      Exit;
    ValueEnd := LineEnd;
    if (ValueEnd > LineStart) and (Head[ValueEnd - 1] = #13) then
      Dec(ValueEnd);
    if ValueEnd = LineStart then
      Break;
    if IsFirstLine then
    begin
      if not ParseStatusLine(Head + LineStart, ValueEnd - LineStart, Response) then
        Exit;
      IsFirstLine := False;
      LineStart := LineEnd + 1;
      Continue;
    end;
    { Folded lines (obsolete) are refused. }
    if Head[LineStart] in [' ', #9] then
      Exit;
    NameEnd := LineStart;
    while (NameEnd < ValueEnd) and (Head[NameEnd] <> ':') do
    begin
      if Head[NameEnd] in [' ', #9] then
        Exit;
      Inc(NameEnd);
    end;
    if (NameEnd = LineStart) or (NameEnd >= ValueEnd) then
      Exit;
    ValueStart := NameEnd + 1;
    while (ValueStart < ValueEnd) and (Head[ValueStart] in [' ', #9]) do
      Inc(ValueStart);
    while (ValueEnd > ValueStart) and (Head[ValueEnd - 1] in [' ', #9]) do
      Dec(ValueEnd);

    if NameIs(Head + LineStart, NameEnd - LineStart, 'content-length') then
    begin
      if not ParseDecimal(Head + ValueStart, ValueEnd - ValueStart, ContentLength) then
        Exit;
      if (Response.ContentLength >= 0) and (Response.ContentLength <> ContentLength) then
        Exit;
      Response.ContentLength := ContentLength;
    end
    else if NameIs(Head + LineStart, NameEnd - LineStart, 'transfer-encoding') then
    begin
      if not ReadTransferEncoding(Head + ValueStart, ValueEnd - ValueStart, Response) then
        Exit(HeadUnsupportedCoding);
    end
    else if NameIs(Head + LineStart, NameEnd - LineStart, 'content-range') then
    begin
      CopyValue(Head + ValueStart, ValueEnd - ValueStart, @RangeText[0], SizeOf(RangeText));
      Response.HasContentRange := ParseContentRange(@RangeText[0], Response.RangeStart, Response.RangeEnd,
        Response.RangeTotal);
    end
    else if NameIs(Head + LineStart, NameEnd - LineStart, 'content-type') then
      CopyValue(Head + ValueStart, ValueEnd - ValueStart, @Response.ContentType[0], SizeOf(Response.ContentType))
    else if NameIs(Head + LineStart, NameEnd - LineStart, 'location') then
    begin
      Response.HasLocation := ValueEnd > ValueStart;
      CopyValue(Head + ValueStart, ValueEnd - ValueStart, @Response.Location[0], SizeOf(Response.Location));
    end
    else if NameIs(Head + LineStart, NameEnd - LineStart, 'connection') then
    begin
      if NameIs(Head + ValueStart, ValueEnd - ValueStart, 'close') then
        Response.ConnectionClose := True;
    end;
    LineStart := LineEnd + 1;
  end;
  if IsFirstLine then
    Exit;
  { A chunked body's length comes from its chunks (RFC 9112 6.3). }
  if Response.Chunked then
    Response.ContentLength := -1;
  Result := HeadParsed;
end;

end.
