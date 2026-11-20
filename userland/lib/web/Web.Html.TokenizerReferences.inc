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
  Web.Html.Tokenizer: character references, named and numeric.
}

const
  { What numeric references to 0x80..0x9F stand for (windows-1252). }
  C1Replacements: array[$80..$9F] of Word = (
    $20AC, $0081, $201A, $0192, $201E, $2026, $2020, $2021, $02C6, $2030, $0160, $2039, $0152, $008D, $017D, $008F,
    $0090, $2018, $2019, $201C, $201D, $2022, $2013, $2014, $02DC, $2122, $0161, $203A, $0153, $009D, $017E, $0178);

function THtmlTokenizer.StepCharacterReference: Boolean;
var
  Value: Byte;
begin
  FTemporaryBuffer.Clear;
  FTemporaryBuffer.AppendChar('&');
  case ReadNext(FInput, Value) of
    ReadSuspend:
      Exit(False);
    ReadByteAvailable:
      begin
        if IsAsciiAlphanumeric(Value) then
        begin
          FInput.Back;
          FState := TsNamedCharacterReference;
          Exit(True);
        end;
        if Value = Ord('#') then
        begin
          FTemporaryBuffer.AppendChar('#');
          FState := TsNumericCharacterReference;
          Exit(True);
        end;
        FInput.Back;
      end;
  end;
  FlushCharacterReference;
  FState := FReturnState;
  Result := True;
end;

function THtmlTokenizer.StepNamedCharacterReference: Boolean;
var
  ReferenceIndex, MatchLength: Integer;
  Next: Byte;
  LastIsSemicolon: Boolean;
begin
  case MatchNamedReference(FInput.CurrentPointer, FInput.Available, FInput.NoMoreInputComing, ReferenceIndex,
    MatchLength) of
    NamedReferenceNeedsMoreInput:
      Exit(False);
    NamedReferenceNoMatch:
      begin
        FlushCharacterReference;
        FState := TsAmbiguousAmpersand;
        Exit(True);
      end;
  end;
  LastIsSemicolon := FInput.CurrentPointer[MatchLength - 1] = ';';
  if IsInAttributeValue and not LastIsSemicolon then
  begin
    { The character after the name decides; it may not be here yet. }
    if MatchLength >= FInput.Available then
    begin
      if not FInput.NoMoreInputComing then
        Exit(False);
      Next := 0;
    end
    else
      Next := Ord(FInput.CurrentPointer[MatchLength]);
    if (Next = Ord('=')) or IsAsciiAlphanumeric(Next) then
    begin
      FTemporaryBuffer.Append(FInput.CurrentPointer, MatchLength);
      FInput.Skip(MatchLength);
      FlushCharacterReference;
      FState := FReturnState;
      Exit(True);
    end;
  end;
  FInput.Skip(MatchLength);
  if not LastIsSemicolon then
    ParseError('missing-semicolon-after-character-reference');
  FTemporaryBuffer.Clear;
  FTemporaryBuffer.AppendString(NamedReferenceText(ReferenceIndex));
  FlushCharacterReference;
  FState := FReturnState;
  Result := True;
end;

function THtmlTokenizer.StepAmbiguousAmpersand: Boolean;
var
  Value: Byte;
begin
  case ReadNext(FInput, Value) of
    ReadSuspend:
      Exit(False);
    ReadByteAvailable:
      begin
        if IsAsciiAlphanumeric(Value) then
        begin
          AppendToAttributeOrEmit(Value);
          Exit(True);
        end;
        if Value = Ord(';') then
          ParseError('unknown-named-character-reference');
        FInput.Back;
      end;
  end;
  FState := FReturnState;
  Result := True;
end;

function THtmlTokenizer.StepNumericCharacterReference: Boolean;
var
  Value: Byte;
begin
  FCharacterReferenceCode := 0;
  case ReadNext(FInput, Value) of
    ReadSuspend:
      Exit(False);
    ReadByteAvailable:
      begin
        if (Value = Ord('x')) or (Value = Ord('X')) then
        begin
          FTemporaryBuffer.AppendChar(Chr(Value));
          FState := TsHexadecimalCharacterReferenceStart;
          Exit(True);
        end;
        FInput.Back;
      end;
  end;
  FState := TsDecimalCharacterReferenceStart;
  Result := True;
end;

function IsHexDigit(Value: Byte): Boolean; inline;
begin
  Result := Value in [Ord('0')..Ord('9'), Ord('a')..Ord('f'), Ord('A')..Ord('F')];
end;

function THtmlTokenizer.StepNumericReferenceStart(Hexadecimal: Boolean): Boolean;
var
  Value: Byte;
begin
  case ReadNext(FInput, Value) of
    ReadSuspend:
      Exit(False);
    ReadByteAvailable:
      begin
        FInput.Back;
        if (Hexadecimal and IsHexDigit(Value)) or (not Hexadecimal and (Value in [Ord('0')..Ord('9')])) then
        begin
          if Hexadecimal then
            FState := TsHexadecimalCharacterReference
          else
            FState := TsDecimalCharacterReference;
          Exit(True);
        end;
      end;
  end;
  ParseError('absence-of-digits-in-numeric-character-reference');
  FlushCharacterReference;
  FState := FReturnState;
  Result := True;
end;

procedure AddDigit(var Code: LongWord; Base, Digit: LongWord); inline;
begin
  { Past the Unicode range the value only needs to stay past it. }
  if Code <= $10FFFF then
    Code := Code * Base + Digit;
end;

function THtmlTokenizer.StepHexadecimalCharacterReference: Boolean;
var
  Value: Byte;
begin
  case ReadNext(FInput, Value) of
    ReadSuspend:
      Exit(False);
    ReadByteAvailable:
      begin
        case Value of
          Ord('0')..Ord('9'):
            begin
              AddDigit(FCharacterReferenceCode, 16, Value - Ord('0'));
              Exit(True);
            end;
          Ord('A')..Ord('F'):
            begin
              AddDigit(FCharacterReferenceCode, 16, Value - Ord('A') + 10);
              Exit(True);
            end;
          Ord('a')..Ord('f'):
            begin
              AddDigit(FCharacterReferenceCode, 16, Value - Ord('a') + 10);
              Exit(True);
            end;
          Ord(';'):
            begin
              FState := TsNumericCharacterReferenceEnd;
              Exit(True);
            end;
        end;
        FInput.Back;
      end;
  end;
  ParseError('missing-semicolon-after-character-reference');
  FState := TsNumericCharacterReferenceEnd;
  Result := True;
end;

function THtmlTokenizer.StepDecimalCharacterReference: Boolean;
var
  Value: Byte;
begin
  case ReadNext(FInput, Value) of
    ReadSuspend:
      Exit(False);
    ReadByteAvailable:
      begin
        if Value in [Ord('0')..Ord('9')] then
        begin
          AddDigit(FCharacterReferenceCode, 10, Value - Ord('0'));
          Exit(True);
        end;
        if Value = Ord(';') then
        begin
          FState := TsNumericCharacterReferenceEnd;
          Exit(True);
        end;
        FInput.Back;
      end;
  end;
  ParseError('missing-semicolon-after-character-reference');
  FState := TsNumericCharacterReferenceEnd;
  Result := True;
end;

function IsNoncharacter(Code: LongWord): Boolean; inline;
begin
  Result := ((Code >= $FDD0) and (Code <= $FDEF)) or ((Code and $FFFE) = $FFFE);
end;

function THtmlTokenizer.StepNumericCharacterReferenceEnd: Boolean;
var
  Code: LongWord;
begin
  Code := FCharacterReferenceCode;
  if Code = 0 then
  begin
    ParseError('null-character-reference');
    Code := $FFFD;
  end
  else if Code > $10FFFF then
  begin
    ParseError('character-reference-outside-unicode-range');
    Code := $FFFD;
  end
  else if (Code >= $D800) and (Code <= $DFFF) then
  begin
    ParseError('surrogate-character-reference');
    Code := $FFFD;
  end
  else if IsNoncharacter(Code) then
    ParseError('noncharacter-character-reference')
  else if (Code = $0D) or (((Code < $20) or ((Code >= $7F) and (Code <= $9F))) and
    not (Code in [$09, $0A, $0C, $20])) then
  begin
    ParseError('control-character-reference');
    if (Code >= $80) and (Code <= $9F) then
      Code := C1Replacements[Code];
  end;
  FTemporaryBuffer.Clear;
  FTemporaryBuffer.AppendCodePoint(Code);
  FlushCharacterReference;
  FState := FReturnState;
  Result := True;
end;
