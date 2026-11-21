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
  Crash reports that can be symbolized: every address of a back trace
  ("An unhandled exception occurred at $...", "Runtime error 216 at
  $...", heap check reports) is followed by the module it lies in and
  its offset there,

    An unhandled exception occurred at $0000000000412345:
    EAccessViolation: Access violation
      $0000000000412345  coretest+$12345
      $00007F0000034567  libsystem.so+$34567

  and a process that ends with an error after writing a back trace lists
  its modules on the error output as its last words:

    Modules:
      $0000000000400000-$0000000000452000 coretest
      $00007F0000000000-$00007F00000A3000 libsystem.so

  The modules come from the kernel (CallGetProcessModules), so this
  holds wherever they were loaded. scripts/symbolize.py turns such a
  report into routine names.
}

const
  CrashModuleCapacity = 64;

var
  CrashModules: array[0..CrashModuleCapacity - 1] of TAbiModuleInformation;
  BackTraceWasWritten: Boolean = False;

function FetchCrashModules: LongInt;
var
  Count: Int64;
begin
  Count := SystemCall(CallGetProcessModules, QWord(@CrashModules[0]), CrashModuleCapacity, 0, 0, 0, 0);
  if Count < 0 then
    Count := 0;
  if Count > CrashModuleCapacity then
    Count := CrashModuleCapacity;
  FetchCrashModules := LongInt(Count);
end;

function ModuleNameText(constref Module: TAbiModuleInformation): ShortString;
var
  Text: ShortString;
  Index: LongInt;
begin
  Text := '';
  Index := 0;
  while (Index < AbiModuleNameCapacity) and (Module.Name[Index] <> #0) and (Length(Text) < 200) do
  begin
    Text := Text + Module.Name[Index];
    Inc(Index);
  end;
  ModuleNameText := Text;
end;

{ Value in hexadecimal without leading zeros. }
function ShortHexText(Value: QWord): ShortString;
var
  Text: ShortString;
begin
  Text := HexStr(Value, 16);
  while (Length(Text) > 1) and (Text[1] = '0') do
    Delete(Text, 1, 1);
  ShortHexText := Text;
end;

function ModuleBackTraceStr(Addr: CodePointer): ShortString;
var
  Text: ShortString;
  Address: QWord;
  Count: LongInt;
  Index: LongInt;
begin
  BackTraceWasWritten := True;
  Address := QWord(PtrUInt(Addr));
  Text := '  $' + HexStr(Address, 16);
  Count := FetchCrashModules;
  Index := 0;
  while Index < Count do
  begin
    if (Address >= CrashModules[Index].Base) and (Address < CrashModules[Index].Limit) then
    begin
      Text := Text + '  ' + ModuleNameText(CrashModules[Index]) + '+$' +
        ShortHexText(Address - CrashModules[Index].Base);
      Break;
    end;
    Inc(Index);
  end;
  ModuleBackTraceStr := Text;
end;

procedure WriteErrorText(const Text: ShortString);
begin
  SystemCall(CallWrite, StdErrorHandle, QWord(@Text[1]), Length(Text), 0, 0, 0);
end;

{ The module list after a crash report (see above); System_exit calls
  it, when the error output has been flushed. }
procedure WriteCrashModuleList;
var
  Count: LongInt;
  Index: LongInt;
begin
  if not BackTraceWasWritten or (ExitCode = 0) then
    Exit;
  Count := FetchCrashModules;
  if Count = 0 then
    Exit;
  WriteErrorText('Modules:' + LineEnding);
  Index := 0;
  while Index < Count do
  begin
    WriteErrorText('  $' + HexStr(CrashModules[Index].Base, 16) + '-$' +
      HexStr(CrashModules[Index].Limit, 16) + ' ' + ModuleNameText(CrashModules[Index]) + LineEnding);
    Inc(Index);
  end;
end;
