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
  Loading shared libraries at run time.

  LoadLibrary maps a shared library (and the libraries it needs) into the
  program; a bare name such as 'libplugin.so' is looked for in /lib.
  FindSymbol returns the address of an exported symbol, which can be cast
  to a procedure or function type of the right signature.

  Free Pascal exports routines under mangled names; a library meant for
  run time loading should give its entry points plain names with
  "public name '...'" or "alias".

  Before LoadLibrary returns, the initializers of the libraries it
  brought in have run (and their finalizers run when the program ends);
  their thread-local storage and threadvars work in every thread, those
  that ran before included. A Free Pascal library compiled from a
  "library" source with the startup unit si_dll gets its units
  initialized (userland/lib/dynpascal shows how it is built).
}
unit Sys.Libraries;

{$mode objfpc}

interface

{ Returns a library handle (zero or more) or a negative error code. }
function LoadLibrary(Name: PChar): Int64;
{ Returns nil if the symbol does not exist. }
function FindSymbol(LibraryHandle: Int64; Name: PChar): Pointer;

implementation

uses
  Sys.Kernel;

function LoadLibrary(Name: PChar): Int64;
begin
  Result := SysLoadLibraryHandle(Name);
end;

function FindSymbol(LibraryHandle: Int64; Name: PChar): Pointer;
var
  Address: Int64;
begin
  Address := KernelFindSymbol(LibraryHandle, Name);
  if Address <= 0 then
    Result := nil
  else
    Result := Pointer(Address);
end;

end.
