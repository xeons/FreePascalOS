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
  A small repeatable random number generator for the damage tests: the
  same seed gives the same damage on every run and every host. Each part
  of the test keeps its own state, so adding checks to one part does not
  change what another damages.
}
unit ImageTest.Random;

{$mode objfpc}
{$H+}

interface

type
  TTestRandom = record
    State: LongWord;
  end;

function NewTestRandom(Seed: LongWord): TTestRandom;

{ A number from 0 to Limit - 1. }
function NextRandom(var Random: TTestRandom; Limit: LongWord): LongWord;

implementation

function NewTestRandom(Seed: LongWord): TTestRandom;
begin
  Result.State := Seed;
end;

function NextRandom(var Random: TTestRandom; Limit: LongWord): LongWord;
var
  Product: QWord;
begin
  { A linear congruential step modulo 2^32, worked in 64 bits so that the
    overflow is explicit rather than a range error. }
  Product := QWord(Random.State) * 1103515245 + 12345;
  Random.State := LongWord(Product and $FFFFFFFF);
  Result := (Random.State shr 8) mod Limit;
end;

end.
