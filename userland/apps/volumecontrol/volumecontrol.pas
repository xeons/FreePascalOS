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
  volumecontrol - the sound outputs' volumes

  volumecontrol [-c]

  A mixer window with a row for every sound output (HD Audio, AC'97,
  USB audio): a volume slider, Mute and a peak meter for each side
  (from the output's monitor input, so it moves while sound plays); the
  default output (where programs play that name none) is chosen in a
  list at the top. Changes apply at once and are kept for the next boot
  by the system settings service; changes made elsewhere show within a
  second. Sound Settings opens the Control Panel's Sound page. With -c,
  a compact window with the default output alone and a button to the
  whole mixer (the desktop's volume pop-up opens the mixer too).

  Prints what happens, a line each:

    outputs N                 how many outputs there are
    output N KIND volume V muted on|off default yes|no
                              each of them (numbered from 0)
    volume N V, mute N on|off the user changed output N
    default N                 output N chosen as the default
    kept N V                  the change kept for the next boot
    started COMMAND, exit

  The units are in userland/apps/volumecontrol: VolumeControl.Levels (peaks
  and the meters' scale), VolumeControl.PeakMonitor (the monitor input),
  VolumeControl.OutputRow, VolumeControl.MainWindow,
  VolumeControl.Settings, VolumeControl.Launching and
  VolumeControl.Output.
}
program VolumeControl;

{$mode objfpc}
{$H+}

uses
  Windowing.Windows,
  VolumeControl.MainWindow;

var
  Window: TVolumeControlWindow;
begin
  Window := TVolumeControlWindow.Create((ParamCount >= 1) and (ParamStr(1) = '-c'));
  Window.Show;
  RunMessageLoop;
end.
