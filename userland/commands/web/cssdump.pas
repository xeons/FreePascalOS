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
  cssdump - parse CSS and print it back normalized (through libcss)
  cssdump [-d] [-s] [FILE...]

  Each FILE (standard input when there is none, or for "-") is parsed
  as a style sheet and printed the way CSSOM serializes it: what did
  not parse is gone, values are in their canonical form, shorthands are
  folded where they can be. -d reads declarations (a style attribute)
  instead of a style sheet; -s lists every selector with its
  specificity.
}
program cssdump;

{$mode objfpc}{$H+}

uses
  Classes,
  SysUtils,
  Css.Selectors,
  Css.Declarations,
  Css.Stylesheets,
  Css.Parser,
  Util.CommandLine,
  Util.Messages;

const
  Usage = 'Usage: cssdump [OPTION]... [FILE]...'#10 +
    'Parse CSS style sheets and print them normalized.'#10 +
    #10 +
    '  -d, --declarations  read declaration lists (style attributes), not style sheets'#10 +
    '  -s, --selectors     list each selector with its specificity (a,b,c)'#10 +
    '      --help          display this help and exit'#10 +
    #10 +
    'With no FILE, or when FILE is -, read standard input.';

  OptionDeclarations = 100;
  OptionSelectors = 101;

var
  ReadDeclarations: Boolean = False;
  ListSelectors: Boolean = False;
  ExitStatus: Integer = 0;

function ReadAll(Source: TStream): string;
var
  Buffer: array[0..65535] of Byte;
  Count: LongInt;
  Text: TStringStream;
begin
  Text := TStringStream.Create('');
  try
    repeat
      Count := Source.Read(Buffer[0], SizeOf(Buffer));
      if Count > 0 then
        Text.WriteBuffer(Buffer[0], Count);
    until Count <= 0;
    Result := Text.DataString;
  finally
    Text.Free;
  end;
end;

function SpecificityText(Specificity: LongWord): string;
begin
  Result := Format('(%d,%d,%d)', [Specificity shr 20, (Specificity shr 10) and 1023, Specificity and 1023]);
end;

procedure ListRuleSelectors(const Rules: TCssRuleArray);
var
  Index, Item: Integer;
  StyleRule: TCssStyleRule;
begin
  for Index := 0 to High(Rules) do
  begin
    if Rules[Index].Kind = rkStyle then
    begin
      StyleRule := TCssStyleRule(Rules[Index]);
      for Item := 0 to StyleRule.Selectors.Count - 1 do
        WriteLn(SpecificityText(StyleRule.Selectors.Items[Item].Specificity), ' ',
          StyleRule.Selectors.Items[Item].Serialize);
    end;
    if Rules[Index] is TCssGroupingRule then
      ListRuleSelectors(TCssGroupingRule(Rules[Index]).Rules);
  end;
end;

procedure Dump(const Source: string);
var
  Sheet: TCssStyleSheet;
  Block: TCssDeclarationBlock;
begin
  if ReadDeclarations then
  begin
    Block := ParseStyleAttribute(Source);
    try
      WriteLn(Block.Serialize);
    finally
      Block.Free;
    end;
    Exit;
  end;
  Sheet := ParseStyleSheet(Source, coAuthor);
  try
    if ListSelectors then
      ListRuleSelectors(Sheet.Rules)
    else
      Write(Sheet.Serialize);
  finally
    Sheet.Free;
  end;
end;

procedure DumpFile(const Name: string);
var
  Source: TStream;
begin
  try
    if Name = '-' then
      Source := THandleStream.Create(StdInputHandle)
    else
      Source := TFileStream.Create(Name, fmOpenRead or fmShareDenyNone);
    try
      Dump(ReadAll(Source));
    finally
      Source.Free;
    end;
  except
    on Failure: Exception do
    begin
      Report(Name + ': ' + Failure.Message);
      ExitStatus := 1;
    end;
  end;
end;

var
  CommandLine: TCommandLine;
  Code, Index: Integer;
  Value: string;
begin
  CommandLine := TCommandLine.Create([
    CommandOption('d', 'declarations', False, OptionDeclarations),
    CommandOption('s', 'selectors', False, OptionSelectors)], Usage);
  try
    while CommandLine.NextOption(Code, Value) do
      case Code of
        OptionDeclarations: ReadDeclarations := True;
        OptionSelectors: ListSelectors := True;
      end;
    if CommandLine.OperandCount = 0 then
      DumpFile('-')
    else
      for Index := 0 to CommandLine.OperandCount - 1 do
        DumpFile(CommandLine.Operands[Index]);
  finally
    CommandLine.Free;
  end;
  Halt(ExitStatus);
end.
