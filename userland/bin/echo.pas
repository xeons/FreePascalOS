{
  echo - display a line of text

  echo [-neE] [STRING]...

  Writes the arguments separated by single spaces, followed by a line
  end. -n leaves out the line end, -e interprets backslash escapes
  (\n \t \\ \a \b \r \v \f \0NNN \c), -E disables them (the default).
  As in GNU echo, options are only recognized before the first string,
  and "--help" is not special.
}
program echo;

{$mode objfpc}
{$pointermath on}

uses
  Sys.Environment,
  Sys.Streams;

var
  PrintLineEnd: Boolean;
  InterpretEscapes: Boolean;

function IsEchoOption(Text: PChar): Boolean;
var
  Index: Integer;
begin
  Result := False;
  if (Text[0] <> '-') or (Text[1] = #0) then
    Exit;
  Index := 1;
  while Text[Index] <> #0 do
  begin
    if not (Text[Index] in ['n', 'e', 'E']) then
      Exit;
    Inc(Index);
  end;
  Result := True;
end;

procedure ApplyOption(Text: PChar);
var
  Index: Integer;
begin
  Index := 1;
  while Text[Index] <> #0 do
  begin
    case Text[Index] of
      'n': PrintLineEnd := False;
      'e': InterpretEscapes := True;
      'E': InterpretEscapes := False;
    end;
    Inc(Index);
  end;
end;

{ Writes Text with escapes interpreted; returns False after \c, which
  ends all output. }
function WriteEscaped(Text: PChar): Boolean;
var
  Index: Integer;
  Value: Integer;
  DigitCount: Integer;
begin
  Index := 0;
  while Text[Index] <> #0 do
  begin
    if (Text[Index] <> '\') or (Text[Index + 1] = #0) then
    begin
      WriteCharacter(StandardOutput, Text[Index]);
      Inc(Index);
      Continue;
    end;
    Inc(Index);
    case Text[Index] of
      'n': WriteCharacter(StandardOutput, #10);
      't': WriteCharacter(StandardOutput, #9);
      'r': WriteCharacter(StandardOutput, #13);
      'a': WriteCharacter(StandardOutput, #7);
      'b': WriteCharacter(StandardOutput, #8);
      'v': WriteCharacter(StandardOutput, #11);
      'f': WriteCharacter(StandardOutput, #12);
      'e': WriteCharacter(StandardOutput, #27);
      '\': WriteCharacter(StandardOutput, '\');
      'c': Exit(False);
      '0':
        begin
          Value := 0;
          DigitCount := 0;
          while (DigitCount < 3) and (Text[Index + 1] in ['0'..'7']) do
          begin
            Inc(Index);
            Value := Value * 8 + Ord(Text[Index]) - Ord('0');
            Inc(DigitCount);
          end;
          WriteCharacter(StandardOutput, Char(Value and $FF));
        end;
    else
      begin
        WriteCharacter(StandardOutput, '\');
        WriteCharacter(StandardOutput, Text[Index]);
      end;
    end;
    Inc(Index);
  end;
  Result := True;
end;

var
  ArgumentIndex: Integer;
  FirstString: Integer;
begin
  PrintLineEnd := True;
  InterpretEscapes := False;

  ArgumentIndex := 1;
  while (ArgumentIndex < ArgumentTotal) and IsEchoOption(Argument(ArgumentIndex)) do
  begin
    ApplyOption(Argument(ArgumentIndex));
    Inc(ArgumentIndex);
  end;

  FirstString := ArgumentIndex;
  while ArgumentIndex < ArgumentTotal do
  begin
    if ArgumentIndex > FirstString then
      WriteCharacter(StandardOutput, ' ');
    if InterpretEscapes then
    begin
      if not WriteEscaped(Argument(ArgumentIndex)) then
        Halt(0);
    end
    else
      WriteText(StandardOutput, Argument(ArgumentIndex));
    Inc(ArgumentIndex);
  end;
  if PrintLineEnd then
    WriteCharacter(StandardOutput, #10);
end.
