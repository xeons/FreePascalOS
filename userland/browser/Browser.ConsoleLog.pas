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
  What the Error Console shows: the pages' console messages and script
  errors from every tab (their content processes send them), newest
  last, at most MaximumConsoleMessages. Each is an error, a warning or
  a message (log, info, debug), with the page it came from. Plain
  logic, checked on the host.
}
unit Browser.ConsoleLog;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes;

const
  MaximumConsoleMessages = 1000;

type
  TConsoleSeverity = (SeverityError, SeverityWarning, SeverityMessage);
  TConsoleFilter = (FilterAll, FilterErrors, FilterWarnings, FilterMessages);

  TConsoleEntry = record
    Severity: TConsoleSeverity;
    Text: string;
    Source: string;
    Time: Int64;
  end;
  TConsoleEntries = array of TConsoleEntry;

  TConsoleLog = class
  private
    FEntries: TConsoleEntries;
    FCount: Integer;
    FVersion: Int64;
    FOnChanged: TNotifyEvent;
    function GetEntry(Index: Integer): TConsoleEntry;
  public
    { Level as the page's console names it (error, warn, log, info,
      debug, exception). }
    procedure Add(const Level, Text, Source: string; Time: Int64);
    procedure Clear;
    { The entries Filter lets through holding Search (case folded). }
    function Filtered(Filter: TConsoleFilter; const Search: string): TConsoleEntries;
    property Count: Integer read FCount;
    property Entries[Index: Integer]: TConsoleEntry read GetEntry;
    { Moves with every change. }
    property Version: Int64 read FVersion;
    property OnChanged: TNotifyEvent read FOnChanged write FOnChanged;
  end;

function SeverityOfLevel(const Level: string): TConsoleSeverity;
function SeverityName(Severity: TConsoleSeverity): string;

implementation

uses
  Browser.TextFiles;

function SeverityOfLevel(const Level: string): TConsoleSeverity;
var
  Lowered: string;
begin
  Lowered := FoldCase(Level);
  if (Lowered = 'error') or (Lowered = 'exception') or (Lowered = 'assert') then
    Result := SeverityError
  else if (Lowered = 'warn') or (Lowered = 'warning') then
    Result := SeverityWarning
  else
    Result := SeverityMessage;
end;

function SeverityName(Severity: TConsoleSeverity): string;
begin
  case Severity of
    SeverityError: Result := 'Error';
    SeverityWarning: Result := 'Warning';
  else
    Result := 'Message';
  end;
end;

function TConsoleLog.GetEntry(Index: Integer): TConsoleEntry;
begin
  Result := FEntries[Index];
end;

procedure TConsoleLog.Add(const Level, Text, Source: string; Time: Int64);
var
  Dropped: Integer;
begin
  if FCount >= MaximumConsoleMessages then
  begin
    Dropped := MaximumConsoleMessages div 10;
    FEntries := Copy(FEntries, Dropped, FCount - Dropped);
    FCount := FCount - Dropped;
  end;
  if FCount >= Length(FEntries) then
    SetLength(FEntries, FCount * 2 + 16);
  FEntries[FCount].Severity := SeverityOfLevel(Level);
  FEntries[FCount].Text := Text;
  FEntries[FCount].Source := Source;
  FEntries[FCount].Time := Time;
  Inc(FCount);
  Inc(FVersion);
  if Assigned(FOnChanged) then
    FOnChanged(Self);
end;

procedure TConsoleLog.Clear;
begin
  FEntries := nil;
  FCount := 0;
  Inc(FVersion);
  if Assigned(FOnChanged) then
    FOnChanged(Self);
end;

function TConsoleLog.Filtered(Filter: TConsoleFilter; const Search: string): TConsoleEntries;
var
  Index, Kept: Integer;
  Wanted: Boolean;
  Needle: string;
begin
  Result := nil;
  SetLength(Result, FCount);
  Kept := 0;
  Needle := FoldCase(Trim(Search));
  for Index := 0 to FCount - 1 do
  begin
    case Filter of
      FilterErrors: Wanted := FEntries[Index].Severity = SeverityError;
      FilterWarnings: Wanted := FEntries[Index].Severity = SeverityWarning;
      FilterMessages: Wanted := FEntries[Index].Severity = SeverityMessage;
    else
      Wanted := True;
    end;
    if Wanted and (Needle <> '') then
      Wanted := Pos(Needle, FoldCase(FEntries[Index].Text + ' ' + FEntries[Index].Source)) > 0;
    if Wanted then
    begin
      Result[Kept] := FEntries[Index];
      Inc(Kept);
    end;
  end;
  SetLength(Result, Kept);
end;

end.
