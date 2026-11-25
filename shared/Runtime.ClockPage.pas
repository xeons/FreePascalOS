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
  The clock page's arithmetic as a unit, for the kernel and the host
  test (the System unit includes ClockPageMath.inc itself).
}
unit Runtime.ClockPage;

{$mode objfpc}

interface

uses
  Abi.SystemCalls;

function ClockPageUptimeAt(const Page: TAbiClockPage; Counter: QWord): QWord;
function ClockSlewProgress(Total: Int64; Start, Now: QWord; PartsPerMillion: QWord): Int64;
function ClockPageWallClockAt(const Page: TAbiClockPage; Uptime: QWord): Int64;

implementation

{$I ClockPageMath.inc}

end.
