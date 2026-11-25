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
  What the browser asks of a web view beyond showing pages, in one
  place: a tab's back and forward entries (the Back and Forward menus,
  the session), going several entries at once, giving a restored tab
  its entries, highlighting every match of a find, and the page's
  display options. The session's entries are Browser.SessionStore's.
}
unit Browser.ViewSupport;

{$mode objfpc}
{$H+}

interface

uses
  WebView.Control,
  Browser.SessionStore;

{ The view's entries, oldest first, and which one is shown. }
function ViewHistory(View: TWebView; out Index: Integer): TSessionEntries;
{ Goes Offset entries back (negative) or forward. }
procedure GoToViewHistory(View: TWebView; Offset: Integer);
{ A new view shows Entries[Index], the others its back and forward. }
procedure RestoreViewHistory(View: TWebView; const Entries: TSessionEntries; Index: Integer);
{ Every match of Needle highlighted ('' none). }
procedure SetViewFindHighlight(View: TWebView; const Needle: string; MatchCase: Boolean);

implementation

uses
  SysUtils,
  WebView.Types;

function ViewHistory(View: TWebView; out Index: Integer): TSessionEntries;
var
  Entries: TWebHistoryList;
  Item: Integer;
begin
  Result := nil;
  Entries := View.HistoryEntries;
  Index := View.HistoryIndex;
  SetLength(Result, Length(Entries));
  for Item := 0 to High(Entries) do
  begin
    Result[Item].Url := Entries[Item].Url;
    Result[Item].Title := Entries[Item].Title;
  end;
  if Length(Result) = 0 then
  begin
    { A view that has not told its entries yet: what it shows. }
    if View.Url <> '' then
    begin
      SetLength(Result, 1);
      Result[0].Url := View.Url;
      Result[0].Title := View.Title;
    end;
    Index := 0;
  end;
  if Index > High(Result) then
    Index := High(Result);
  if Index < 0 then
    Index := 0;
end;

procedure GoToViewHistory(View: TWebView; Offset: Integer);
begin
  if Offset <> 0 then
    View.GoToHistoryOffset(Offset);
end;

procedure RestoreViewHistory(View: TWebView; const Entries: TSessionEntries; Index: Integer);
var
  List: TWebHistoryList;
  Item: Integer;
begin
  List := nil;
  SetLength(List, Length(Entries));
  for Item := 0 to High(Entries) do
  begin
    List[Item].Url := Entries[Item].Url;
    List[Item].Title := Entries[Item].Title;
  end;
  if Length(List) > 0 then
    View.RestoreHistory(List, Index);
end;

procedure SetViewFindHighlight(View: TWebView; const Needle: string; MatchCase: Boolean);
begin
  View.SetFindHighlight(Needle, MatchCase);
end;

end.
