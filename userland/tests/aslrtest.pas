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
  aslrtest - address space layout randomization

    aslrtest --print           prints where this run's parts are
    aslrtest --compare A B     compares two such printouts

  --print writes one line per part: the program's code, a library's code
  (libsystem), the main stack, a heap block and a thread's stack. Two
  runs of the same program are compared with --compare: with
  randomization (the default) every part must be somewhere else in the
  second run (libraries keep the place they were given first, shared by
  every process, so they are not compared - unless the kernel option
  aslr=process gives each process places of its own for them too); with
  the kernel option aslr=off everywhere the same (a
  heap block and stacks may move by a little there: only their page
  must match). It prints which and exits with 1 if the expectation was
  not met.
}
program aslrtest;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Classes,
  Sys.Streams,
  Sys.Threads,
  Sys.KernelOptions;

const
  PartCount = 5;
  PartNames: array[0..PartCount - 1] of string = ('code', 'library', 'stack', 'heap', 'thread');
  LibraryPart = 1;
  { Parts that are pages of their own with aslr=off: compared to the
    page, as what lies in them may shift a little. }
  PageMask = not QWord($FFF);

var
  ThreadStackAddress: QWord;

function RecordThreadStack(Argument: Pointer): LongInt;
var
  Local: LongInt;
begin
  Local := 0;
  ThreadStackAddress := QWord(PtrUInt(@Local));
  Result := Local;
end;

procedure PrintParts;
var
  Local: LongInt;
  Block: Pointer;
  Handle: Int64;
  ExitCode: LongInt;
begin
  Local := 0;
  Block := GetMem(64);
  Handle := CreateThread(@RecordThreadStack, nil);
  if Handle >= 0 then
  begin
    WaitForThread(Handle, -1, ExitCode);
    CloseThreadHandle(Handle);
  end;
  PrintStringLine('code=' + IntToHex(QWord(PtrUInt(@PrintParts)), 16));
  PrintStringLine('library=' + IntToHex(QWord(PtrUInt(@YieldThread)), 16));
  PrintStringLine('stack=' + IntToHex(QWord(PtrUInt(@Local)), 16));
  PrintStringLine('heap=' + IntToHex(QWord(PtrUInt(Block)), 16));
  PrintStringLine('thread=' + IntToHex(ThreadStackAddress, 16));
  FreeMem(Block);
  Inc(Local);
end;

function ReadParts(const FileName: string; out Parts: array of QWord): Boolean;
var
  Lines: TStringList;
  Index: Integer;
  Text: string;
begin
  Result := False;
  Lines := TStringList.Create;
  try
    try
      Lines.LoadFromFile(FileName);
    except
      on EStreamError do
        Exit;
    end;
    for Index := 0 to PartCount - 1 do
    begin
      Text := Lines.Values[PartNames[Index]];
      if Text = '' then
        Exit;
      Parts[Index] := QWord(StrToInt64('$' + Text));
    end;
    Result := True;
  finally
    Lines.Free;
  end;
end;

function Compare(const FirstName, SecondName: string): Integer;
var
  First: array[0..PartCount - 1] of QWord;
  Second: array[0..PartCount - 1] of QWord;
  Randomized: Boolean;
  Value: string;
  Index: Integer;
  Same: string;
  Moved: string;
  LibrariesPerProcess: Boolean;
begin
  if not ReadParts(FirstName, First) or not ReadParts(SecondName, Second) then
  begin
    PrintStringLine('aslrtest: cannot read the printouts');
    Exit(2);
  end;
  Randomized := not (GetKernelOption('aslr', Value) and (Value = 'off'));
  LibrariesPerProcess := GetKernelOption('aslr', Value) and (Value = 'process');
  Same := '';
  Moved := '';
  for Index := 0 to PartCount - 1 do
    if Randomized and (Index = LibraryPart) and not LibrariesPerProcess then
      Continue
    else if (First[Index] = Second[Index]) or (not Randomized and (Index >= 2) and
       ((First[Index] and PageMask) = (Second[Index] and PageMask))) then
      Same := Same + ' ' + PartNames[Index]
    else
      Moved := Moved + ' ' + PartNames[Index];

  if Randomized then
  begin
    if (Same = '') and LibrariesPerProcess then
    begin
      PrintStringLine('aslrtest: code, library, stack, heap and thread stack addresses differ');
      Exit(0);
    end;
    if Same = '' then
    begin
      PrintStringLine('aslrtest: code, stack, heap and thread stack addresses differ');
      Exit(0);
    end;
    PrintStringLine('aslrtest: FAIL: the same in both runs:' + Same);
    Exit(1);
  end;
  if Moved = '' then
  begin
    PrintStringLine('aslrtest: aslr=off, the addresses are the same');
    Exit(0);
  end;
  PrintStringLine('aslrtest: FAIL: moved with aslr=off:' + Moved);
  Result := 1;
end;

begin
  if (ParamCount = 1) and (ParamStr(1) = '--print') then
    PrintParts
  else if (ParamCount = 3) and (ParamStr(1) = '--compare') then
    ExitCode := Compare(ParamStr(2), ParamStr(3))
  else
  begin
    PrintStringLine('Usage: aslrtest --print | --compare FILE FILE');
    ExitCode := 2;
  end;
  FlushStandardStreams;
end.
