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
