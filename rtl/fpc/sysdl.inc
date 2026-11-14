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
  Loading libraries at run time (LoadLibrary, GetProcAddress) through the
  kernel's loader, which maps the library and the ones it needs into the
  process and binds their symbols. Libraries stay loaded until the
  process ends; ordinals do not exist in ELF.
}

var
  LastLoadError: LongInt = 0;

function SysLoadLibraryA(const Name: RawByteString): TLibHandle;
var
  CallResult: Int64;
begin
  CallResult := SystemCall(CallLoadLibrary, QWord(PChar(Name)), 0, 0, 0, 0, 0);
  if CallResult < 0 then
  begin
    LastLoadError := LongInt(-CallResult);
    SysLoadLibraryA := NilHandle;
  end
  else
  begin
    LastLoadError := 0;
    SysLoadLibraryA := TLibHandle(CallResult);
  end;
end;

function SysLoadLibraryU(const Name: UnicodeString): TLibHandle;
begin
  SysLoadLibraryU := SysLoadLibraryA(ToSingleByteFileSystemEncodedFileName(Name));
end;

function SysGetProcAddress(Lib: TLibHandle; const ProcName: AnsiString): Pointer;
var
  CallResult: Int64;
begin
  CallResult := SystemCall(CallFindSymbol, QWord(Lib), QWord(PChar(ProcName)), 0, 0, 0, 0);
  if CallResult <= 0 then
    SysGetProcAddress := nil
  else
    SysGetProcAddress := Pointer(CallResult);
end;

function SysGetProcAddressOrdinal(Lib: TLibHandle; Ordinal: TOrdinalEntry): Pointer;
begin
  SysGetProcAddressOrdinal := nil;
end;

function SysUnloadLibrary(Lib: TLibHandle): Boolean;
begin
  SysUnloadLibrary := Lib <> NilHandle;
end;

function SysGetLoadErrorStr: String;
begin
  if LastLoadError = 0 then
    SysGetLoadErrorStr := ''
  else
  begin
    Str(LastLoadError, SysGetLoadErrorStr);
    SysGetLoadErrorStr := 'error ' + SysGetLoadErrorStr;
  end;
end;

const
  SystemDynLibsManager: TDynLibsManager = (
    LoadLibraryU: @SysLoadLibraryU;
    LoadLibraryA: @SysLoadLibraryA;
    GetProcAddress: @SysGetProcAddress;
    GetProcAddressOrdinal: @SysGetProcAddressOrdinal;
    UnloadLibrary: @SysUnloadLibrary;
    GetLoadErrorStr: @SysGetLoadErrorStr;
  );

procedure InitSystemDynLibs;
begin
  SetDynLibsManager(SystemDynLibsManager);
end;
