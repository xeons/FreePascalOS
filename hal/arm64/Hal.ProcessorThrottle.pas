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
  Slowing a processor down when it is too hot, on AArch64: there is no
  architectural way; the Raspberry Pi lowers its clock through the
  firmware instead (Power.BoardClocks).
}
unit Hal.ProcessorThrottle;

{$mode objfpc}

interface

function ProcessorThrottleIsAvailable: Boolean;
procedure SetThisProcessorThrottle(Percent: LongWord);

implementation

function ProcessorThrottleIsAvailable: Boolean;
begin
  Result := False;
end;

procedure SetThisProcessorThrottle(Percent: LongWord);
begin
end;

end.
