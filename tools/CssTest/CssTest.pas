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
  Host side test of libcss (make css-test): the tokenizer, parsing and
  serialization, selectors and matching, the cascade, computed values,
  media queries, shorthands, colors, and memory and sharing on a
  synthetic page.
}
program CssTest;

{$mode objfpc}
{$H+}

uses
  SysUtils, TestChecks, CssTest.Syntax, CssTest.Selectors, CssTest.Cascade, CssTest.Memory;

begin
  RunSyntaxTests;
  RunSelectorTests;
  RunCascadeTests;
  RunMemoryTests;
  FinishChecks('CSS TEST');
end.
