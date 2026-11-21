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
  Transfer rates: how fast a long operation (a copy) is going, how long
  it has left, and the words for both.

  A TTransferRateMeter is given timestamped samples of the bytes done
  (AddSample). Its rate (BytesPerSecond) is the plain average over the
  first few seconds, then a smoothed one: each new interval's speed
  pulls the rate towards it by a share that grows with the interval's
  length (an exponential moving average with a time constant of
  RateTimeConstant milliseconds), so a stall or a burst moves the
  estimate without making it jump. SkipGap leaves the time until the
  next sample out (a pause). It also keeps the rate at each share of
  the whole done (History, at most HistoryBuckets points), what a
  progress dialog's graph draws.

  The texts: sizes ("34 MB", "1.5 KB"), speeds ("12.3 MB/s"), the time
  left ("About 2 minutes") and the items left ("5 (34 MB)").

  Plain logic, no system calls: it builds for the host too and is
  checked there (tools/NavigationControlsTest).
}
unit Controls.TransferRates;

{$mode objfpc}
{$H+}

interface

const
  { Milliseconds: the smoothing's time constant, and how long the rate
    must have been measured before a time left is given. }
  RateTimeConstant = 2500;
  MinimumEstimateTime = 1000;
  { The most points History keeps (one per share of the whole). }
  HistoryBuckets = 200;

type
  { The rate when Fraction (0 to 1) of the whole was done. }
  TRatePoint = record
    Fraction: Double;
    BytesPerSecond: Double;
  end;

  TTransferRateMeter = class
  private
    FHasBaseline: Boolean;
    FSkipGap: Boolean;
    FLastTime: QWord;
    FLastBytes: QWord;
    FMeasuredTime: QWord;
    FMeasuredBytes: QWord;
    FRate: Double;
    FPeakRate: Double;
    FHistory: array of TRatePoint;
    FHistoryCount: LongInt;
    procedure Remember(BytesDone, BytesTotal: QWord);
    function GetHistory(Index: LongInt): TRatePoint;
  public
    procedure Reset;
    { BytesDone of BytesTotal at TimeMilliseconds (any clock that only
      goes forward). }
    procedure AddSample(TimeMilliseconds, BytesDone, BytesTotal: QWord);
    { The time from the last sample to the next one does not count. }
    procedure SkipGap;
    { Whether the rate has been measured long enough to estimate from. }
    function HasEstimate: Boolean;
    { Seconds until BytesTotal at the rate now; -1 if not known yet. }
    function SecondsRemaining(BytesDone, BytesTotal: QWord): Double;
    property BytesPerSecond: Double read FRate;
    { The highest rate so far. }
    property PeakRate: Double read FPeakRate;
    property HistoryCount: LongInt read FHistoryCount;
    property History[Index: LongInt]: TRatePoint read GetHistory;
  end;

{ "512 bytes", "1.5 KB", "34 MB", "2.1 GB" (1024 to a kilobyte). }
function TransferSizeText(Bytes: QWord): string;
{ "12.3 MB/s"; "0 bytes/s" for none. }
function TransferSpeedText(BytesPerSecond: Double): string;
{ "About 5 seconds", "About 1 minute", "About 2 hours and 5 minutes";
  "Calculating..." for a negative (unknown) time. }
function TimeRemainingText(Seconds: Double): string;
{ "5 (34 MB)". }
function ItemsRemainingText(Items: LongInt; Bytes: QWord): string;
{ Done of Total as a whole percentage, 0 to 100 (0 for no total). }
function PercentDone(Done, Total: QWord): LongInt;

implementation

uses
  SysUtils;

procedure TTransferRateMeter.Reset;
begin
  FHasBaseline := False;
  FSkipGap := False;
  FLastTime := 0;
  FLastBytes := 0;
  FMeasuredTime := 0;
  FMeasuredBytes := 0;
  FRate := 0;
  FPeakRate := 0;
  FHistory := nil;
  FHistoryCount := 0;
end;

procedure TTransferRateMeter.SkipGap;
begin
  FSkipGap := True;
end;

function TTransferRateMeter.HasEstimate: Boolean;
begin
  Result := FMeasuredTime >= MinimumEstimateTime;
end;

function TTransferRateMeter.GetHistory(Index: LongInt): TRatePoint;
begin
  Result := FHistory[Index];
end;

{ The rate at this share of the whole: a new point once the share moves
  into the next bucket, else the bucket's point takes the newer rate. }
procedure TTransferRateMeter.Remember(BytesDone, BytesTotal: QWord);
var
  Fraction: Double;
  Bucket: LongInt;
  LastBucket: LongInt;
begin
  if BytesTotal = 0 then
    Exit;
  Fraction := BytesDone / BytesTotal;
  if Fraction > 1 then
    Fraction := 1;
  Bucket := Trunc(Fraction * HistoryBuckets);
  if FHistoryCount > 0 then
  begin
    LastBucket := Trunc(FHistory[FHistoryCount - 1].Fraction * HistoryBuckets);
    if Bucket <= LastBucket then
    begin
      FHistory[FHistoryCount - 1].BytesPerSecond := FRate;
      Exit;
    end;
  end;
  if FHistoryCount >= Length(FHistory) then
    SetLength(FHistory, FHistoryCount + 16);
  FHistory[FHistoryCount].Fraction := Fraction;
  FHistory[FHistoryCount].BytesPerSecond := FRate;
  Inc(FHistoryCount);
end;

procedure TTransferRateMeter.AddSample(TimeMilliseconds, BytesDone, BytesTotal: QWord);
var
  Elapsed: QWord;
  Moved: QWord;
  IntervalRate: Double;
  Share: Double;
begin
  { The first sample, one after a gap, or one going backwards (the
    operation started again): only where to measure from. }
  if not FHasBaseline or FSkipGap or (TimeMilliseconds < FLastTime) or (BytesDone < FLastBytes) then
  begin
    FHasBaseline := True;
    FSkipGap := False;
    FLastTime := TimeMilliseconds;
    FLastBytes := BytesDone;
    Exit;
  end;
  Elapsed := TimeMilliseconds - FLastTime;
  { No time has passed: the bytes count in the next interval. }
  if Elapsed = 0 then
    Exit;
  Moved := BytesDone - FLastBytes;
  IntervalRate := Moved * 1000.0 / Elapsed;
  FMeasuredTime := FMeasuredTime + Elapsed;
  FMeasuredBytes := FMeasuredBytes + Moved;
  if FMeasuredTime <= RateTimeConstant then
    { Early on, the plain average is the steadiest. }
    FRate := FMeasuredBytes * 1000.0 / FMeasuredTime
  else
  begin
    Share := 1 - Exp(-(Elapsed / RateTimeConstant));
    FRate := FRate + Share * (IntervalRate - FRate);
  end;
  if FRate < 0 then
    FRate := 0;
  if FRate > FPeakRate then
    FPeakRate := FRate;
  FLastTime := TimeMilliseconds;
  FLastBytes := BytesDone;
  Remember(BytesDone, BytesTotal);
end;

function TTransferRateMeter.SecondsRemaining(BytesDone, BytesTotal: QWord): Double;
begin
  if BytesDone >= BytesTotal then
    Exit(0);
  if not HasEstimate or (FRate <= 0) then
    Exit(-1);
  Result := (BytesTotal - BytesDone) / FRate;
end;

function PointFormat: TFormatSettings;
begin
  Result := DefaultFormatSettings;
  Result.DecimalSeparator := '.';
  Result.ThousandSeparator := ',';
end;

{ Value of a unit: one decimal below Limit, whole above. }
function UnitAmountText(Value: Double; Limit: Double): string;
begin
  if Value < Limit then
    Result := FormatFloat('0.0', Value, PointFormat)
  else
    Result := FormatFloat('0', Value, PointFormat);
end;

const
  UnitNames: array[1..5] of string = ('KB', 'MB', 'GB', 'TB', 'PB');

{ Bytes in the largest unit that keeps it at least 1 (Level 0: bytes). }
procedure SplitUnits(Bytes: Double; out Value: Double; out Level: LongInt);
begin
  Value := Bytes;
  Level := 0;
  while (Value >= 1024) and (Level < High(UnitNames)) do
  begin
    Value := Value / 1024;
    Inc(Level);
  end;
end;

function TransferSizeText(Bytes: QWord): string;
var
  Value: Double;
  Level: LongInt;
begin
  if Bytes = 1 then
    Exit('1 byte');
  SplitUnits(Bytes, Value, Level);
  if Level = 0 then
    Exit(IntToStr(Bytes) + ' bytes');
  Result := UnitAmountText(Value, 10) + ' ' + UnitNames[Level];
end;

function TransferSpeedText(BytesPerSecond: Double): string;
var
  Value: Double;
  Level: LongInt;
begin
  if BytesPerSecond < 0 then
    BytesPerSecond := 0;
  SplitUnits(BytesPerSecond, Value, Level);
  if Level = 0 then
    Exit(IntToStr(Round(BytesPerSecond)) + ' bytes/s');
  Result := UnitAmountText(Value, 100) + ' ' + UnitNames[Level] + '/s';
end;

function CountedText(Count: Int64; const Singular: string): string;
begin
  Result := IntToStr(Count) + ' ' + Singular;
  if Count <> 1 then
    Result := Result + 's';
end;

function TimeRemainingText(Seconds: Double): string;
var
  Whole: Int64;
  Hours: Int64;
  Minutes: Int64;
begin
  if Seconds < 0 then
    Exit('Calculating...');
  if Seconds <= 10 then
  begin
    Whole := Round(Seconds);
    if Whole < 1 then
      Whole := 1;
    Exit('About ' + CountedText(Whole, 'second'));
  end;
  if Seconds < 57.5 then
    { To the nearest five seconds. }
    Exit('About ' + CountedText(Round(Seconds / 5) * 5, 'second'));
  if Seconds < 90 then
    Exit('About 1 minute');
  if Seconds < 3570 then
    Exit('About ' + CountedText(Round(Seconds / 60), 'minute'));
  Hours := Trunc(Seconds / 3600);
  Minutes := Round((Seconds - Hours * 3600) / 60);
  if Minutes >= 60 then
  begin
    Inc(Hours);
    Minutes := 0;
  end;
  Result := 'About ' + CountedText(Hours, 'hour');
  if Minutes > 0 then
    Result := Result + ' and ' + CountedText(Minutes, 'minute');
end;

function ItemsRemainingText(Items: LongInt; Bytes: QWord): string;
begin
  Result := IntToStr(Items) + ' (' + TransferSizeText(Bytes) + ')';
end;

function PercentDone(Done, Total: QWord): LongInt;
begin
  if Total = 0 then
    Exit(0);
  if Done >= Total then
    Exit(100);
  if Total > High(QWord) div 100 then
    Result := Done div (Total div 100)
  else
    Result := Done * 100 div Total;
  if Result > 100 then
    Result := 100;
end;

end.
