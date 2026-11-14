{
  readlink - print resolved symbolic links or canonical file names

  readlink [-fnqsvz] FILE...

  Without -f prints the target of each symbolic link. With -f prints the
  canonical absolute name, following every link.
}
program readlink;

{$mode objfpc}
{$pointermath on}

uses
  Abi.SystemCalls,
  Runtime.Memory,
  Runtime.Text,
  Sys.Files,
  Sys.Format,
  Sys.Memory,
  Sys.Streams,
  Sys.Text,
  Util.Messages,
  Util.Options,
  Util.Paths;

const
  Usage: PChar = 'Usage: readlink [OPTION]... FILE...'#10 +
    'Print value of a symbolic link or canonical file name.'#10 +
    #10 +
    '  -f, --canonicalize     canonicalize by following every symlink in every'#10 +
    '                         component of the given name recursively'#10 +
    '  -n, --no-newline       do not output the trailing delimiter'#10 +
    '  -q, --quiet, -s, --silent  suppress most error messages'#10 +
    '  -v, --verbose          report error messages'#10 +
    '  -z, --zero             end each output line with NUL, not newline'#10;

  OptionCanonicalize = 1;
  OptionNoNewline = 2;
  OptionQuiet = 3;
  OptionVerbose = 4;
  OptionZero = 5;
  MaximumLinkDepth = 40;

{ Appends component Name to the absolute path in Builder, handling "."
  and ".." and following symbolic links. }
function AddComponent(var Builder: TTextBuilder; Name: PChar; Depth: Integer): LongInt; forward;

function ResolveInto(var Builder: TTextBuilder; Path: PChar; Depth: Integer): LongInt;
var
  Copy: PChar;
  Start: PtrUInt;
  Position: PtrUInt;
  Directory: array[0..PathCapacity - 1] of Char;
begin
  Result := ErrorNone;
  if Path[0] = '/' then
  begin
    DiscardText(Builder);
    BeginText(Builder);
  end
  else if Builder.Length = 0 then
  begin
    GetCurrentDirectory(@Directory[0], PathCapacity);
    AppendText(Builder, @Directory[0]);
    if TextIsEqual(Builder.Text, '/') then
      Builder.Length := 0;
  end;

  Copy := DuplicateText(Path);
  Position := 0;
  while Copy[Position] <> #0 do
  begin
    while Copy[Position] = '/' do
      Inc(Position);
    Start := Position;
    while (Copy[Position] <> '/') and (Copy[Position] <> #0) do
      Inc(Position);
    if Position = Start then
      Break;
    if Copy[Position] = '/' then
    begin
      Copy[Position] := #0;
      Result := AddComponent(Builder, Copy + Start, Depth);
      Copy[Position] := '/';
    end
    else
      Result := AddComponent(Builder, Copy + Start, Depth);
    if Result <> ErrorNone then
      Break;
  end;
  FreeMemory(Copy);
end;

function AddComponent(var Builder: TTextBuilder; Name: PChar; Depth: Integer): LongInt;
var
  LastSlash: PtrInt;
  Information: TFileInformation;
  Target: array[0..PathCapacity - 1] of Char;
  SavedLength: PtrUInt;
begin
  Result := ErrorNone;
  if TextIsEqual(Name, '.') then
    Exit;
  if TextIsEqual(Name, '..') then
  begin
    LastSlash := FindLastCharacter(Builder.Text, '/');
    if LastSlash >= 0 then
    begin
      Builder.Length := PtrUInt(LastSlash);
      Builder.Text[Builder.Length] := #0;
    end;
    Exit;
  end;
  SavedLength := Builder.Length;
  AppendCharacter(Builder, '/');
  AppendText(Builder, Name);
  if GetLinkInformation(Builder.Text, Information) <> ErrorNone then
    { A missing last component is allowed, as with readlink -f. }
    Exit;
  if Information.Kind <> KindSymbolicLink then
    Exit;
  if Depth >= MaximumLinkDepth then
    Exit(ErrorTooManyLinks);
  Result := ReadSymbolicLink(Builder.Text, @Target[0], PathCapacity);
  if Result <> ErrorNone then
    Exit;
  Builder.Length := SavedLength;
  Builder.Text[Builder.Length] := #0;
  Result := ResolveInto(Builder, @Target[0], Depth + 1);
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  Canonicalize: Boolean;
  NoNewline: Boolean;
  Quiet: Boolean;
  LineEnd: Char;
  Index: Integer;
  Target: array[0..PathCapacity - 1] of Char;
  Builder: TTextBuilder;
  Error: LongInt;
  ExitStatus: LongInt;
begin
  Canonicalize := False;
  NoNewline := False;
  Quiet := True;
  LineEnd := #10;
  BeginOptions(Parser, [
    OptionDefinition('f', 'canonicalize', False, OptionCanonicalize),
    OptionDefinition('e', 'canonicalize-existing', False, OptionCanonicalize),
    OptionDefinition('m', 'canonicalize-missing', False, OptionCanonicalize),
    OptionDefinition('n', 'no-newline', False, OptionNoNewline),
    OptionDefinition('q', 'quiet', False, OptionQuiet),
    OptionDefinition('s', 'silent', False, OptionQuiet),
    OptionDefinition('v', 'verbose', False, OptionVerbose),
    OptionDefinition('z', 'zero', False, OptionZero)], Usage);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionCanonicalize: Canonicalize := True;
      OptionNoNewline: NoNewline := True;
      OptionQuiet: Quiet := True;
      OptionVerbose: Quiet := False;
      OptionZero: LineEnd := #0;
    end;
  if Parser.OperandCount = 0 then
    FailWithUsageHint('missing operand', []);

  ExitStatus := 0;
  for Index := 0 to Parser.OperandCount - 1 do
  begin
    if Canonicalize then
    begin
      BeginText(Builder);
      Error := ResolveInto(Builder, Parser.Operands[Index], 0);
      if Builder.Length = 0 then
        AppendCharacter(Builder, '/');
      if Error = ErrorNone then
        CopyText(@Target[0], Builder.Text, PathCapacity);
      DiscardText(Builder);
    end
    else
      Error := ReadSymbolicLink(Parser.Operands[Index], @Target[0], PathCapacity);
    if Error <> ErrorNone then
    begin
      if not Quiet then
        ReportError(Error, '%s', [ArgumentText(Parser.Operands[Index])]);
      ExitStatus := 1;
      Continue;
    end;
    WriteText(StandardOutput, @Target[0]);
    if not NoNewline or (Parser.OperandCount > 1) then
      WriteCharacter(StandardOutput, LineEnd);
  end;
  Halt(ExitStatus);
end.
