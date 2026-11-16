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
  wget's progress line, drawn on error output when it is a terminal and
  redrawn in place (a carriage return) at most five times a second:

    index.html      45%[=======>          ]  1.23M  456KB/s  eta 3s

  Without a known length the bar is a marker moving back and forth and
  there is no percentage or estimate. When the transfer ends the line
  is drawn a last time with the total time, and a line end follows.
  Off a terminal nothing is drawn.
}
unit Wget.Progress;

{$mode objfpc}
{$H+}

interface

type
  TProgress = record
    Enabled: Boolean;
    Name: string;
    { -1 when not known. }
    ExpectedTotal: Int64;
    { Bytes there before this transfer (-c). }
    StartingBytes: Int64;
    Received: Int64;
    StartTime: QWord;
    LastDrawTime: QWord;
    Columns: Integer;
  end;

procedure BeginProgress(out Progress: TProgress; const Name: string; ExpectedTotal, StartingBytes: Int64;
  Quiet: Boolean);
procedure AdvanceProgress(var Progress: TProgress; Count: Int64);
procedure FinishProgress(var Progress: TProgress);
{ "1.23M", "456K", "789". }
function FormatSize(Bytes: Int64): string;
{ Bytes per second as "456KB/s" or "1.23MB/s". }
function FormatSpeed(BytesPerSecond: Int64): string;

implementation

uses
  SysUtils,
  StrUtils,
  Abi.SystemCalls,
  Sys.Console,
  Sys.Streams,
  Sys.Time;

const
  RedrawInterval = 200;
  { The most of the file's name the line shows. }
  MaximumShownNameLength = 63;

procedure BeginProgress(out Progress: TProgress; const Name: string; ExpectedTotal, StartingBytes: Int64;
  Quiet: Boolean);
var
  Rows: LongInt;
  Columns: LongInt;
begin
  Progress := Default(TProgress);
  Progress.Enabled := not Quiet and IsConsole(StandardErrorHandle);
  Progress.Name := Copy(Name, 1, MaximumShownNameLength);
  Progress.ExpectedTotal := ExpectedTotal;
  Progress.StartingBytes := StartingBytes;
  Progress.StartTime := UptimeMilliseconds;
  Progress.Columns := 80;
  if Progress.Enabled then
  begin
    GetConsoleSize(StandardErrorHandle, Rows, Columns);
    if Columns >= 40 then
      Progress.Columns := Columns;
  end;
end;

{ Two decimal digits after the point for values below 100. }
function FormatScaled(Value: Int64; Divisor: Int64; const UnitText: string): string;
var
  Whole, Fraction: Int64;
begin
  Whole := Value div Divisor;
  Fraction := ((Value mod Divisor) * 100) div Divisor;
  Result := IntToStr(Whole);
  if Whole < 100 then
    Result := Result + '.' + Format('%.2d', [Fraction]);
  Result := Result + UnitText;
end;

function FormatSize(Bytes: Int64): string;
begin
  if Bytes < 1024 then
    Result := IntToStr(Bytes)
  else if Bytes < 1024 * 1024 then
    Result := FormatScaled(Bytes, 1024, 'K')
  else if Bytes < 1024 * 1024 * 1024 then
    Result := FormatScaled(Bytes, 1024 * 1024, 'M')
  else
    Result := FormatScaled(Bytes, 1024 * 1024 * 1024, 'G');
end;

function FormatSpeed(BytesPerSecond: Int64): string;
begin
  if BytesPerSecond < 1024 * 1024 then
    Result := FormatScaled(BytesPerSecond, 1024, 'KB/s')
  else
    Result := FormatScaled(BytesPerSecond, 1024 * 1024, 'MB/s');
end;

{ The bar of a known length: Percent filled, ">" at its tip. }
function FilledBar(BarWidth: Integer; Percent: Int64): string;
var
  Filled, Index: Integer;
begin
  Result := '';
  Filled := Integer((Int64(BarWidth) * Percent) div 100);
  for Index := 1 to BarWidth do
    if Index < Filled then
      Result := Result + '='
    else if (Index = Filled) and (Percent < 100) then
      Result := Result + '>'
    else if Index <= Filled then
      Result := Result + '='
    else
      Result := Result + ' ';
end;

{ The bar of an unknown length: a three character marker moving back
  and forth. }
function MovingBar(BarWidth: Integer; Elapsed: QWord; Finished: Boolean): string;
var
  Marker, Index: Integer;
begin
  Result := '';
  Marker := Integer((Elapsed div RedrawInterval) mod QWord(2 * (BarWidth - 3)));
  if Marker > BarWidth - 3 then
    Marker := 2 * (BarWidth - 3) - Marker;
  Index := 0;
  while Index < BarWidth do
    if (Index = Marker) and not Finished then
    begin
      Result := Result + '<=>';
      Index := Index + 3;
    end
    else
    begin
      Result := Result + ' ';
      Inc(Index);
    end;
end;

procedure DrawLine(var Progress: TProgress; Finished: Boolean);
var
  Elapsed: QWord;
  Total, Done: Int64;
  Percent: Int64;
  BarWidth: Integer;
  Speed: Int64;
  Line: string;
begin
  Elapsed := UptimeMilliseconds - Progress.StartTime;
  Done := Progress.StartingBytes + Progress.Received;
  Total := Progress.ExpectedTotal;
  Line := #13 + PadRight(Progress.Name, 20);
  BarWidth := Progress.Columns - 20 - 5 - 2 - 8 - 11 - 12;
  if BarWidth < 10 then
    BarWidth := 10;
  if Total > 0 then
  begin
    Percent := (Done * 100) div Total;
    if Percent > 100 then
      Percent := 100;
    Line := Line + PadLeft(IntToStr(Percent), 3) + '%[' + FilledBar(BarWidth, Percent);
  end
  else
    Line := Line + '    [' + MovingBar(BarWidth, Elapsed, Finished);
  Line := Line + '] ' + PadLeft(FormatSize(Done), 8);
  if Elapsed > 0 then
    Speed := (Progress.Received * 1000) div Int64(Elapsed)
  else
    Speed := 0;
  Line := Line + '  ' + PadLeft(FormatSpeed(Speed), 9);
  if Finished then
    Line := Line + '    in ' + IntToStr(Elapsed div 1000) + '.' + IntToStr((Elapsed mod 1000) div 100) + 's'
  else if (Total > 0) and (Speed > 0) and (Total > Done) then
    Line := Line + '    eta ' + IntToStr((Total - Done) div Speed) + 's   '
  else
    Line := Line + '           ';
  PrintErrorString(Line);
  FlushStream(StandardError);
  Progress.LastDrawTime := UptimeMilliseconds;
end;

procedure AdvanceProgress(var Progress: TProgress; Count: Int64);
begin
  Progress.Received := Progress.Received + Count;
  if not Progress.Enabled then
    Exit;
  if UptimeMilliseconds - Progress.LastDrawTime >= RedrawInterval then
    DrawLine(Progress, False);
end;

procedure FinishProgress(var Progress: TProgress);
begin
  if not Progress.Enabled then
    Exit;
  DrawLine(Progress, True);
  PrintErrorString(#10#10);
  FlushStream(StandardError);
end;

end.
