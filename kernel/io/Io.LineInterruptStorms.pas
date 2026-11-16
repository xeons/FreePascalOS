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
  Watching level triggered lines for interrupt storms.

  A level triggered line keeps firing for as long as some device holds
  it asserted. A handler that does not quiet its device (or a device no
  handler knows about) makes the line fire again the moment it returns,
  and since interrupts of one priority level are taken highest vector
  first, every lower device vector on that processor then starves. A
  line firing far more often than any device needs is reported once,
  so the cause shows in the log instead of as dead devices.
}
unit Io.LineInterruptStorms;

{$mode objfpc}

interface

type
  TLineStormWatch = record
    { Every time the line fired. }
    Fires: QWord;
    WindowStartTick: QWord;
    WindowFires: LongWord;
    StormReported: Boolean;
  end;

{ Counts one firing of Gsi (on Vector); reports a storm once. }
procedure NoteLineInterrupt(var Watch: TLineStormWatch; Gsi: LongWord; Vector: Byte);

implementation

uses
  Kernel.Clock,
  Debug.Output;

const
  { Far more than any device on a shared line needs in one second. }
  StormFiresPerSecond = 20000;

procedure ReportStorm(Gsi: LongWord; Vector: Byte; Fires: LongWord);
begin
  DebugBeginMessage;
  DebugWriteTag('interrupts');
  DebugWrite('GSI ');
  DebugWriteDecimal(Gsi);
  DebugWrite(' (vector 0x');
  DebugWriteHex(Vector, 2);
  DebugWrite(') fired ');
  DebugWriteDecimal(Fires);
  DebugWriteLine(' times in one second: an interrupt storm (a device on it is not being quieted)');
  DebugEndMessage;
end;

procedure NoteLineInterrupt(var Watch: TLineStormWatch; Gsi: LongWord; Vector: Byte);
var
  Now: QWord;
begin
  Inc(Watch.Fires);
  Now := ClockTickCount;
  if Now - Watch.WindowStartTick >= ClockTicksPerSecond then
  begin
    Watch.WindowStartTick := Now;
    Watch.WindowFires := 0;
  end;
  Inc(Watch.WindowFires);
  if (Watch.WindowFires = StormFiresPerSecond) and not Watch.StormReported then
  begin
    Watch.StormReported := True;
    ReportStorm(Gsi, Vector, Watch.WindowFires);
  end;
end;

end.
