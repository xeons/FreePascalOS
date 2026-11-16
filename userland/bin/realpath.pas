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
  realpath - print the resolved path

  realpath [-emqsz] [--relative-to=DIR] [--relative-base=DIR] FILE...

  By default every component but the last must exist. -s keeps symbolic
  links unresolved (only "." and ".." are handled).
}
program realpath;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  StrUtils,
  Sys.Format,
  Sys.Memory,
  Sys.Streams,
  Util.Messages,
  Util.Options,
  Util.Paths;

const
  Usage: PChar = 'Usage: realpath [OPTION]... FILE...'#10 +
    'Print the resolved absolute file name;'#10 +
    'all but the last component must exist'#10#10 +
    '  -e, --canonicalize-existing  all components of the path must exist'#10 +
    '  -m, --canonicalize-missing   no path components need exist or be a directory'#10 +
    '  -q, --quiet                  suppress most error messages'#10 +
    '      --relative-to=DIR        print the resolved path relative to DIR'#10 +
    '      --relative-base=DIR      print absolute paths unless paths below DIR'#10 +
    '  -s, --strip, --no-symlinks   don''t expand symlinks'#10 +
    '  -z, --zero                   end each output line with NUL, not newline'#10;

  OptionExisting = 1;
  OptionMissing = 2;
  OptionQuiet = 3;
  OptionRelativeTo = 4;
  OptionRelativeBase = 5;
  OptionStrip = 6;
  OptionZero = 7;

var
  Mode: TCanonicalMode;
  FollowLinks: Boolean;

{ The character at the 0-based Index, #0 past the end. }
function CharacterAt(const Text: string; Index: Integer): Char;
begin
  if Index < Length(Text) then
    Result := Text[Index + 1]
  else
    Result := #0;
end;

function IsComponentEnd(Character: Char): Boolean;
begin
  Result := (Character = '/') or (Character = #0);
end;

{ True if Path is Base or below it. }
function IsBelow(const Path, Base: string): Boolean;
begin
  if Base = '/' then
    Exit(True);
  Result := StartsStr(Base, Path) and IsComponentEnd(CharacterAt(Path, Length(Base)));
end;

{ Path relative to Directory (both absolute and canonical). }
function MakeRelative(const Path, Directory: string): string;
var
  Common: Integer;
  Index: Integer;
  Remaining: string;
begin
  { Longest common prefix that ends at a component boundary. }
  Common := 0;
  Index := 0;
  while (Index < Length(Path)) and (CharacterAt(Path, Index) = CharacterAt(Directory, Index)) do
  begin
    Inc(Index);
    if IsComponentEnd(CharacterAt(Path, Index)) and IsComponentEnd(CharacterAt(Directory, Index)) then
      Common := Index;
  end;
  if Directory = '/' then
    Common := 0;
  Result := '';
  { One ".." per remaining component of Directory. }
  Index := Common;
  while Index < Length(Directory) do
  begin
    if CharacterAt(Directory, Index) = '/' then
    begin
      Inc(Index);
      if Index >= Length(Directory) then
        Break;
      if Result <> '' then
        Result := Result + '/';
      Result := Result + '..';
    end;
    while not IsComponentEnd(CharacterAt(Directory, Index)) do
      Inc(Index);
  end;
  Remaining := Copy(Path, Common + 1, MaxInt);
  if StartsStr('/', Remaining) then
    Delete(Remaining, 1, 1);
  if Remaining <> '' then
  begin
    if Result <> '' then
      Result := Result + '/';
    Result := Result + Remaining;
  end;
  if Result = '' then
    Result := '.';
end;

{ CanonicalizePath for strings. }
function Canonicalize(const Path: string; out Canonical: string): LongInt;
var
  CanonicalText: PChar;
begin
  Canonical := '';
  Result := CanonicalizePath(PChar(Path), Mode, FollowLinks, CanonicalText);
  if Result <> 0 then
    Exit;
  Canonical := CanonicalText;
  FreeMemory(CanonicalText);
end;

{ The canonical form of a --relative-to or --relative-base directory. }
function CanonicalDirectory(const Path: string): string;
var
  Error: LongInt;
begin
  Error := Canonicalize(Path, Result);
  if Error <> 0 then
    FailWithError(1, Error, '%s', [ArgumentText(PChar(Path))]);
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  Quiet: Boolean;
  LineEnd: Char;
  HasRelativeTo: Boolean;
  HasRelativeBase: Boolean;
  RelativeTo: string;
  RelativeBase: string;
  Index: Integer;
  Canonical: string;
  Error: LongInt;
  ExitStatus: LongInt;
begin
  Mode := CanonicalAllButLast;
  Quiet := False;
  FollowLinks := True;
  LineEnd := #10;
  HasRelativeTo := False;
  HasRelativeBase := False;
  BeginOptions(Parser, [
    OptionDefinition('e', 'canonicalize-existing', False, OptionExisting),
    OptionDefinition('m', 'canonicalize-missing', False, OptionMissing),
    OptionDefinition('q', 'quiet', False, OptionQuiet),
    OptionDefinition(#0, 'relative-to', True, OptionRelativeTo),
    OptionDefinition(#0, 'relative-base', True, OptionRelativeBase),
    OptionDefinition('s', 'strip', False, OptionStrip),
    OptionDefinition(#0, 'no-symlinks', False, OptionStrip),
    OptionDefinition('z', 'zero', False, OptionZero)], Usage);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionExisting: Mode := CanonicalExisting;
      OptionMissing: Mode := CanonicalMissingAllowed;
      OptionQuiet: Quiet := True;
      OptionRelativeTo:
        begin
          RelativeTo := Value;
          HasRelativeTo := True;
        end;
      OptionRelativeBase:
        begin
          RelativeBase := Value;
          HasRelativeBase := True;
        end;
      OptionStrip: FollowLinks := False;
      OptionZero: LineEnd := #0;
    end;
  if Parser.OperandCount = 0 then
    FailWithUsageHint('missing operand', []);

  if HasRelativeTo then
    RelativeTo := CanonicalDirectory(RelativeTo);
  if HasRelativeBase then
  begin
    RelativeBase := CanonicalDirectory(RelativeBase);
    if not HasRelativeTo then
    begin
      RelativeTo := RelativeBase;
      HasRelativeTo := True;
    end;
  end;

  ExitStatus := 0;
  for Index := 0 to Parser.OperandCount - 1 do
  begin
    Error := Canonicalize(Parser.Operands[Index], Canonical);
    if Error <> 0 then
    begin
      if not Quiet then
        ReportError(Error, '%s', [ArgumentText(Parser.Operands[Index])]);
      ExitStatus := 1;
      Continue;
    end;
    if HasRelativeTo and (not HasRelativeBase or (IsBelow(Canonical, RelativeBase) and
       IsBelow(RelativeTo, RelativeBase))) then
      WriteText(StandardOutput, PChar(MakeRelative(Canonical, RelativeTo)))
    else
      WriteText(StandardOutput, PChar(Canonical));
    WriteCharacter(StandardOutput, LineEnd);
  end;
  Halt(ExitStatus);
end.
