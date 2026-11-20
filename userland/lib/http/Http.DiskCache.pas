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
  The HTTP cache's files: one per stored response, named after a 64-bit
  FNV-1a hash of its key (the URL), in a folder the program chooses:

    FPOS-HTTP-CACHE 1
    key  status  request-time  response-time  (one per line)
    reason
    vary-key, its newlines as \n
    field count, then "name: value" lines
    an empty line, then the content (the rest of the file)

  A file whose key is not the one asked for (a hash collision) or that
  does not read is a miss. Writes go to a temporary file renamed over
  the old one, so a reader never sees half a response.

  Plain Pascal (the RTL and Classes), checked on the host by
  tools/HttpTest.
}
unit Http.DiskCache;

{$mode objfpc}
{$H+}

interface

uses
  Http.Cache;

procedure SaveCacheEntry(const Directory: string; Entry: THttpCacheEntry);
{ The entry for Key, or nil. }
function LoadCacheEntry(const Directory, Key: string): THttpCacheEntry;
procedure DeleteCacheEntry(const Directory, Key: string);

implementation

uses
  Classes,
  SysUtils,
  Http.HeaderFields;

const
  Signature = 'FPOS-HTTP-CACHE 1';

function KeyHash(const Key: string): string;
var
  Hash: QWord;
  Character: Char;
begin
  Hash := QWord($CBF29CE484222325);
  for Character in Key do
  begin
    Hash := Hash xor Ord(Character);
    Hash := Hash * QWord($100000001B3);
  end;
  Result := LowerCase(IntToHex(Hash, 16));
end;

function EntryFileName(const Directory, Key: string): string;
begin
  Result := IncludeTrailingPathDelimiter(Directory) + KeyHash(Key) + '.cache';
end;

function EscapeLine(const Text: string): string;
begin
  Result := StringReplace(StringReplace(Text, '\', '\\', [rfReplaceAll]), #10, '\n', [rfReplaceAll]);
end;

function UnescapeLine(const Text: string): string;
var
  Index: Integer;
begin
  Result := '';
  Index := 1;
  while Index <= Length(Text) do
  begin
    if (Text[Index] = '\') and (Index < Length(Text)) then
    begin
      Inc(Index);
      if Text[Index] = 'n' then
        Result := Result + #10
      else
        Result := Result + Text[Index];
    end
    else
      Result := Result + Text[Index];
    Inc(Index);
  end;
end;

procedure SaveCacheEntry(const Directory: string; Entry: THttpCacheEntry);
var
  Head: string;
  Field: THttpHeaderField;
  Stream: TFileStream;
  Name, Temporary: string;
begin
  Head := Signature + #10 + EscapeLine(Entry.Key) + #10 + IntToStr(Entry.Status) + #10 +
    IntToStr(Entry.RequestTime) + #10 + IntToStr(Entry.ResponseTime) + #10 + EscapeLine(Entry.Reason) + #10 +
    EscapeLine(Entry.VaryKey) + #10 + IntToStr(Length(Entry.Fields)) + #10;
  for Field in Entry.Fields do
    Head := Head + Field.Name + ': ' + EscapeLine(Field.Value) + #10;
  Head := Head + #10;
  Name := EntryFileName(Directory, Entry.Key);
  Temporary := Name + '.new';
  try
    Stream := TFileStream.Create(Temporary, fmCreate);
    try
      Stream.WriteBuffer(Head[1], Length(Head));
      if Length(Entry.Body) > 0 then
        Stream.WriteBuffer(Entry.Body[0], Length(Entry.Body));
    finally
      Stream.Free;
    end;
    DeleteFile(Name);
    RenameFile(Temporary, Name);
  except
    on EStreamError do
      DeleteFile(Temporary);
  end;
end;

{ The next line of Data from Position (moved past it). }
function NextLine(const Data: string; var Position: Integer; out Line: string): Boolean;
var
  Ending: Integer;
begin
  Ending := Position;
  while (Ending <= Length(Data)) and (Data[Ending] <> #10) do
    Inc(Ending);
  if Ending > Length(Data) then
    Exit(False);
  Line := Copy(Data, Position, Ending - Position);
  Position := Ending + 1;
  Result := True;
end;

function ParseEntry(const Data, Key: string): THttpCacheEntry;
var
  Position, Count, Index, Colon, Status: Integer;
  Line, StatusLine, RequestLine, ResponseLine, Reason, Vary: string;
  RequestTime, ResponseTime: Int64;
  Fields: THttpHeaderFieldArray;
begin
  Result := nil;
  Position := 1;
  if not NextLine(Data, Position, Line) or (Line <> Signature) then
    Exit;
  if not NextLine(Data, Position, Line) or (UnescapeLine(Line) <> Key) then
    Exit;
  if not NextLine(Data, Position, StatusLine) or not NextLine(Data, Position, RequestLine) or
     not NextLine(Data, Position, ResponseLine) or not NextLine(Data, Position, Reason) or
     not NextLine(Data, Position, Vary) or not NextLine(Data, Position, Line) then
    Exit;
  if not TryStrToInt(StatusLine, Status) or not TryStrToInt64(RequestLine, RequestTime) or
     not TryStrToInt64(ResponseLine, ResponseTime) or not TryStrToInt(Line, Count) or (Count < 0) then
    Exit;
  Fields := nil;
  SetLength(Fields, Count);
  for Index := 0 to Count - 1 do
  begin
    if not NextLine(Data, Position, Line) then
      Exit;
    Colon := Pos(': ', Line);
    if Colon = 0 then
      Exit;
    Fields[Index].Name := Copy(Line, 1, Colon - 1);
    Fields[Index].Value := UnescapeLine(Copy(Line, Colon + 2, MaxInt));
  end;
  if not NextLine(Data, Position, Line) or (Line <> '') then
    Exit;
  Result := THttpCacheEntry.Create;
  Result.Key := Key;
  Result.Status := Status;
  Result.Reason := UnescapeLine(Reason);
  Result.VaryKey := UnescapeLine(Vary);
  Result.RequestTime := RequestTime;
  Result.ResponseTime := ResponseTime;
  Result.Fields := Fields;
  SetLength(Result.Body, Length(Data) - Position + 1);
  if Length(Result.Body) > 0 then
    Move(Data[Position], Result.Body[0], Length(Result.Body));
end;

function LoadCacheEntry(const Directory, Key: string): THttpCacheEntry;
var
  Stream: TFileStream;
  Data: string;
  Name: string;
begin
  Result := nil;
  Name := EntryFileName(Directory, Key);
  if not FileExists(Name) then
    Exit;
  try
    Stream := TFileStream.Create(Name, fmOpenRead or fmShareDenyWrite);
    try
      Data := '';
      SetLength(Data, Stream.Size);
      if Length(Data) > 0 then
        Stream.ReadBuffer(Data[1], Length(Data));
    finally
      Stream.Free;
    end;
  except
    on EStreamError do
      Exit;
  end;
  Result := ParseEntry(Data, Key);
end;

procedure DeleteCacheEntry(const Directory, Key: string);
begin
  DeleteFile(EntryFileName(Directory, Key));
end;

end.
