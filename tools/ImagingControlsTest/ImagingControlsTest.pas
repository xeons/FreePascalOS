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
  ImagingControlsTest - checks on the host (make imaging-controls-test)
  the parts of libcontrols' picture and timing controls that need no
  window: which pixel size an image list draws from
  (Controls.ImageSizes), where a picture box puts its picture in each
  size mode (Controls.PictureGeometry), the greyed and selected looks
  (Controls.ImageEffects), when tooltips show and go
  (Controls.HintTiming, against a clock it is given) and the timers'
  queue (Controls.TimerQueue).
}
program ImagingControlsTest;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  ImagingControlsTest.Checks,
  ImagingControlsTest.Pictures,
  ImagingControlsTest.Timing;

begin
  CheckImageSizes;
  CheckPictureGeometry;
  CheckImageEffects;
  CheckHintTiming;
  CheckTimerQueue;
  FinishChecks('IMAGING CONTROLS TEST');
end.
