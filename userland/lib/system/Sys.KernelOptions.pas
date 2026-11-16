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
  The options the system was started with (the kernel's command line,
  from options.txt on the boot volume): space separated words, flags
  ("kshell") or name=value pairs ("mode=text"). The service manager
  reads its boot mode here, login and the session manager the user to
  log in automatically.
}
unit Sys.KernelOptions;

{$mode objfpc}{$H+}

interface

const
  KernelOptionsCapacity = 512;

{ True if the flag Name (or a name=value pair of that name) is given. }
function KernelOptionIsSet(const Name: string): Boolean;
{ The value of the name=value option Name; False (Value empty) if the
  option is not given. }
function GetKernelOption(const Name: string; out Value: string): Boolean;

implementation

uses
  Sys.Kernel;

{ The line, read afresh: it is short, and asked for rarely. }
function ReadOptions: string;
var
  Line: array[0..KernelOptionsCapacity - 1] of Char;
begin
  if KernelGetKernelOptions(@Line[0], KernelOptionsCapacity) < 0 then
    Exit('');
  Line[KernelOptionsCapacity - 1] := #0;
  Result := PChar(@Line[0]);
end;

{ The word of the options named Name ("name" or "name=value"); False if
  there is none. }
function FindWord(const Name: string; out Word: string): Boolean;
var
  Line: string;
  Start: Integer;
  Finish: Integer;
begin
  Line := ReadOptions;
  Start := 1;
  while Start <= Length(Line) do
  begin
    while (Start <= Length(Line)) and (Line[Start] = ' ') do
      Inc(Start);
    Finish := Start;
    while (Finish <= Length(Line)) and (Line[Finish] <> ' ') do
      Inc(Finish);
    Word := Copy(Line, Start, Finish - Start);
    if (Word <> '') and ((Word = Name) or (Copy(Word, 1, Length(Name) + 1) = Name + '=')) then
      Exit(True);
    Start := Finish;
  end;
  Word := '';
  Result := False;
end;

function KernelOptionIsSet(const Name: string): Boolean;
var
  Word: string;
begin
  Result := FindWord(Name, Word);
end;

function GetKernelOption(const Name: string; out Value: string): Boolean;
var
  Word: string;
begin
  Value := '';
  Result := FindWord(Name, Word) and (Length(Word) > Length(Name));
  if Result then
    Value := Copy(Word, Length(Name) + 2, MaxInt);
end;

end.
