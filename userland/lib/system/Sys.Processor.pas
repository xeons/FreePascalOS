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
  What the processor is: its maker and its model name, as the processor
  itself tells them. The kernel asks it (CPUID on x86-64, MIDR_EL1 on
  AArch64, which user mode cannot read) through
  CallGetProcessorDescription.
}
unit Sys.Processor;

{$mode objfpc}{$H+}

interface

{ "GenuineIntel", "AuthenticAMD", "ARM", ... }
function ProcessorVendor: string;
{ The model name, such as "AMD Ryzen 7 5800X 8-Core Processor" or
  "Cortex-A72", with the spaces some processors pad it with taken away;
  empty if the processor does not tell it. }
function ProcessorModel: string;

implementation

uses
  Abi.SystemCalls;

function QueryDescription(out Description: TAbiProcessorDescription): Boolean;
begin
  FillChar(Description, SizeOf(Description), 0);
  Result := SystemCall(CallGetProcessorDescription, QWord(@Description), 0, 0, 0, 0, 0) >= 0;
end;

function ProcessorVendor: string;
var
  Description: TAbiProcessorDescription;
begin
  Result := '';
  if QueryDescription(Description) then
    Result := string(PChar(@Description.Vendor[0]));
end;

{ Text without the spaces before and after it, and with runs of spaces
  inside it made one. }
function TidySpaces(const Text: string): string;
var
  Character: Char;
begin
  Result := '';
  for Character in Text do
    if (Character <> ' ') or ((Result <> '') and (Result[Length(Result)] <> ' ')) then
      Result := Result + Character;
  if (Result <> '') and (Result[Length(Result)] = ' ') then
    SetLength(Result, Length(Result) - 1);
end;

function ProcessorModel: string;
var
  Description: TAbiProcessorDescription;
begin
  Result := '';
  if QueryDescription(Description) then
    Result := TidySpaces(string(PChar(@Description.Model[0])));
end;

end.
