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
  AppsTest: the plain logic behind the calculator, the image viewer and
  the volume control, on the host.

    AppsTest

  The calculator's numbers (Calculator.Numbers: shown to 15 digits, read
  back, integers in bases and words), its arithmetic
  (Calculator.MathFunctions: errors, exact quarter turns, no noise),
  expressions (Calculator.Expressions: precedence, left to right,
  parentheses, functions, integers) and keys (Calculator.Engine); the
  image viewer's zoom and pan arithmetic and turning
  (ImageViewer.ViewGeometry, ImageViewer.Orientations) and finding the
  next image in a folder (ImageViewer.FolderImages); the volume
  control's peak levels (VolumeControl.Levels). Every check prints a
  line; the exit code is 1 if any failed.

  This is a host tool, built with the normal Free Pascal runtime library.
}
program AppsTest;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  AppsTest.Checks,
  AppsTest.Calculator,
  AppsTest.ImageViewer,
  AppsTest.VolumeControl;

begin
  TestCalculator;
  TestImageViewer;
  TestVolumeControl;
  WriteLn('[apps] ', Passed, ' passed, ', Failed, ' failed');
  if Failed > 0 then
    Halt(1);
end.
