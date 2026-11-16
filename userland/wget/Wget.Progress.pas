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
{$pointermath on}

interface

type
  TProgress = record
    Enabled: Boolean;
    Name: array[0..63] of Char;
    { -1 when not known. }
    ExpectedTotal: Int64;
    { Bytes there before this transfer (-c). }
    StartingBytes: Int64;
    Received: Int64;
    StartTime: QWord;
    LastDrawTime: QWord;
    Columns: Integer;
  end;

procedure BeginProgress(out Progress: TProgress; Name: PChar; ExpectedTotal, StartingBytes: Int64; Quiet: Boolean);
procedure AdvanceProgress(var Progress: TProgress; Count: Int64);
procedure FinishProgress(var Progress: TProgress);
{ "1.23M", "456K", "789". }
procedure FormatSize(Bytes: Int64; Buffer: PChar);
{ Bytes per second as "456KB/s" or "1.23MB/s". }
procedure FormatSpeed(BytesPerSecond: Int64; Buffer: PChar);

implementation

uses
  Abi.SystemCalls,
  Runtime.Text,
  Sys.Console,
  Sys.Streams,
  Sys.Time;

const
  RedrawInterval = 200;

procedure CopyName(Destination: PChar; Capacity: Integer; Source: PChar);
var
  Index: Integer;
begin
  Index := 0;
  while (Source[Index] <> #0) and (Index < Capacity - 1) do
  begin
    Destination[Index] := Source[Index];
    Inc(Index);
  end;
  Destination[Index] := #0;
end;

procedure BeginProgress(out Progress: TProgress; Name: PChar; ExpectedTotal, StartingBytes: Int64; Quiet: Boolean);
var
  Rows: LongInt;
  Columns: LongInt;
begin
  FillChar(Progress, SizeOf(Progress), 0);
  Progress.Enabled := not Quiet and IsConsole(StandardErrorHandle);
  CopyName(@Progress.Name[0], SizeOf(Progress.Name), Name);
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

{ One decimal digit after the point for values below 100. }
procedure FormatScaled(Value: Int64; Divisor: Int64; UnitText: PChar; Buffer: PChar);
var
  Whole, Fraction: Int64;
  Number: TNumberText;
  Position: Integer;

  procedure Append(Text: PChar);
  var
    Index: Integer;
  begin
    Index := 0;
    while Text[Index] <> #0 do
    begin
      Buffer[Position] := Text[Index];
      Inc(Position);
      Inc(Index);
    end;
    Buffer[Position] := #0;
  end;

begin
  Position := 0;
  Buffer[0] := #0;
  Whole := Value div Divisor;
  Fraction := ((Value mod Divisor) * 100) div Divisor;
  Append(FormatDecimal(Whole, Number));
  if Whole < 100 then
  begin
    Append('.');
    if Fraction < 10 then
      Append('0');
    Append(FormatDecimal(Fraction, Number));
  end;
  Append(UnitText);
end;

procedure FormatSize(Bytes: Int64; Buffer: PChar);
var
  Number: TNumberText;
begin
  if Bytes < 1024 then
  begin
    CopyName(Buffer, 16, FormatDecimal(Bytes, Number));
    Exit;
  end;
  if Bytes < 1024 * 1024 then
    FormatScaled(Bytes, 1024, 'K', Buffer)
  else if Bytes < 1024 * 1024 * 1024 then
    FormatScaled(Bytes, 1024 * 1024, 'M', Buffer)
  else
    FormatScaled(Bytes, 1024 * 1024 * 1024, 'G', Buffer);
end;

procedure FormatSpeed(BytesPerSecond: Int64; Buffer: PChar);
begin
  if BytesPerSecond < 1024 * 1024 then
    FormatScaled(BytesPerSecond, 1024, 'KB/s', Buffer)
  else
    FormatScaled(BytesPerSecond, 1024 * 1024, 'MB/s', Buffer);
end;

procedure WritePadded(Text: PChar; Width: Integer; AlignRight: Boolean);
var
  Length: Integer;
begin
  Length := 0;
  while Text[Length] <> #0 do
    Inc(Length);
  if AlignRight then
    while Length < Width do
    begin
      WriteCharacter(StandardError, ' ');
      Inc(Length);
    end;
  WriteText(StandardError, Text);
  if not AlignRight then
    while Length < Width do
    begin
      WriteCharacter(StandardError, ' ');
      Inc(Length);
    end;
end;

procedure DrawLine(var Progress: TProgress; Finished: Boolean);
var
  Elapsed: QWord;
  Total, Done: Int64;
  Percent: Int64;
  BarWidth, Filled, Index, Marker: Integer;
  SizeText: array[0..31] of Char;
  SpeedText: array[0..31] of Char;
  Number: TNumberText;
  Speed: Int64;
  Remaining: Int64;
begin
  Elapsed := UptimeMilliseconds - Progress.StartTime;
  Done := Progress.StartingBytes + Progress.Received;
  Total := Progress.ExpectedTotal;
  WriteCharacter(StandardError, #13);
  WritePadded(@Progress.Name[0], 20, False);
  BarWidth := Progress.Columns - 20 - 5 - 2 - 8 - 11 - 12;
  if BarWidth < 10 then
    BarWidth := 10;
  if Total > 0 then
  begin
    Percent := (Done * 100) div Total;
    if Percent > 100 then
      Percent := 100;
    WritePadded(FormatDecimal(Percent, Number), 3, True);
    WriteText(StandardError, '%[');
    Filled := Integer((Int64(BarWidth) * Percent) div 100);
    for Index := 1 to BarWidth do
      if Index < Filled then
        WriteCharacter(StandardError, '=')
      else if (Index = Filled) and (Percent < 100) then
        WriteCharacter(StandardError, '>')
      else if Index <= Filled then
        WriteCharacter(StandardError, '=')
      else
        WriteCharacter(StandardError, ' ');
  end
  else
  begin
    WriteText(StandardError, '    [');
    { A three character marker moving back and forth. }
    Marker := Integer((Elapsed div RedrawInterval) mod QWord(2 * (BarWidth - 3)));
    if Marker > BarWidth - 3 then
      Marker := 2 * (BarWidth - 3) - Marker;
    Index := 0;
    while Index < BarWidth do
      if (Index = Marker) and not Finished then
      begin
        WriteText(StandardError, '<=>');
        Index := Index + 3;
      end
      else
      begin
        WriteCharacter(StandardError, ' ');
        Inc(Index);
      end;
  end;
  WriteText(StandardError, '] ');
  FormatSize(Done, @SizeText[0]);
  WritePadded(@SizeText[0], 8, True);
  if Elapsed > 0 then
    Speed := (Progress.Received * 1000) div Int64(Elapsed)
  else
    Speed := 0;
  FormatSpeed(Speed, @SpeedText[0]);
  WriteText(StandardError, '  ');
  WritePadded(@SpeedText[0], 9, True);
  if Finished then
  begin
    WriteText(StandardError, '    in ');
    WriteText(StandardError, FormatDecimal(Elapsed div 1000, Number));
    WriteText(StandardError, '.');
    WriteText(StandardError, FormatDecimal((Elapsed mod 1000) div 100, Number));
    WriteText(StandardError, 's');
  end
  else if (Total > 0) and (Speed > 0) and (Total > Done) then
  begin
    Remaining := (Total - Done) div Speed;
    WriteText(StandardError, '    eta ');
    WriteText(StandardError, FormatDecimal(Remaining, Number));
    WriteText(StandardError, 's   ');
  end
  else
    WriteText(StandardError, '           ');
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
  WriteCharacter(StandardError, #10);
  WriteCharacter(StandardError, #10);
  FlushStream(StandardError);
end;

end.
