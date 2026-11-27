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
  What the location bar's text leads to, keywords first: a first word
  that is a bookmark's keyword opens the bookmark ("%s" in its address
  replaced by the words after it), one that is a search engine's keyword
  searches the rest with that engine; otherwise the text is an address
  or words for the chosen search engine (Browser.Addresses).

  Plain logic (the RTL only), checked on the host.
}
unit Browser.Keywords;

{$mode objfpc}
{$H+}

interface

uses
  Browser.Addresses,
  Browser.Bookmarks,
  Browser.SearchEngines;

{ The URL for Text; Engines and Bookmarks may be nil. }
function ResolveLocation(const Text, SearchUrl: string; Bookmarks: TBookmarkStore; Engines: TSearchEngineList;
  out Url: string): TAddressKind;

implementation

uses
  SysUtils;

function ResolveLocation(const Text, SearchUrl: string; Bookmarks: TBookmarkStore; Engines: TSearchEngineList;
  out Url: string): TAddressKind;
var
  Trimmed, FirstWord, Rest: string;
  Space, Engine: Integer;
  Mark: TBookmarkNode;
begin
  Url := '';
  Trimmed := Trim(Text);
  Space := Pos(' ', Trimmed);
  if Space > 0 then
  begin
    FirstWord := Copy(Trimmed, 1, Space - 1);
    Rest := Trim(Copy(Trimmed, Space + 1, MaxInt));
  end
  else
  begin
    FirstWord := Trimmed;
    Rest := '';
  end;
  if (FirstWord <> '') and (Bookmarks <> nil) then
  begin
    Mark := Bookmarks.FindKeyword(FirstWord);
    if Mark <> nil then
    begin
      if Pos('%s', Mark.Url) > 0 then
        Url := BuildSearchUrl(Mark.Url, Rest)
      else
        Url := Mark.Url;
      Exit(AddressUrl);
    end;
  end;
  if (FirstWord <> '') and (Rest <> '') and (Engines <> nil) then
  begin
    Engine := Engines.IndexOfKeyword(FirstWord);
    if Engine >= 0 then
    begin
      Url := BuildSearchUrl(Engines[Engine].Url, Rest);
      Exit(AddressSearch);
    end;
  end;
  Result := InterpretAddress(Text, SearchUrl, Url);
end;

end.
