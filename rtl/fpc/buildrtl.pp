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
  Builds the units of the user runtime library besides System and
  si_prc: compiling this unit compiles every unit it names, in
  dependency order. Its own object is not used.

  The units come from rtl/fpc (the FreePascalOS parts) and from the Free
  Pascal source tree: rtl/objpas, rtl/inc, packages/rtl-objpas,
  packages/rtl-unicode and packages/fcl-base.
}
unit buildrtl;

interface

uses
  objpas, fpintres, strings, ctypes, getopts,
  sysconst, sysutils, typinfo, math, types, rtlconsts, classes, fgl,
  unicodedata, character, charset, unicodeducet, fpwidestring,
  strutils, dateutils, varutils, variants, convutils, system.uitypes,
  contnrs, syncobjs;

implementation

end.
