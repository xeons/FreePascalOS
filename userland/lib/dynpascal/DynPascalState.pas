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
  The state of libdynpascal.so (the library dynlibtest loads at run
  time): threadvars and a unit initialization of a Free Pascal library
  that the program was not linked with. The initialization runs once,
  in the thread that loads the library, and marks that thread's
  threadvar; every other thread's copy starts at zero. A resource string
  (and a constant initialized with it) shows that translations made with
  SetResourceStrings reach a library's units (latelibtest).
}
unit DynPascalState;

{$mode objfpc}

interface

const
  LoaderMark = 77;

resourcestring
  SDynPascalGreeting = 'hello from libdynpascal';

const
  { Set from the resource string; updated with it on a translation. }
  GreetingCopy: AnsiString = SDynPascalGreeting;

function DynPascalCounterAddress: PInt64;
function DynPascalMark: LongInt;
function DynPascalInitializations: LongInt;
procedure DynPascalSetMark(Value: LongInt);
{ The resource string and the constant made from it, as they are now. }
function DynPascalGreeting: PChar;
function DynPascalGreetingCopy: PChar;

implementation

uses
  SysUtils;

threadvar
  Counter: Int64;
  Mark: LongInt;

var
  Initializations: LongInt = 0;

function DynPascalCounterAddress: PInt64;
begin
  Result := @Counter;
end;

function DynPascalMark: LongInt;
begin
  Result := Mark;
end;

procedure DynPascalSetMark(Value: LongInt);
begin
  Mark := Value;
end;

function DynPascalGreeting: PChar;
begin
  Result := PChar(SDynPascalGreeting);
end;

function DynPascalGreetingCopy: PChar;
begin
  Result := PChar(GreetingCopy);
end;

function DynPascalInitializations: LongInt;
begin
  Result := Initializations;
end;

initialization
  Inc(Initializations);
  Mark := LoaderMark;
  { SysUtils is the program's (in libsystem), started long before. }
  if IntToStr(Initializations) <> '1' then
    Mark := -1;

finalization
  WriteLn('dynpascal: unit finalized');
  Flush(Output);
end.
