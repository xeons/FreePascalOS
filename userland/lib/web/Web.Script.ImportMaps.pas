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
  Import maps (HTML 8.1.5.x): a document's <script type=importmap>
  entries, merged as the maps arrive (an entry already there wins), and
  module specifier resolution through them: the most specific scope
  that covers the referrer first, then the top-level imports; an exact
  key, else the longest key ending in "/" that the specifier starts
  with. The JSON is read by the caller (the script engine's JSON.parse)
  and handed over as triples.
}
unit Web.Script.ImportMaps;

{$mode objfpc}
{$H+}

interface

uses
  Url.Records;

type
  TImportMapResult = (ImportNoMatch, ImportResolved, ImportBlocked);

  TImportMapEntry = record
    { The scope's URL ('' for the top-level imports). }
    Scope: string;
    { The normalized specifier key. }
    Key: string;
    { The address; '' when null (the specifier is blocked). }
    Address: string;
  end;

  TImportMap = class
  private
    FEntries: array of TImportMapEntry;
    function Has(const Scope, Key: string): Boolean;
    function MatchIn(const Scope, Normalized: string; out Url: string): TImportMapResult;
  public
    { Adds an entry of a map read against Base: Scope '' for "imports",
      else a key of "scopes"; ValueIsString False for a value that is
      not a string (null). }
    procedure AddEntry(const Scope, Key, Value: string; ValueIsString: Boolean; constref Base: TUrlRecord);
    function IsEmpty: Boolean;
    { Resolves Specifier from a module at Referrer (relative ones
      against ReferrerBase); Url is the result when ImportResolved. }
    function Resolve(const Specifier, Referrer: string; constref ReferrerBase: TUrlRecord;
      out Url: string): TImportMapResult;
  end;

{ "/x", "./x", "../x" (resolved against a base). }
function IsRelativeSpecifier(const Specifier: string): Boolean;
{ A URL-like specifier parsed (relative ones against Base); False for a bare one. }
function ParseUrlLike(const Specifier: string; constref Base: TUrlRecord; out Url: TUrlRecord): Boolean;

implementation

uses
  Url.Parser;

function IsRelativeSpecifier(const Specifier: string): Boolean;
begin
  Result := (Copy(Specifier, 1, 1) = '/') or (Copy(Specifier, 1, 2) = './') or (Copy(Specifier, 1, 3) = '../');
end;

function ParseUrlLike(const Specifier: string; constref Base: TUrlRecord; out Url: TUrlRecord): Boolean;
begin
  if IsRelativeSpecifier(Specifier) then
    Result := ParseUrl(Specifier, Base, Url)
  else
    Result := ParseUrl(Specifier, Url);
end;

function EndsWithSlash(const Text: string): Boolean;
begin
  Result := (Text <> '') and (Text[Length(Text)] = '/');
end;

function StartsWith(const Text, Prefix: string): Boolean;
begin
  Result := (Length(Text) >= Length(Prefix)) and (Copy(Text, 1, Length(Prefix)) = Prefix);
end;

function TImportMap.Has(const Scope, Key: string): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(FEntries) do
    if (FEntries[Index].Scope = Scope) and (FEntries[Index].Key = Key) then
      Exit(True);
  Result := False;
end;

procedure TImportMap.AddEntry(const Scope, Key, Value: string; ValueIsString: Boolean; constref Base: TUrlRecord);
var
  Parsed: TUrlRecord;
  Entry: TImportMapEntry;
begin
  if Key = '' then
    Exit;
  Entry.Scope := '';
  if Scope <> '' then
  begin
    if not ParseUrl(Scope, Base, Parsed) then
      Exit;
    Entry.Scope := SerializeUrl(Parsed);
  end;
  if ParseUrlLike(Key, Base, Parsed) then
    Entry.Key := SerializeUrl(Parsed)
  else
    Entry.Key := Key;
  Entry.Address := '';
  if ValueIsString and ParseUrlLike(Value, Base, Parsed) then
    Entry.Address := SerializeUrl(Parsed);
  { A prefix key needs a prefix address. }
  if EndsWithSlash(Entry.Key) and not EndsWithSlash(Entry.Address) then
    Entry.Address := '';
  if Has(Entry.Scope, Entry.Key) then
    Exit;
  SetLength(FEntries, Length(FEntries) + 1);
  FEntries[High(FEntries)] := Entry;
end;

function TImportMap.IsEmpty: Boolean;
begin
  Result := Length(FEntries) = 0;
end;

function TImportMap.MatchIn(const Scope, Normalized: string; out Url: string): TImportMapResult;
var
  Index, Best: Integer;
  Base, Target: TUrlRecord;
begin
  Url := '';
  Best := -1;
  for Index := 0 to High(FEntries) do
    if FEntries[Index].Scope = Scope then
    begin
      if FEntries[Index].Key = Normalized then
      begin
        Best := Index;
        Break;
      end;
      if EndsWithSlash(FEntries[Index].Key) and StartsWith(Normalized, FEntries[Index].Key) and
        ((Best < 0) or (Length(FEntries[Index].Key) > Length(FEntries[Best].Key))) then
        Best := Index;
    end;
  if Best < 0 then
    Exit(ImportNoMatch);
  if FEntries[Best].Address = '' then
    Exit(ImportBlocked);
  if FEntries[Best].Key = Normalized then
  begin
    Url := FEntries[Best].Address;
    Exit(ImportResolved);
  end;
  { What follows the prefix, against the prefix's address (and still
    under it: "../" cannot climb out). }
  if not ParseUrl(FEntries[Best].Address, Base) or
    not ParseUrl(Copy(Normalized, Length(FEntries[Best].Key) + 1, MaxInt), Base, Target) then
    Exit(ImportBlocked);
  Url := SerializeUrl(Target);
  if not StartsWith(Url, FEntries[Best].Address) then
    Exit(ImportBlocked);
  Result := ImportResolved;
end;

function TImportMap.Resolve(const Specifier, Referrer: string; constref ReferrerBase: TUrlRecord;
  out Url: string): TImportMapResult;
var
  AsUrl: TUrlRecord;
  HasUrl: Boolean;
  Normalized, BestScope: string;
  Index: Integer;
  Tried: array of string;

  function Tested(const Scope: string): Boolean;
  var
    Item: Integer;
  begin
    for Item := 0 to High(Tried) do
      if Tried[Item] = Scope then
        Exit(True);
    Result := False;
  end;

begin
  Url := '';
  HasUrl := ParseUrlLike(Specifier, ReferrerBase, AsUrl);
  if HasUrl then
    Normalized := SerializeUrl(AsUrl)
  else
    Normalized := Specifier;
  { The scopes that cover the referrer, the most specific (longest) first. }
  Tried := nil;
  repeat
    BestScope := '';
    for Index := 0 to High(FEntries) do
      if (FEntries[Index].Scope <> '') and not Tested(FEntries[Index].Scope) and
        ((FEntries[Index].Scope = Referrer) or
         (EndsWithSlash(FEntries[Index].Scope) and StartsWith(Referrer, FEntries[Index].Scope))) and
        (Length(FEntries[Index].Scope) > Length(BestScope)) then
        BestScope := FEntries[Index].Scope;
    if BestScope = '' then
      Break;
    SetLength(Tried, Length(Tried) + 1);
    Tried[High(Tried)] := BestScope;
    Result := MatchIn(BestScope, Normalized, Url);
    if Result <> ImportNoMatch then
      Exit;
  until False;
  Result := MatchIn('', Normalized, Url);
  if Result <> ImportNoMatch then
    Exit;
  if HasUrl then
  begin
    Url := Normalized;
    Result := ImportResolved;
  end;
end;

end.
