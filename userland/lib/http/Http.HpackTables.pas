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
  HPACK's tables (RFC 7541 sections 2.3 and 4, appendix A): the static
  table of 61 entries, and the dynamic table, a ring of entries newest
  first whose size is the sum of 32 + name length + value length per
  entry, kept under its maximum by evicting the oldest. Index 1 to 61
  is the static table, 62 on the dynamic one.

  The ring is an array that doubles when full and is never shrunk while
  the connection lasts; its size bound (the SETTINGS_HEADER_TABLE_SIZE
  in force) keeps it to a few dozen entries.

  Plain Pascal (the RTL only), checked on the host by tools/HttpTest.
}
unit Http.HpackTables;

{$mode objfpc}
{$H+}

interface

const
  StaticTableCount = 61;
  EntryOverhead = 32;
  DefaultHeaderTableSize = 4096;

type
  THpackEntry = record
    Name: string;
    Value: string;
  end;

  THpackDynamicTable = class
  private
    FEntries: array of THpackEntry;
    { FEntries[FNewest] is index 62; older ones follow, wrapping. }
    FNewest: Integer;
    FCount: Integer;
    FSize: Integer;
    FMaximumSize: Integer;
    procedure EvictOldest;
    procedure Grow;
  public
    constructor Create(MaximumSize: Integer = DefaultHeaderTableSize);
    { An entry larger than the maximum empties the table and is not
      added (section 4.4). }
    procedure Add(const Name, Value: string);
    procedure SetMaximumSize(Value: Integer);
    { Position 0 is the newest. }
    function Entry(Position: Integer): THpackEntry;
    property Count: Integer read FCount;
    property Size: Integer read FSize;
    property MaximumSize: Integer read FMaximumSize;
  end;

function EntrySize(const Name, Value: string): Integer;
function StaticEntry(Index: Integer): THpackEntry;
{ The static index of an exact match, or 0; NameIndex is the first
  index with the name, or 0. }
function FindStatic(const Name, Value: string; out NameIndex: Integer): Integer;

implementation

const
  StaticNames: array[1..StaticTableCount] of string = (
    ':authority', ':method', ':method', ':path', ':path', ':scheme', ':scheme', ':status', ':status',
    ':status', ':status', ':status', ':status', ':status', 'accept-charset', 'accept-encoding',
    'accept-language', 'accept-ranges', 'accept', 'access-control-allow-origin', 'age', 'allow',
    'authorization', 'cache-control', 'content-disposition', 'content-encoding', 'content-language',
    'content-length', 'content-location', 'content-range', 'content-type', 'cookie', 'date', 'etag', 'expect',
    'expires', 'from', 'host', 'if-match', 'if-modified-since', 'if-none-match', 'if-range',
    'if-unmodified-since', 'last-modified', 'link', 'location', 'max-forwards', 'proxy-authenticate',
    'proxy-authorization', 'range', 'referer', 'refresh', 'retry-after', 'server', 'set-cookie',
    'strict-transport-security', 'transfer-encoding', 'user-agent', 'vary', 'via', 'www-authenticate');

  StaticValues: array[1..StaticTableCount] of string = (
    '', 'GET', 'POST', '/', '/index.html', 'http', 'https', '200', '204', '206', '304', '400', '404', '500',
    '', 'gzip, deflate', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '',
    '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '');

function EntrySize(const Name, Value: string): Integer;
begin
  Result := EntryOverhead + Length(Name) + Length(Value);
end;

function StaticEntry(Index: Integer): THpackEntry;
begin
  Result.Name := StaticNames[Index];
  Result.Value := StaticValues[Index];
end;

function FindStatic(const Name, Value: string; out NameIndex: Integer): Integer;
var
  Index: Integer;
begin
  NameIndex := 0;
  for Index := 1 to StaticTableCount do
    if StaticNames[Index] = Name then
    begin
      if NameIndex = 0 then
        NameIndex := Index;
      if StaticValues[Index] = Value then
        Exit(Index);
    end;
  Result := 0;
end;

constructor THpackDynamicTable.Create(MaximumSize: Integer);
begin
  inherited Create;
  FMaximumSize := MaximumSize;
end;

procedure THpackDynamicTable.EvictOldest;
var
  Oldest: Integer;
begin
  Oldest := (FNewest + FCount - 1) mod Length(FEntries);
  Dec(FSize, EntrySize(FEntries[Oldest].Name, FEntries[Oldest].Value));
  FEntries[Oldest] := Default(THpackEntry);
  Dec(FCount);
end;

procedure THpackDynamicTable.Grow;
var
  Larger: array of THpackEntry;
  Position: Integer;
begin
  Larger := nil;
  if Length(FEntries) = 0 then
    SetLength(Larger, 16)
  else
    SetLength(Larger, Length(FEntries) * 2);
  for Position := 0 to FCount - 1 do
    Larger[Position] := FEntries[(FNewest + Position) mod Length(FEntries)];
  FEntries := Larger;
  FNewest := 0;
end;

procedure THpackDynamicTable.Add(const Name, Value: string);
var
  Needed: Integer;
begin
  Needed := EntrySize(Name, Value);
  while (FCount > 0) and (FSize + Needed > FMaximumSize) do
    EvictOldest;
  if Needed > FMaximumSize then
    Exit;
  if FCount = Length(FEntries) then
    Grow;
  FNewest := (FNewest - 1 + Length(FEntries)) mod Length(FEntries);
  FEntries[FNewest].Name := Name;
  FEntries[FNewest].Value := Value;
  Inc(FCount);
  Inc(FSize, Needed);
end;

procedure THpackDynamicTable.SetMaximumSize(Value: Integer);
begin
  FMaximumSize := Value;
  while (FCount > 0) and (FSize > FMaximumSize) do
    EvictOldest;
end;

function THpackDynamicTable.Entry(Position: Integer): THpackEntry;
begin
  Result := FEntries[(FNewest + Position) mod Length(FEntries)];
end;

end.
