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
  The search engines the search bar offers, in the user's order: a name,
  a search URL ("%s" stands for the words, form-encoded) and a keyword
  (typed before words in the location bar: "wp pascal"). A few common
  ones ship with the browser (DuckDuckGo, Wikipedia, Google, Bing), but
  none is chosen until the user picks one: until then nothing typed is
  sent anywhere (the search bar asks the user to choose; words in the
  location bar give a page saying they are not an address). Which one is
  chosen is a setting (Browser/SearchEngine), with its URL also kept as
  Browser/SearchUrl.

  The list is kept in searchengines.txt in the profile (fields
  tab-separated, in order):

    engine  name  url  keyword
    removed name                 (a shipped engine the user removed)

  A shipped engine neither listed nor removed (new in this version) is
  added at the end.

  Plain logic (the RTL only), checked on the host.
}
unit Browser.SearchEngines;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes;

type
  TSearchEngine = record
    Name: string;
    Url: string;
    Keyword: string;
    BuiltIn: Boolean;
  end;

  TSearchEngineList = class
  private
    FItems: array of TSearchEngine;
    FRemoved: TStringArray;
    function GetItem(Index: Integer): TSearchEngine;
    function GetCount: Integer;
    procedure AddShipped;
    function IsRemoved(const Name: string): Boolean;
  public
    constructor Create;
    procedure LoadFromLines(Lines: TStrings);
    procedure SaveToLines(Lines: TStrings);
    procedure Load(const Path: string);
    procedure Save(const Path: string);
    function IndexOf(const Name: string): Integer;
    { The engine whose keyword is Keyword (-1: none). }
    function IndexOfKeyword(const Keyword: string): Integer;
    function IndexOfUrl(const Url: string): Integer;
    { Adds an engine at the end; -1 (nothing added) if the name is taken
      or the URL is not a search URL. }
    function Add(const Name, Url, Keyword: string): Integer;
    procedure Remove(Index: Integer);
    { Moves engine From to place To. }
    procedure Move(From, Target: Integer);
    procedure SetKeyword(Index: Integer; const Keyword: string);
    { The shipped engines back (those removed return; the user's stay). }
    procedure RestoreDefaults;
    property Count: Integer read GetCount;
    property Items[Index: Integer]: TSearchEngine read GetItem; default;
  end;

{ Template with "%s" replaced by Words, form-encoded. }
function BuildSearchUrl(const Template, Words: string): string;
{ Whether Url can be a search URL: http or https with "%s" in it. }
function IsSearchTemplate(const Url: string): Boolean;
{ The host a search URL sends words to (for the menu's tooltip). }
function SearchHost(const Url: string): string;

implementation

uses
  Browser.TextFiles,
  Browser.Addresses,
  Browser.History;

type
  TShippedEngine = record
    Name: string;
    Url: string;
  end;

const
  ShippedEngines: array[0..3] of TShippedEngine = (
    (Name: 'DuckDuckGo'; Url: 'https://html.duckduckgo.com/html/?q=%s'),
    (Name: 'Wikipedia (English)'; Url: 'https://en.wikipedia.org/wiki/Special:Search?search=%s'),
    (Name: 'Google'; Url: 'https://www.google.com/search?q=%s'),
    (Name: 'Bing'; Url: 'https://www.bing.com/search?q=%s'));

function BuildSearchUrl(const Template, Words: string): string;
begin
  Result := StringReplace(Template, '%s', FormEncodeWords(Trim(Words)), [rfReplaceAll]);
end;

function IsSearchTemplate(const Url: string): Boolean;
var
  Lowered: string;
begin
  Lowered := FoldCase(Trim(Url));
  Result := ((Copy(Lowered, 1, 7) = 'http://') or (Copy(Lowered, 1, 8) = 'https://')) and (Pos('%s', Url) > 0) and
    (Pos(' ', Trim(Url)) = 0);
end;

function SearchHost(const Url: string): string;
begin
  Result := HostOfUrl(Url);
end;

constructor TSearchEngineList.Create;
begin
  inherited Create;
  AddShipped;
end;

function TSearchEngineList.GetItem(Index: Integer): TSearchEngine;
begin
  Result := FItems[Index];
end;

function TSearchEngineList.GetCount: Integer;
begin
  Result := Length(FItems);
end;

function TSearchEngineList.IsRemoved(const Name: string): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(FRemoved) do
    if SameText(FRemoved[Index], Name) then
      Exit(True);
  Result := False;
end;

procedure TSearchEngineList.AddShipped;
var
  Index, Place: Integer;
begin
  for Index := Low(ShippedEngines) to High(ShippedEngines) do
  begin
    if IsRemoved(ShippedEngines[Index].Name) then
      Continue;
    Place := IndexOf(ShippedEngines[Index].Name);
    if Place >= 0 then
    begin
      FItems[Place].BuiltIn := True;
      Continue;
    end;
    SetLength(FItems, Length(FItems) + 1);
    FItems[High(FItems)].Name := ShippedEngines[Index].Name;
    FItems[High(FItems)].Url := ShippedEngines[Index].Url;
    FItems[High(FItems)].Keyword := '';
    FItems[High(FItems)].BuiltIn := True;
  end;
end;

procedure TSearchEngineList.LoadFromLines(Lines: TStrings);
var
  Index: Integer;
  Fields: TStringArray;
begin
  FItems := nil;
  FRemoved := nil;
  for Index := 0 to Lines.Count - 1 do
  begin
    Fields := Lines[Index].Split([#9]);
    if Length(Fields) < 2 then
      Continue;
    if Fields[0] = 'removed' then
    begin
      SetLength(FRemoved, Length(FRemoved) + 1);
      FRemoved[High(FRemoved)] := Fields[1];
    end
    else if (Fields[0] = 'engine') and (IndexOf(Fields[1]) < 0) and IsSearchTemplate(FieldAt(Fields, 2)) then
    begin
      SetLength(FItems, Length(FItems) + 1);
      FItems[High(FItems)].Name := Fields[1];
      FItems[High(FItems)].Url := FieldAt(Fields, 2);
      FItems[High(FItems)].Keyword := FieldAt(Fields, 3);
      FItems[High(FItems)].BuiltIn := False;
    end;
  end;
  AddShipped;
end;

procedure TSearchEngineList.SaveToLines(Lines: TStrings);
var
  Index: Integer;
begin
  Lines.Clear;
  for Index := 0 to High(FItems) do
    Lines.Add(JoinFields(['engine', FItems[Index].Name, FItems[Index].Url, FItems[Index].Keyword]));
  for Index := 0 to High(FRemoved) do
    Lines.Add(JoinFields(['removed', FRemoved[Index]]));
end;

procedure TSearchEngineList.Load(const Path: string);
var
  Lines: TStringList;
begin
  Lines := ReadLines(Path);
  try
    LoadFromLines(Lines);
  finally
    Lines.Free;
  end;
end;

procedure TSearchEngineList.Save(const Path: string);
var
  Lines: TStringList;
begin
  Lines := TStringList.Create;
  try
    SaveToLines(Lines);
    WriteLines(Lines, Path);
  finally
    Lines.Free;
  end;
end;

function TSearchEngineList.IndexOf(const Name: string): Integer;
var
  Index: Integer;
begin
  for Index := 0 to High(FItems) do
    if SameText(FItems[Index].Name, Name) then
      Exit(Index);
  Result := -1;
end;

function TSearchEngineList.IndexOfKeyword(const Keyword: string): Integer;
var
  Index: Integer;
begin
  if Keyword <> '' then
    for Index := 0 to High(FItems) do
      if SameText(FItems[Index].Keyword, Keyword) then
        Exit(Index);
  Result := -1;
end;

function TSearchEngineList.IndexOfUrl(const Url: string): Integer;
var
  Index: Integer;
begin
  if Url <> '' then
    for Index := 0 to High(FItems) do
      if FItems[Index].Url = Url then
        Exit(Index);
  Result := -1;
end;

function TSearchEngineList.Add(const Name, Url, Keyword: string): Integer;
var
  Index: Integer;
begin
  Result := -1;
  if (Trim(Name) = '') or (IndexOf(Trim(Name)) >= 0) or not IsSearchTemplate(Url) then
    Exit;
  { A shipped engine added again by name is no longer removed. }
  for Index := High(FRemoved) downto 0 do
    if SameText(FRemoved[Index], Trim(Name)) then
    begin
      FRemoved[Index] := FRemoved[High(FRemoved)];
      SetLength(FRemoved, Length(FRemoved) - 1);
    end;
  SetLength(FItems, Length(FItems) + 1);
  Result := High(FItems);
  FItems[Result].Name := Trim(Name);
  FItems[Result].Url := Trim(Url);
  FItems[Result].Keyword := Trim(Keyword);
  FItems[Result].BuiltIn := False;
end;

procedure TSearchEngineList.Remove(Index: Integer);
var
  Place: Integer;
begin
  if (Index < 0) or (Index > High(FItems)) then
    Exit;
  if FItems[Index].BuiltIn then
  begin
    SetLength(FRemoved, Length(FRemoved) + 1);
    FRemoved[High(FRemoved)] := FItems[Index].Name;
  end;
  for Place := Index to High(FItems) - 1 do
    FItems[Place] := FItems[Place + 1];
  SetLength(FItems, Length(FItems) - 1);
end;

procedure TSearchEngineList.Move(From, Target: Integer);
var
  Engine: TSearchEngine;
  Place: Integer;
begin
  if (From < 0) or (From > High(FItems)) or (Target < 0) or (Target > High(FItems)) or (From = Target) then
    Exit;
  Engine := FItems[From];
  if From < Target then
    for Place := From to Target - 1 do
      FItems[Place] := FItems[Place + 1]
  else
    for Place := From downto Target + 1 do
      FItems[Place] := FItems[Place - 1];
  FItems[Target] := Engine;
end;

procedure TSearchEngineList.SetKeyword(Index: Integer; const Keyword: string);
begin
  if (Index >= 0) and (Index <= High(FItems)) then
    FItems[Index].Keyword := Trim(Keyword);
end;

procedure TSearchEngineList.RestoreDefaults;
begin
  FRemoved := nil;
  AddShipped;
end;

end.
