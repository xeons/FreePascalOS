{
  realpath - print the resolved path

  realpath [-emqsz] [--relative-to=DIR] [--relative-base=DIR] FILE...

  By default every component but the last must exist. -s keeps symbolic
  links unresolved (only "." and ".." are handled).
}
program realpath;

{$mode objfpc}
{$pointermath on}

uses
  Runtime.Text,
  Sys.Format,
  Sys.Memory,
  Sys.Streams,
  Sys.Text,
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

{ True if Path is Base or below it. }
function IsBelow(Path, Base: PChar): Boolean;
var
  Length: PtrUInt;
begin
  if TextIsEqual(Base, '/') then
    Exit(True);
  Length := TextLength(Base);
  Result := TextStartsWith(Path, Base) and ((Path[Length] = '/') or (Path[Length] = #0));
end;

{ Path relative to Directory (both absolute and canonical). }
function MakeRelative(Path, Directory: PChar): PChar;
var
  Builder: TTextBuilder;
  Common: PtrUInt;
  Index: PtrUInt;
  Remaining: PChar;
begin
  { Longest common prefix that ends at a component boundary. }
  Common := 0;
  Index := 0;
  while (Path[Index] <> #0) and (Path[Index] = Directory[Index]) do
  begin
    Inc(Index);
    if ((Path[Index] = '/') or (Path[Index] = #0)) and ((Directory[Index] = '/') or (Directory[Index] = #0)) then
      Common := Index;
  end;
  if TextIsEqual(Directory, '/') then
    Common := 0;
  BeginText(Builder);
  { One ".." per remaining component of Directory. }
  Remaining := Directory + Common;
  while Remaining^ <> #0 do
  begin
    if Remaining^ = '/' then
    begin
      Inc(Remaining);
      if Remaining^ = #0 then
        Break;
      if Builder.Length > 0 then
        AppendCharacter(Builder, '/');
      AppendText(Builder, '..');
    end;
    while (Remaining^ <> '/') and (Remaining^ <> #0) do
      Inc(Remaining);
  end;
  Remaining := Path + Common;
  if Remaining^ = '/' then
    Inc(Remaining);
  if Remaining^ <> #0 then
  begin
    if Builder.Length > 0 then
      AppendCharacter(Builder, '/');
    AppendText(Builder, Remaining);
  end;
  if Builder.Length = 0 then
    AppendCharacter(Builder, '.');
  Result := FinishText(Builder);
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  Mode: TCanonicalMode;
  Quiet: Boolean;
  FollowLinks: Boolean;
  LineEnd: Char;
  RelativeTo: PChar;
  RelativeBase: PChar;
  Index: Integer;
  Canonical: PChar;
  Relative: PChar;
  Error: LongInt;
  ExitStatus: LongInt;
begin
  Mode := CanonicalAllButLast;
  Quiet := False;
  FollowLinks := True;
  LineEnd := #10;
  RelativeTo := nil;
  RelativeBase := nil;
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
      OptionRelativeTo: RelativeTo := Value;
      OptionRelativeBase: RelativeBase := Value;
      OptionStrip: FollowLinks := False;
      OptionZero: LineEnd := #0;
    end;
  if Parser.OperandCount = 0 then
    FailWithUsageHint('missing operand', []);

  if RelativeTo <> nil then
  begin
    Error := CanonicalizePath(RelativeTo, Mode, FollowLinks, Canonical);
    if Error <> 0 then
      FailWithError(1, Error, '%s', [ArgumentText(RelativeTo)]);
    RelativeTo := Canonical;
  end;
  if RelativeBase <> nil then
  begin
    Error := CanonicalizePath(RelativeBase, Mode, FollowLinks, Canonical);
    if Error <> 0 then
      FailWithError(1, Error, '%s', [ArgumentText(RelativeBase)]);
    RelativeBase := Canonical;
    if RelativeTo = nil then
      RelativeTo := RelativeBase;
  end;

  ExitStatus := 0;
  for Index := 0 to Parser.OperandCount - 1 do
  begin
    Error := CanonicalizePath(Parser.Operands[Index], Mode, FollowLinks, Canonical);
    if Error <> 0 then
    begin
      if not Quiet then
        ReportError(Error, '%s', [ArgumentText(Parser.Operands[Index])]);
      ExitStatus := 1;
      Continue;
    end;
    if (RelativeTo <> nil) and ((RelativeBase = nil) or (IsBelow(Canonical, RelativeBase) and
       IsBelow(RelativeTo, RelativeBase))) then
    begin
      Relative := MakeRelative(Canonical, RelativeTo);
      WriteText(StandardOutput, Relative);
      FreeMemory(Relative);
    end
    else
      WriteText(StandardOutput, Canonical);
    WriteCharacter(StandardOutput, LineEnd);
    FreeMemory(Canonical);
  end;
  Halt(ExitStatus);
end.
