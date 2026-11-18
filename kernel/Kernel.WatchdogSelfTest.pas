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
  Self test of the hardware watchdog (Io.Watchdog), when the machine has
  one (under test, QEMU's i6300esb): it is armed for 4 seconds and left
  to the kernel timer that pets it for more than twice that. Had the
  petting failed, the watchdog would have reset the machine (and the
  test run, started with -no-reboot, would have ended); the test also
  checks that the timer did pet it. Afterwards the watchdog is put back
  as it was (armed by the watchdog option, or not).

  It takes 9 seconds, so it runs only under test (the test-exit option)
  or when the option watchdogtest asks for it, not at every boot of a
  Raspberry Pi.
}
unit Kernel.WatchdogSelfTest;

{$mode objfpc}

interface

procedure RunWatchdogSelfTest;

implementation

uses
  Kernel.Options,
  Kernel.Scheduler,
  Kernel.SelfTest,
  Io.Watchdog;

const
  TestTimeoutSeconds = 4;
  { More than twice the timeout. }
  TestWaitMilliseconds = 9000;
  { The timer pets every third of the timeout: six times in the wait. }
  MinimumPets = 4;

procedure RunWatchdogSelfTest;
var
  WasArmed: Boolean;
  PreviousTimeout: LongWord;
begin
  if not WatchdogIsPresent or
     not (KernelOptionIsSet(OptionTestExit) or KernelOptionIsSet('watchdogtest')) then
    Exit;
  WasArmed := WatchdogIsArmed;
  PreviousTimeout := WatchdogTimeoutSeconds;
  Check(ArmWatchdog(TestTimeoutSeconds), 'watchdog: it cannot be armed');
  SleepMilliseconds(TestWaitMilliseconds);
  Check(WatchdogIsArmed, 'watchdog: it is no longer armed');
  Check(WatchdogPetCount >= MinimumPets, 'watchdog: the kernel timer did not pet it');
  if WasArmed then
    ArmWatchdog(PreviousTimeout)
  else
    DisarmWatchdog;
  ReportPassed('watchdog');
end;

end.
