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

(*
  Parameter expansion: the special parameters ($? $$ $! $# $0..$9) and
  the forms in braces.

    ${NAME}  ${#NAME}
    ${NAME:-word}  ${NAME:=word}  ${NAME:+word}  ${NAME:?word}
                   (without ':' they test for unset only)
    ${NAME#pattern}  ${NAME##pattern}  ${NAME%pattern}  ${NAME%%pattern}

  A name in braces is a variable name, a number (a positional parameter)
  or one special character. Anything else is a bad substitution: the
  command is not run (ExpansionFailed).
*)
unit Shell.Parameters;

{$mode objfpc}
{$H+}

interface

uses
  Shell.Expansion;

{ A one-character special parameter (or $1..$9). False if Name is not
  one; IsSet is False for a positional parameter past the end. }
function SpecialParameter(Name: Char; out Value: string; out IsSet: Boolean): Boolean;

(* Expands the ${...} whose brace is at Word[Position] into Expander;
  Position ends after the closing brace. *)
procedure ExpandBracedParameter(Expander: TWordExpander; const Word: string; var Position: Integer;
  Quoted: Boolean);

implementation

uses
  SysUtils,
  Sys.Processes,
  Sys.Text,
  Shell.Text,
  Shell.Output,
  Shell.Patterns,
  Shell.Variables;

function SpecialParameter(Name: Char; out Value: string; out IsSet: Boolean): Boolean;
begin
  Result := True;
  IsSet := True;
  Value := '';
  case Name of
    '?': Value := IntToStr(LastStatus);
    '$': Value := IntToStr(CurrentProcessId);
    '!':
      if LastBackgroundProcessId > 0 then
        Value := IntToStr(LastBackgroundProcessId);
    '#': Value := IntToStr(PositionalCount);
    '0': Value := ScriptName;
    '1'..'9': IsSet := FindPositionalParameter(Ord(Name) - Ord('0'), Value);
  else
    begin
      IsSet := False;
      Result := False;
    end;
  end;
end;

{ The value of a parameter name inside braces (variable, positional or
  special); False when it is unset. }
function ParameterValue(const Name: string; out Value: string): Boolean;
var
  Number: Int64;
begin
  if (Length(Name) = 1) and SpecialParameter(Name[1], Value, Result) then
    Exit;
  if IsDigit(CharAt(Name, 1)) and TryParseInteger(Name, Number) then
    Exit(FindPositionalParameter(Integer(Number), Value));
  Result := FindVariable(Name, Value);
end;

(* Finds the brace that closes the dollar-brace before Word[Start]; 0 if
  none. Nested ${...}, quotes and backslashes are skipped. *)
function FindClosingBrace(const Word: string; Start: Integer): Integer;
var
  Position: Integer;
  Depth: Integer;
  Quote: Char;
begin
  Depth := 1;
  Position := Start;
  while Position <= Length(Word) do
  begin
    case Word[Position] of
      '\':
        if Position < Length(Word) then
          Inc(Position);
      '''', '"':
        begin
          Quote := Word[Position];
          Inc(Position);
          while not (CharAt(Word, Position) in [Quote, #0]) do
          begin
            if (Quote = '"') and (Word[Position] = '\') and (CharAt(Word, Position + 1) <> #0) then
              Inc(Position);
            Inc(Position);
          end;
          if CharAt(Word, Position) = #0 then
            Exit(0);
        end;
      '$':
        if CharAt(Word, Position + 1) = '{' then
        begin
          Inc(Depth);
          Inc(Position);
        end;
      '}':
        begin
          Dec(Depth);
          if Depth = 0 then
            Exit(Position);
        end;
    end;
    Inc(Position);
  end;
  Result := 0;
end;

{ Removes the shortest or longest prefix or suffix matching Pattern. }
function RemovePattern(const Value, Pattern: string; FromEnd, Longest: Boolean): string;
var
  Cut: Integer;
begin
  if not FromEnd then
  begin
    { Prefixes of length Cut. }
    if Longest then
      Cut := Length(Value)
    else
      Cut := 0;
    while (Cut >= 0) and (Cut <= Length(Value)) do
    begin
      if MatchPattern(Pattern, Copy(Value, 1, Cut)) then
        Exit(Copy(Value, Cut + 1, MaxInt));
      if Longest then
        Dec(Cut)
      else
        Inc(Cut);
    end;
    Exit(Value);
  end;
  { Suffixes starting after Cut characters. }
  if Longest then
    Cut := 0
  else
    Cut := Length(Value);
  while (Cut >= 0) and (Cut <= Length(Value)) do
  begin
    if MatchPattern(Pattern, Copy(Value, Cut + 1, MaxInt)) then
      Exit(Copy(Value, 1, Cut));
    if Longest then
      Inc(Cut)
    else
      Dec(Cut);
  end;
  Result := Value;
end;

{ The length of the parameter's name at the start of Inner (letters,
  digits and _, digits, or one special character); 0 if there is none. }
function ParameterNameLength(const Inner: string): Integer;
begin
  Result := 0;
  if IsNameStart(CharAt(Inner, 1)) then
    while IsNameCharacter(CharAt(Inner, Result + 1)) do
      Inc(Result)
  else if IsDigit(CharAt(Inner, 1)) then
    while IsDigit(CharAt(Inner, Result + 1)) do
      Inc(Result)
  else if CharAt(Inner, 1) in ['?', '$', '#', '@', '*', '!', '-'] then
    Result := 1;
end;

procedure ReportBadSubstitution(const Inner: string);
begin
  ShellErrorWithoutFlush('${' + Inner + '}: bad substitution');
  ExpansionFailed := True;
end;

(* ${NAME?word} with NAME unset (or empty, with ':'). *)
procedure ReportUnsetParameter(const Name, Argument: string);
var
  Message: string;
begin
  if Argument <> '' then
    Message := ExpandToText(Argument)
  else
    Message := 'parameter null or not set';
  ShellErrorWithoutFlush(Name + ': ' + Message);
  ExpansionFailed := True;
end;

procedure ExpandBracedParameter(Expander: TWordExpander; const Word: string; var Position: Integer;
  Quoted: Boolean);
var
  Finish: Integer;
  Inner: string;
  NameLength: Integer;
  Name: string;
  OperationPosition: Integer;
  Operation: Char;
  Doubled: Boolean;
  UseColon: Boolean;
  Argument: string;
  Value: string;
  IsSet: Boolean;
  NeedsWord: Boolean;
  Expanded: string;
begin
  Finish := FindClosingBrace(Word, Position + 1);
  if Finish = 0 then
  begin
    Expander.AddQuoted('$');
    Exit;
  end;
  Inner := Copy(Word, Position + 1, Finish - (Position + 1));
  Position := Finish + 1;

  (* ${#NAME}: the length. *)
  if (CharAt(Inner, 1) = '#') and (Length(Inner) > 1) then
  begin
    ParameterValue(Copy(Inner, 2, MaxInt), Value);
    Expander.AddExpansionResult(IntToStr(Length(Value)), Quoted);
    Exit;
  end;

  NameLength := ParameterNameLength(Inner);
  if NameLength = 0 then
  begin
    ReportBadSubstitution(Inner);
    Exit;
  end;
  Name := Copy(Inner, 1, NameLength);

  { The operation after the name, and its word. }
  Operation := #0;
  Doubled := False;
  OperationPosition := NameLength + 1;
  UseColon := CharAt(Inner, OperationPosition) = ':';
  if UseColon then
    Inc(OperationPosition);
  if CharAt(Inner, OperationPosition) in ['-', '=', '+', '?'] then
  begin
    Operation := Inner[OperationPosition];
    Inc(OperationPosition);
  end
  else if (CharAt(Inner, OperationPosition) in ['#', '%']) and not UseColon then
  begin
    Operation := Inner[OperationPosition];
    Inc(OperationPosition);
    Doubled := CharAt(Inner, OperationPosition) = Operation;
    if Doubled then
      Inc(OperationPosition);
  end
  else if CharAt(Inner, OperationPosition) <> #0 then
  begin
    ReportBadSubstitution(Inner);
    Exit;
  end;
  Argument := Copy(Inner, OperationPosition, MaxInt);

  IsSet := ParameterValue(Name, Value);
  NeedsWord := (UseColon and (not IsSet or (Value = ''))) or (not UseColon and not IsSet);

  case Operation of
    #0:
      Expander.AddExpansionResult(Value, Quoted);
    '-':
      if NeedsWord then
        Expander.AddExpansionResult(ExpandToText(Argument), Quoted)
      else
        Expander.AddExpansionResult(Value, Quoted);
    '=':
      if NeedsWord then
      begin
        Expanded := ExpandToText(Argument);
        AssignVariable(Name, Expanded);
        Expander.AddExpansionResult(Expanded, Quoted);
      end
      else
        Expander.AddExpansionResult(Value, Quoted);
    '+':
      if not NeedsWord then
        Expander.AddExpansionResult(ExpandToText(Argument), Quoted);
    '?':
      if NeedsWord then
        ReportUnsetParameter(Name, Argument)
      else
        Expander.AddExpansionResult(Value, Quoted);
    '#', '%':
      Expander.AddExpansionResult(RemovePattern(Value, ExpandToPattern(Argument), Operation = '%', Doubled),
        Quoted);
  end;
end;

end.
