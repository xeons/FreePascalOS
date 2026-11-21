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
  NavigationControlsTest: the plain logic behind the tab strip, the
  breadcrumb bar, the command bar and the progress dialog, on the host.

    NavigationControlsTest

  Transfer rates and their texts (Controls.TransferRates: the smoothed
  rate, pauses, the time left, sizes, speeds, the graph's history), the
  tab strip's widths and dragging (Controls.TabStripLayout), which
  breadcrumbs fit and child paths (Controls.BreadcrumbLayout), and the
  command bar's overflow (Controls.CommandLayout). Every check prints a
  line; the exit code is 1 if any failed.

  This is a host tool, built with the normal Free Pascal runtime library.
}
program NavigationControlsTest;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Controls.TransferRates,
  Controls.TabStripLayout,
  Controls.BreadcrumbLayout,
  Controls.CommandLayout;

var
  Failures: Integer = 0;
  Checks: Integer = 0;

procedure Check(const Name: string; Passed: Boolean);
begin
  Inc(Checks);
  if Passed then
    WriteLn('[navigation] pass: ', Name)
  else
  begin
    WriteLn('[navigation] FAIL: ', Name);
    Inc(Failures);
  end;
end;

procedure CheckText(const Name, Actual, Expected: string);
begin
  if Actual <> Expected then
    WriteLn('[navigation]   got "', Actual, '", expected "', Expected, '"');
  Check(Name, Actual = Expected);
end;

function Near(Actual, Expected, Tolerance: Double): Boolean;
begin
  Result := Abs(Actual - Expected) <= Tolerance;
end;

procedure TestSizeTexts;
begin
  CheckText('0 bytes', TransferSizeText(0), '0 bytes');
  CheckText('1 byte', TransferSizeText(1), '1 byte');
  CheckText('1023 bytes', TransferSizeText(1023), '1023 bytes');
  CheckText('1 KB with a decimal', TransferSizeText(1024), '1.0 KB');
  CheckText('1.5 KB', TransferSizeText(1536), '1.5 KB');
  CheckText('34 MB, whole above ten', TransferSizeText(34 * 1024 * 1024), '34 MB');
  CheckText('2.1 GB', TransferSizeText(QWord(2254857830)), '2.1 GB');
  CheckText('speed in MB/s', TransferSpeedText(12.3 * 1024 * 1024), '12.3 MB/s');
  CheckText('speed in bytes/s', TransferSpeedText(500), '500 bytes/s');
  CheckText('speed whole above a hundred', TransferSpeedText(150.4 * 1024), '150 KB/s');
  CheckText('items left', ItemsRemainingText(5, 34 * 1024 * 1024), '5 (34 MB)');
end;

procedure TestTimeTexts;
begin
  CheckText('unknown', TimeRemainingText(-1), 'Calculating...');
  CheckText('under a second is one', TimeRemainingText(0.2), 'About 1 second');
  CheckText('seven seconds', TimeRemainingText(7.2), 'About 7 seconds');
  CheckText('to five seconds', TimeRemainingText(33), 'About 35 seconds');
  CheckText('a minute', TimeRemainingText(70), 'About 1 minute');
  CheckText('two minutes', TimeRemainingText(125), 'About 2 minutes');
  CheckText('an hour', TimeRemainingText(3600), 'About 1 hour');
  CheckText('hours and minutes', TimeRemainingText(2 * 3600 + 5 * 60), 'About 2 hours and 5 minutes');
  CheckText('minutes rounding into the hour', TimeRemainingText(3599 + 3600), 'About 2 hours');
end;

procedure TestPercent;
begin
  Check('no total is 0 %', PercentDone(5, 0) = 0);
  Check('a third', PercentDone(1, 3) = 33);
  Check('done is 100 %', PercentDone(10, 10) = 100);
  Check('past the total stays 100 %', PercentDone(11, 10) = 100);
  Check('huge totals do not overflow', PercentDone(High(QWord) div 2, High(QWord)) = 50);
end;

procedure TestSteadyRate;
var
  Meter: TTransferRateMeter;
  Time: QWord;
begin
  Meter := TTransferRateMeter.Create;
  try
    Meter.AddSample(1000, 0, 10000000);
    Check('one sample: no rate yet', Meter.BytesPerSecond = 0);
    Check('one sample: no estimate', Meter.SecondsRemaining(0, 10000000) < 0);
    Time := 1000;
    while Time < 6000 do
    begin
      Time := Time + 100;
      Meter.AddSample(Time, (Time - 1000) * 1000, 10000000);
    end;
    { A steady million bytes a second. }
    Check('steady rate measured', Near(Meter.BytesPerSecond, 1000000, 1));
    Check('estimate after a second', Meter.HasEstimate);
    Check('time left at the steady rate', Near(Meter.SecondsRemaining(5000000, 10000000), 5, 0.01));
    Check('nothing left is no time', Meter.SecondsRemaining(10000000, 10000000) = 0);
    Check('history kept per share', (Meter.HistoryCount > 10) and (Meter.HistoryCount <= HistoryBuckets));
    Check('history rises in share', Meter.History[Meter.HistoryCount - 1].Fraction > Meter.History[0].Fraction);
  finally
    Meter.Free;
  end;
end;

procedure TestSmoothing;
var
  Meter: TTransferRateMeter;
  Time: QWord;
  Bytes: QWord;
  BeforeDrop: Double;
begin
  Meter := TTransferRateMeter.Create;
  try
    Time := 0;
    Bytes := 0;
    Meter.AddSample(Time, Bytes, 0);
    while Time < 10000 do
    begin
      Time := Time + 250;
      Bytes := Bytes + 250000;
      Meter.AddSample(Time, Bytes, 0);
    end;
    BeforeDrop := Meter.BytesPerSecond;
    { The speed halves: the rate moves towards it without jumping. }
    Time := Time + 250;
    Bytes := Bytes + 125000;
    Meter.AddSample(Time, Bytes, 0);
    Check('a slower interval lowers the rate', Meter.BytesPerSecond < BeforeDrop);
    Check('but not all the way at once', Meter.BytesPerSecond > 750000);
    while Time < 30000 do
    begin
      Time := Time + 250;
      Bytes := Bytes + 125000;
      Meter.AddSample(Time, Bytes, 0);
    end;
    Check('the rate settles on the new speed', Near(Meter.BytesPerSecond, 500000, 5000));
    Check('the peak is remembered', Near(Meter.PeakRate, 1000000, 1));
    Check('no total keeps no history', Meter.HistoryCount = 0);
    { A pause: the minute without bytes does not count. }
    Meter.SkipGap;
    Meter.AddSample(Time + 60000, Bytes, 0);
    Meter.AddSample(Time + 60250, Bytes + 125000, 0);
    Check('a skipped gap keeps the rate', Near(Meter.BytesPerSecond, 500000, 5000));
    Meter.Reset;
    Check('reset forgets the rate', (Meter.BytesPerSecond = 0) and not Meter.HasEstimate);
  finally
    Meter.Free;
  end;
end;

procedure TestTabStripLayout;
begin
  Check('one tab takes the maximum', StripTabWidth(1, 1000, 100, 240, 40) = 240);
  Check('tabs share the room', StripTabWidth(5, 1000, 100, 240, 40) = 200);
  Check('the minimum while it fits', StripTabWidth(10, 1000, 100, 240, 40) = 100);
  Check('below the minimum when it does not', StripTabWidth(20, 1000, 100, 240, 40) = 50);
  Check('never below the smallest', StripTabWidth(100, 1000, 100, 240, 40) = 40);
  Check('the tab at a point', StripTabAt(250, 10, 100, 5) = 2);
  Check('left of the tabs is none', StripTabAt(5, 10, 100, 5) = -1);
  Check('right of the tabs is none', StripTabAt(600, 10, 100, 5) = -1);
  Check('a dragged tab follows the pointer', DraggedTabLeft(300, 40, 10, 100, 5) = 260);
  Check('a dragged tab stays in the row (left)', DraggedTabLeft(20, 40, 10, 100, 5) = 10);
  Check('a dragged tab stays in the row (right)', DraggedTabLeft(900, 40, 10, 100, 5) = 410);
  Check('drop where its middle is', StripDropIndex(260, 10, 100, 5) = 3);
  Check('drop before the middle stays', StripDropIndex(150, 10, 100, 5) = 1);
  Check('drop clamped to the last', StripDropIndex(900, 10, 100, 5) = 4);
  Check('inside the strip is not out', not IsDraggedOut(10, 30, 20));
  Check('far below is out', IsDraggedOut(60, 30, 20));
  Check('far above is out', IsDraggedOut(-25, 30, 20));
end;

procedure TestBreadcrumbLayout;
begin
  Check('all fit', FirstShownSegment([50, 60, 70], 200, 20) = 0);
  Check('the first collapses', FirstShownSegment([50, 60, 70], 170, 20) = 1);
  Check('only the last fits', FirstShownSegment([50, 60, 70], 100, 20) = 2);
  Check('the last shows even cut short', FirstShownSegment([50, 60, 70], 10, 20) = 2);
  Check('no segments', FirstShownSegment([], 100, 20) = 0);
  CheckText('a child of the root', JoinChildPath('/', 'home'), '/home');
  CheckText('a child of a folder', JoinChildPath('/home', 'user'), '/home/user');
  CheckText('a folder ending in a slash', JoinChildPath('/home/', 'user'), '/home/user');
end;

function Slot(Width: LongInt; AlignRight: Boolean = False; IsSeparator: Boolean = False): TCommandSlot;
begin
  Result.Width := Width;
  Result.AlignRight := AlignRight;
  Result.IsSeparator := IsSeparator;
end;

procedure TestCommandLayout;
var
  Slots: TCommandSlots;
  Placements: TCommandPlacements;
  OverflowLeft: LongInt;
begin
  Slots := nil;
  SetLength(Slots, 5);
  Slots[0] := Slot(60);
  Slots[1] := Slot(50);
  Slots[2] := Slot(8, False, True);
  Slots[3] := Slot(70);
  Slots[4] := Slot(80, True);
  ArrangeCommands(Slots, 1000, 30, 2, Placements, OverflowLeft);
  Check('all shown when they fit', Placements[0].Shown and Placements[1].Shown and Placements[2].Shown and
    Placements[3].Shown and Placements[4].Shown);
  Check('left ones in a row', (Placements[0].Left = 0) and (Placements[1].Left = 62) and (Placements[3].Left = 124));
  Check('the overflow button after them', OverflowLeft = 196);
  Check('the right one at the far end', Placements[4].Left = 920);
  { 60+2 + 50+2 + 8+2 + 30 + 80+2 = 236: the last left one goes, and the
    separator left at the end with it. }
  ArrangeCommands(Slots, 230, 30, 2, Placements, OverflowLeft);
  Check('the last left command overflows', not Placements[3].Shown);
  Check('a separator at the end goes too', not Placements[2].Shown);
  Check('the rest stay', Placements[0].Shown and Placements[1].Shown and Placements[4].Shown);
  Check('the overflow button follows what is shown', OverflowLeft = 114);
  ArrangeCommands(Slots, 120, 30, 2, Placements, OverflowLeft);
  Check('the right one goes last', not Placements[0].Shown and not Placements[1].Shown and Placements[4].Shown);
  ArrangeCommands(Slots, 40, 30, 2, Placements, OverflowLeft);
  Check('with no room at all only the overflow button stays', not Placements[4].Shown and (OverflowLeft = 0));
end;

begin
  TestSizeTexts;
  TestTimeTexts;
  TestPercent;
  TestSteadyRate;
  TestSmoothing;
  TestTabStripLayout;
  TestBreadcrumbLayout;
  TestCommandLayout;
  WriteLn('[navigation] ', Checks - Failures, ' of ', Checks, ' checks passed');
  if Failures > 0 then
    Halt(1);
end.
