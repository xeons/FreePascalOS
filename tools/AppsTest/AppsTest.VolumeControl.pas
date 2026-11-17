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
  AppsTest: the volume control's peak levels and meters.
}
unit AppsTest.VolumeControl;

{$mode objfpc}
{$H+}

interface

procedure TestVolumeControl;

implementation

uses
  AppsTest.Checks,
  VolumeControl.Levels;

procedure TestVolumeControl;
var
  Stereo: array[0..7] of SmallInt = (100, -2000, -300, 50, 32767, 0, -5, -32768);
  Mono: array[0..3] of SmallInt = (10, -400, 20, 30);
  Peak: TStereoPeak;
begin
  Peak := PeakOfSamples(Stereo, 4, 2);
  CheckNumber('the left peak', Peak.Left, 32767);
  CheckNumber('the right peak (the most negative sample, kept within full scale)', Peak.Right, 32767);
  Peak := PeakOfSamples(Stereo, 2, 2);
  CheckNumber('fewer frames: left', Peak.Left, 300);
  CheckNumber('fewer frames: right', Peak.Right, 2000);
  Peak := PeakOfSamples(Mono, 4, 1);
  Check('mono is both sides', (Peak.Left = 400) and (Peak.Right = 400));
  Peak := PeakOfSamples(Stereo, 100, 2);
  CheckNumber('a count beyond the samples is cut to them', Peak.Left, 32767);
  CheckNumber('silence reads 0', MeterPercent(0), 0);
  CheckNumber('full scale reads 100', MeterPercent(FullScale), 100);
  CheckNumber('-6 dB (half scale) reads 90', MeterPercent(FullScale div 2), 90);
  CheckNumber('-20 dB reads 67', MeterPercent(FullScale div 10), 67);
  CheckNumber('below -60 dB reads 0', MeterPercent(10), 0);
  CheckNumber('a higher reading shows at once', FallenMeter(20, 80, 100), 80);
  CheckNumber('a lower reading falls slowly (24 dB/s, 100 ms: 4 points)', FallenMeter(80, 0, 100), 76);
  CheckNumber('a fall stops at the reading', FallenMeter(80, 78, 1000), 78);
  CheckNumber('a second of silence falls 40 points', FallenMeter(100, 0, 1000), 60);
end;

end.
