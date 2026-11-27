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
  The session: the open windows with their tabs (each tab's back and
  forward entries and which is shown, its zoom), the recently closed
  tabs and windows, and whether the browser was still running when it
  was written (so a session found "running" at start means it crashed,
  and is offered back).

  Kept in session.txt in the profile, written a few seconds after every
  change and at the end. Lines, fields tab-separated:

    #session 1
    state     running | ended
    window    left top width height selected-tab
    tab       entry-index zoom-percent
    entry     url title
    closedtab time window-index position     (its tab and entry lines follow)
    closedwindow time                        (its tab lines follow)

  A tab belongs to the window, closed tab or closed window line above
  it; an entry to the tab above it.

  Plain logic (the RTL only), checked on the host.
}
unit Browser.SessionStore;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes;

const
  MaximumClosedTabs = 10;
  MaximumClosedWindows = 3;
  MaximumSessionEntries = 50;

type
  TSessionEntry = record
    Url: string;
    Title: string;
  end;
  TSessionEntries = array of TSessionEntry;

  TSessionTab = record
    Entries: TSessionEntries;
    { The entry shown. }
    Index: Integer;
    ZoomPercent: Integer;
  end;
  TSessionTabs = array of TSessionTab;

  TSessionWindow = record
    Left, Top, Width, Height: LongInt;
    Tabs: TSessionTabs;
    Selected: Integer;
    { Unix time it was closed (closed windows only). }
    ClosedAt: Int64;
  end;
  TSessionWindows = array of TSessionWindow;

  TClosedTab = record
    Tab: TSessionTab;
    ClosedAt: Int64;
    WindowIndex: Integer;
    Position: Integer;
  end;
  TClosedTabs = array of TClosedTab;

  TSession = record
    Running: Boolean;
    Windows: TSessionWindows;
    ClosedTabs: TClosedTabs;
    ClosedWindows: TSessionWindows;
  end;

function SessionToText(constref Session: TSession): string;
{ False if Text is not a session (an empty session results). }
function TextToSession(const Text: string; out Session: TSession): Boolean;
function LoadSession(const Path: string; out Session: TSession): Boolean;
function SaveSession(constref Session: TSession; const Path: string): Boolean;

{ The tab's shown entry (an empty one if it has none). }
function CurrentEntry(constref Tab: TSessionTab): TSessionEntry;
{ Puts Tab first among the closed tabs (newest first, at most
  MaximumClosedTabs); a blank tab is not kept. }
procedure RememberClosedTab(var Session: TSession; constref Tab: TSessionTab; WindowIndex, Position: Integer;
  ClosedAt: Int64);
{ Takes closed tab Index out (False if there is none). }
function TakeClosedTab(var Session: TSession; Index: Integer; out Closed: TClosedTab): Boolean;
procedure RememberClosedWindow(var Session: TSession; constref Window: TSessionWindow; ClosedAt: Int64);
function TakeClosedWindow(var Session: TSession; Index: Integer; out Window: TSessionWindow): Boolean;
{ Whether a tab shows only a blank or start page (not worth restoring
  or remembering). }
function IsBlankTab(constref Tab: TSessionTab): Boolean;

implementation

uses
  Browser.TextFiles;

const
  FormatHeader = '#session 1';

function CurrentEntry(constref Tab: TSessionTab): TSessionEntry;
begin
  if (Tab.Index >= 0) and (Tab.Index < Length(Tab.Entries)) then
    Result := Tab.Entries[Tab.Index]
  else
  begin
    Result.Url := '';
    Result.Title := '';
  end;
end;

function IsBlankTab(constref Tab: TSessionTab): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(Tab.Entries) do
    if (Tab.Entries[Index].Url <> '') and (Tab.Entries[Index].Url <> 'about:blank') and
       (Tab.Entries[Index].Url <> 'about:home') then
      Exit(False);
  Result := True;
end;

procedure AddTabLines(constref Tab: TSessionTab; Lines: TStringList);
var
  Index, First: Integer;
begin
  { At most the last MaximumSessionEntries entries are kept. }
  First := 0;
  if Length(Tab.Entries) > MaximumSessionEntries then
    First := Length(Tab.Entries) - MaximumSessionEntries;
  Lines.Add(JoinFields(['tab', IntToStr(Tab.Index - First), IntToStr(Tab.ZoomPercent)]));
  for Index := First to High(Tab.Entries) do
    Lines.Add(JoinFields(['entry', Tab.Entries[Index].Url, Tab.Entries[Index].Title]));
end;

procedure AddWindowTabs(constref Window: TSessionWindow; Lines: TStringList);
var
  Index: Integer;
begin
  for Index := 0 to High(Window.Tabs) do
    AddTabLines(Window.Tabs[Index], Lines);
end;

function SessionToText(constref Session: TSession): string;
var
  Lines: TStringList;
  Index: Integer;
  Window: TSessionWindow;
begin
  Lines := TStringList.Create;
  try
    Lines.Add(FormatHeader);
    if Session.Running then
      Lines.Add(JoinFields(['state', 'running']))
    else
      Lines.Add(JoinFields(['state', 'ended']));
    for Index := 0 to High(Session.Windows) do
    begin
      Window := Session.Windows[Index];
      Lines.Add(JoinFields(['window', IntToStr(Window.Left), IntToStr(Window.Top), IntToStr(Window.Width),
        IntToStr(Window.Height), IntToStr(Window.Selected)]));
      AddWindowTabs(Window, Lines);
    end;
    for Index := 0 to High(Session.ClosedTabs) do
    begin
      Lines.Add(JoinFields(['closedtab', IntToStr(Session.ClosedTabs[Index].ClosedAt),
        IntToStr(Session.ClosedTabs[Index].WindowIndex), IntToStr(Session.ClosedTabs[Index].Position)]));
      AddTabLines(Session.ClosedTabs[Index].Tab, Lines);
    end;
    for Index := 0 to High(Session.ClosedWindows) do
    begin
      Window := Session.ClosedWindows[Index];
      Lines.Add(JoinFields(['closedwindow', IntToStr(Window.ClosedAt), IntToStr(Window.Left), IntToStr(Window.Top),
        IntToStr(Window.Width), IntToStr(Window.Height), IntToStr(Window.Selected)]));
      AddWindowTabs(Window, Lines);
    end;
    Result := Lines.Text;
  finally
    Lines.Free;
  end;
end;

type
  { What the tab lines being read belong to. }
  TTabOwner = (OwnerNone, OwnerWindow, OwnerClosedTab, OwnerClosedWindow);

  TSessionReader = record
    Session: TSession;
    Owner: TTabOwner;
    { The tab the entry lines go to (nil: none). }
    Tab: ^TSessionTab;
  end;

function NewTabIn(var Tabs: TSessionTabs): Pointer;
begin
  SetLength(Tabs, Length(Tabs) + 1);
  Tabs[High(Tabs)].Entries := nil;
  Tabs[High(Tabs)].Index := 0;
  Tabs[High(Tabs)].ZoomPercent := 100;
  Result := @Tabs[High(Tabs)];
end;

procedure ReadWindowFields(const Fields: TStringArray; First: Integer; var Window: TSessionWindow);
begin
  Window.Left := StrToIntDef(FieldAt(Fields, First), 0);
  Window.Top := StrToIntDef(FieldAt(Fields, First + 1), 0);
  Window.Width := StrToIntDef(FieldAt(Fields, First + 2), 0);
  Window.Height := StrToIntDef(FieldAt(Fields, First + 3), 0);
  Window.Selected := StrToIntDef(FieldAt(Fields, First + 4), 0);
  Window.Tabs := nil;
  Window.ClosedAt := 0;
end;

procedure ReadTabLine(var Reader: TSessionReader; const Fields: TStringArray);
var
  Tab: ^TSessionTab;
  Closed: ^TClosedTab;
begin
  Tab := nil;
  case Reader.Owner of
    OwnerWindow:
      Tab := NewTabIn(Reader.Session.Windows[High(Reader.Session.Windows)].Tabs);
    OwnerClosedWindow:
      Tab := NewTabIn(Reader.Session.ClosedWindows[High(Reader.Session.ClosedWindows)].Tabs);
    OwnerClosedTab:
      begin
        Closed := @Reader.Session.ClosedTabs[High(Reader.Session.ClosedTabs)];
        { A closed tab has one tab line. }
        if Length(Closed^.Tab.Entries) = 0 then
          Tab := @Closed^.Tab;
      end;
  end;
  Reader.Tab := Tab;
  if Tab = nil then
    Exit;
  Tab^.Index := StrToIntDef(FieldAt(Fields, 1), 0);
  Tab^.ZoomPercent := StrToIntDef(FieldAt(Fields, 2), 100);
  if (Tab^.ZoomPercent < 30) or (Tab^.ZoomPercent > 300) then
    Tab^.ZoomPercent := 100;
end;

procedure ReadEntryLine(var Reader: TSessionReader; const Fields: TStringArray);
var
  Count: Integer;
begin
  if (Reader.Tab = nil) or (FieldAt(Fields, 1) = '') then
    Exit;
  Count := Length(Reader.Tab^.Entries);
  SetLength(Reader.Tab^.Entries, Count + 1);
  Reader.Tab^.Entries[Count].Url := FieldAt(Fields, 1);
  Reader.Tab^.Entries[Count].Title := FieldAt(Fields, 2);
end;

{ Indexes within what was read, windows without tabs dropped. }
procedure Tidy(var Session: TSession);

  procedure TidyTab(var Tab: TSessionTab);
  begin
    if Tab.Index >= Length(Tab.Entries) then
      Tab.Index := High(Tab.Entries);
    if Tab.Index < 0 then
      Tab.Index := 0;
  end;

  procedure TidyWindows(var Windows: TSessionWindows);
  var
    Index, Tab, Kept: Integer;
  begin
    Kept := 0;
    for Index := 0 to High(Windows) do
    begin
      if Length(Windows[Index].Tabs) = 0 then
        Continue;
      for Tab := 0 to High(Windows[Index].Tabs) do
        TidyTab(Windows[Index].Tabs[Tab]);
      if (Windows[Index].Selected < 0) or (Windows[Index].Selected > High(Windows[Index].Tabs)) then
        Windows[Index].Selected := 0;
      Windows[Kept] := Windows[Index];
      Inc(Kept);
    end;
    SetLength(Windows, Kept);
  end;

var
  Index, Kept: Integer;
begin
  TidyWindows(Session.Windows);
  TidyWindows(Session.ClosedWindows);
  Kept := 0;
  for Index := 0 to High(Session.ClosedTabs) do
    if Length(Session.ClosedTabs[Index].Tab.Entries) > 0 then
    begin
      TidyTab(Session.ClosedTabs[Index].Tab);
      Session.ClosedTabs[Kept] := Session.ClosedTabs[Index];
      Inc(Kept);
    end;
  SetLength(Session.ClosedTabs, Kept);
end;

function TextToSession(const Text: string; out Session: TSession): Boolean;
var
  Lines: TStringList;
  Index: Integer;
  Fields: TStringArray;
  Reader: TSessionReader;
  Window: TSessionWindow;
  Closed: TClosedTab;
begin
  Reader := Default(TSessionReader);
  Reader.Owner := OwnerNone;
  Session := Default(TSession);
  Lines := TStringList.Create;
  try
    Lines.Text := Text;
    if (Lines.Count = 0) or (Lines[0] <> FormatHeader) then
      Exit(False);
    for Index := 1 to Lines.Count - 1 do
    begin
      Fields := Lines[Index].Split([#9]);
      if Length(Fields) = 0 then
        Continue;
      case Fields[0] of
        'state':
          Reader.Session.Running := FieldAt(Fields, 1) = 'running';
        'window':
          begin
            ReadWindowFields(Fields, 1, Window);
            SetLength(Reader.Session.Windows, Length(Reader.Session.Windows) + 1);
            Reader.Session.Windows[High(Reader.Session.Windows)] := Window;
            Reader.Owner := OwnerWindow;
            Reader.Tab := nil;
          end;
        'closedtab':
          begin
            Closed := Default(TClosedTab);
            Closed.ClosedAt := StrToInt64Def(FieldAt(Fields, 1), 0);
            Closed.WindowIndex := StrToIntDef(FieldAt(Fields, 2), 0);
            Closed.Position := StrToIntDef(FieldAt(Fields, 3), 0);
            Closed.Tab.ZoomPercent := 100;
            SetLength(Reader.Session.ClosedTabs, Length(Reader.Session.ClosedTabs) + 1);
            Reader.Session.ClosedTabs[High(Reader.Session.ClosedTabs)] := Closed;
            Reader.Owner := OwnerClosedTab;
            Reader.Tab := nil;
          end;
        'closedwindow':
          begin
            ReadWindowFields(Fields, 2, Window);
            Window.ClosedAt := StrToInt64Def(FieldAt(Fields, 1), 0);
            SetLength(Reader.Session.ClosedWindows, Length(Reader.Session.ClosedWindows) + 1);
            Reader.Session.ClosedWindows[High(Reader.Session.ClosedWindows)] := Window;
            Reader.Owner := OwnerClosedWindow;
            Reader.Tab := nil;
          end;
        'tab':
          ReadTabLine(Reader, Fields);
        'entry':
          ReadEntryLine(Reader, Fields);
      end;
    end;
  finally
    Lines.Free;
  end;
  Tidy(Reader.Session);
  Session := Reader.Session;
  Result := True;
end;

function LoadSession(const Path: string; out Session: TSession): Boolean;
var
  Lines: TStringList;
begin
  Lines := ReadLines(Path);
  try
    Result := TextToSession(Lines.Text, Session);
  finally
    Lines.Free;
  end;
end;

function SaveSession(constref Session: TSession; const Path: string): Boolean;
var
  Lines: TStringList;
begin
  Lines := TStringList.Create;
  try
    Lines.Text := SessionToText(Session);
    Result := WriteLines(Lines, Path);
  finally
    Lines.Free;
  end;
end;

procedure RememberClosedTab(var Session: TSession; constref Tab: TSessionTab; WindowIndex, Position: Integer;
  ClosedAt: Int64);
var
  Index, Count: Integer;
begin
  if IsBlankTab(Tab) then
    Exit;
  Count := Length(Session.ClosedTabs);
  if Count < MaximumClosedTabs then
    SetLength(Session.ClosedTabs, Count + 1)
  else
    Count := MaximumClosedTabs - 1;
  for Index := Count downto 1 do
    Session.ClosedTabs[Index] := Session.ClosedTabs[Index - 1];
  Session.ClosedTabs[0].Tab := Tab;
  Session.ClosedTabs[0].ClosedAt := ClosedAt;
  Session.ClosedTabs[0].WindowIndex := WindowIndex;
  Session.ClosedTabs[0].Position := Position;
end;

function TakeClosedTab(var Session: TSession; Index: Integer; out Closed: TClosedTab): Boolean;
var
  Place: Integer;
begin
  Closed := Default(TClosedTab);
  if (Index < 0) or (Index > High(Session.ClosedTabs)) then
    Exit(False);
  Closed := Session.ClosedTabs[Index];
  for Place := Index to High(Session.ClosedTabs) - 1 do
    Session.ClosedTabs[Place] := Session.ClosedTabs[Place + 1];
  SetLength(Session.ClosedTabs, Length(Session.ClosedTabs) - 1);
  Result := True;
end;

procedure RememberClosedWindow(var Session: TSession; constref Window: TSessionWindow; ClosedAt: Int64);
var
  Index, Count, Tab: Integer;
  AllBlank: Boolean;
begin
  AllBlank := True;
  for Tab := 0 to High(Window.Tabs) do
    if not IsBlankTab(Window.Tabs[Tab]) then
      AllBlank := False;
  if AllBlank then
    Exit;
  Count := Length(Session.ClosedWindows);
  if Count < MaximumClosedWindows then
    SetLength(Session.ClosedWindows, Count + 1)
  else
    Count := MaximumClosedWindows - 1;
  for Index := Count downto 1 do
    Session.ClosedWindows[Index] := Session.ClosedWindows[Index - 1];
  Session.ClosedWindows[0] := Window;
  Session.ClosedWindows[0].ClosedAt := ClosedAt;
end;

function TakeClosedWindow(var Session: TSession; Index: Integer; out Window: TSessionWindow): Boolean;
var
  Place: Integer;
begin
  Window := Default(TSessionWindow);
  if (Index < 0) or (Index > High(Session.ClosedWindows)) then
    Exit(False);
  Window := Session.ClosedWindows[Index];
  for Place := Index to High(Session.ClosedWindows) - 1 do
    Session.ClosedWindows[Place] := Session.ClosedWindows[Place + 1];
  SetLength(Session.ClosedWindows, Length(Session.ClosedWindows) - 1);
  Result := True;
end;

end.
