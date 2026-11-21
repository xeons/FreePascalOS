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
  Startup code of Free Pascal libraries (compiled from a "library"
  source; the compiler expects a unit of this name for Linux style
  libraries), for libraries a program loads with LoadLibrary.

  The compiler puts the library's unit tables into the library itself.
  Linked with "ld -shared -init FPC_SHARED_LIB_START -fini
  FPC_LIB_EXIT", the library's DT_INIT hands them to System in
  libsystem (SysRegisterLibrary: the threadvars and initialization of
  the units the program does not have already, rtl/fpc/syslibraries.inc)
  and its DT_FINI finalizes those units again when the program ends. The
  library's own begin ... end block is not run.
}
unit si_dll;

{$mode objfpc}

interface

implementation

var
  InitFinalTable: record end; external name 'INITFINAL';
  ThreadvarTablesTable: record end; external name 'FPC_THREADVARTABLES';
  Registration: Pointer = nil;

procedure LibraryStart; cdecl; [public, alias: 'FPC_SHARED_LIB_START'];
begin
  Registration := SysRegisterLibrary(@InitFinalTable, @ThreadvarTablesTable);
end;

procedure LibraryExit; cdecl; [public, alias: 'FPC_LIB_EXIT'];
begin
  SysUnregisterLibrary(Registration);
  Registration := nil;
end;

end.
