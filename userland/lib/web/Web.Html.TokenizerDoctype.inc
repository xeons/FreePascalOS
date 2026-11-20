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
  Web.Html.Tokenizer: the DOCTYPE states.
}

procedure EmitQuirkyDoctypeAtEnd(Tokenizer: THtmlTokenizer);
begin
  Tokenizer.ParseError('eof-in-doctype');
  Tokenizer.FToken.ForceQuirks := True;
  Tokenizer.EmitDoctype;
  Tokenizer.EmitEndOfFile;
end;

function THtmlTokenizer.StepDoctype: Boolean;
var
  Value: Byte;
begin
  case ReadNext(FInput, Value) of
    ReadSuspend:
      Exit(False);
    ReadEndOfFile:
      begin
        StartDoctype;
        EmitQuirkyDoctypeAtEnd(Self);
        Exit(True);
      end;
  end;
  if IsTokenizerWhitespace(Value) then
    FState := TsBeforeDoctypeName
  else if Value = Ord('>') then
  begin
    FInput.Back;
    FState := TsBeforeDoctypeName;
  end
  else
  begin
    ParseError('missing-whitespace-before-doctype-name');
    FInput.Back;
    FState := TsBeforeDoctypeName;
  end;
  Result := True;
end;

function THtmlTokenizer.StepBeforeDoctypeName: Boolean;
var
  Value: Byte;
begin
  case ReadNext(FInput, Value) of
    ReadSuspend:
      Exit(False);
    ReadEndOfFile:
      begin
        StartDoctype;
        EmitQuirkyDoctypeAtEnd(Self);
        Exit(True);
      end;
  end;
  if IsTokenizerWhitespace(Value) then
    Exit(True);
  StartDoctype;
  if Value = Ord('>') then
  begin
    ParseError('missing-doctype-name');
    FToken.ForceQuirks := True;
    FState := TsData;
    EmitDoctype;
    Exit(True);
  end;
  FToken.HasDoctypeName := True;
  if Value = 0 then
  begin
    ParseError('unexpected-null-character');
    FDoctypeName.AppendString(ReplacementCharacterUtf8);
  end
  else
    FDoctypeName.AppendChar(LowerByte(Value));
  FState := TsDoctypeName;
  Result := True;
end;

function THtmlTokenizer.StepDoctypeName: Boolean;
var
  Value: Byte;
begin
  case ReadNext(FInput, Value) of
    ReadSuspend:
      Exit(False);
    ReadEndOfFile:
      begin
        EmitQuirkyDoctypeAtEnd(Self);
        Exit(True);
      end;
  end;
  if IsTokenizerWhitespace(Value) then
    FState := TsAfterDoctypeName
  else if Value = Ord('>') then
  begin
    FState := TsData;
    EmitDoctype;
  end
  else if Value = 0 then
  begin
    ParseError('unexpected-null-character');
    FDoctypeName.AppendString(ReplacementCharacterUtf8);
  end
  else
    FDoctypeName.AppendChar(LowerByte(Value));
  Result := True;
end;

function THtmlTokenizer.StepAfterDoctypeName: Boolean;
var
  Value: Byte;
  Keyword: TReadResult;
begin
  if not FInput.HasByte then
  begin
    if not FInput.AtEnd then
      Exit(False);
    EmitQuirkyDoctypeAtEnd(Self);
    Exit(True);
  end;
  Value := FInput.PeekByte;
  if IsTokenizerWhitespace(Value) then
  begin
    FInput.Skip(1);
    Exit(True);
  end;
  if Value = Ord('>') then
  begin
    FInput.Skip(1);
    FState := TsData;
    EmitDoctype;
    Exit(True);
  end;
  Keyword := InputContinuesWith(FInput, 'PUBLIC', True);
  if Keyword = ReadSuspend then
    Exit(False);
  if Keyword = ReadByteAvailable then
  begin
    FInput.Skip(6);
    FState := TsAfterDoctypePublicKeyword;
    Exit(True);
  end;
  Keyword := InputContinuesWith(FInput, 'SYSTEM', True);
  if Keyword = ReadSuspend then
    Exit(False);
  if Keyword = ReadByteAvailable then
  begin
    FInput.Skip(6);
    FState := TsAfterDoctypeSystemKeyword;
    Exit(True);
  end;
  ParseError('invalid-character-sequence-after-doctype-name');
  FToken.ForceQuirks := True;
  FState := TsBogusDoctype;
  Result := True;
end;

procedure StartIdentifier(Tokenizer: THtmlTokenizer; IsPublic: Boolean; Quote: Byte);
begin
  if IsPublic then
  begin
    Tokenizer.FToken.HasPublicId := True;
    Tokenizer.FPublicId.Clear;
    if Quote = Ord('"') then
      Tokenizer.FState := TsDoctypePublicIdentifierDoubleQuoted
    else
      Tokenizer.FState := TsDoctypePublicIdentifierSingleQuoted;
  end
  else
  begin
    Tokenizer.FToken.HasSystemId := True;
    Tokenizer.FSystemId.Clear;
    if Quote = Ord('"') then
      Tokenizer.FState := TsDoctypeSystemIdentifierDoubleQuoted
    else
      Tokenizer.FState := TsDoctypeSystemIdentifierSingleQuoted;
  end;
end;

function THtmlTokenizer.StepAfterDoctypeKeyword(IsPublic: Boolean): Boolean;
var
  Value: Byte;
begin
  case ReadNext(FInput, Value) of
    ReadSuspend:
      Exit(False);
    ReadEndOfFile:
      begin
        EmitQuirkyDoctypeAtEnd(Self);
        Exit(True);
      end;
  end;
  if IsTokenizerWhitespace(Value) then
  begin
    if IsPublic then
      FState := TsBeforeDoctypePublicIdentifier
    else
      FState := TsBeforeDoctypeSystemIdentifier;
  end
  else if (Value = Ord('"')) or (Value = Ord('''')) then
  begin
    if IsPublic then
      ParseError('missing-whitespace-after-doctype-public-keyword')
    else
      ParseError('missing-whitespace-after-doctype-system-keyword');
    StartIdentifier(Self, IsPublic, Value);
  end
  else if Value = Ord('>') then
  begin
    if IsPublic then
      ParseError('missing-doctype-public-identifier')
    else
      ParseError('missing-doctype-system-identifier');
    FToken.ForceQuirks := True;
    FState := TsData;
    EmitDoctype;
  end
  else
  begin
    if IsPublic then
      ParseError('missing-quote-before-doctype-public-identifier')
    else
      ParseError('missing-quote-before-doctype-system-identifier');
    FToken.ForceQuirks := True;
    FInput.Back;
    FState := TsBogusDoctype;
  end;
  Result := True;
end;

function THtmlTokenizer.StepBeforeDoctypeIdentifier(IsPublic: Boolean): Boolean;
var
  Value: Byte;
begin
  case ReadNext(FInput, Value) of
    ReadSuspend:
      Exit(False);
    ReadEndOfFile:
      begin
        EmitQuirkyDoctypeAtEnd(Self);
        Exit(True);
      end;
  end;
  if IsTokenizerWhitespace(Value) then
    Exit(True);
  if (Value = Ord('"')) or (Value = Ord('''')) then
    StartIdentifier(Self, IsPublic, Value)
  else if Value = Ord('>') then
  begin
    if IsPublic then
      ParseError('missing-doctype-public-identifier')
    else
      ParseError('missing-doctype-system-identifier');
    FToken.ForceQuirks := True;
    FState := TsData;
    EmitDoctype;
  end
  else
  begin
    if IsPublic then
      ParseError('missing-quote-before-doctype-public-identifier')
    else
      ParseError('missing-quote-before-doctype-system-identifier');
    FToken.ForceQuirks := True;
    FInput.Back;
    FState := TsBogusDoctype;
  end;
  Result := True;
end;

function THtmlTokenizer.StepDoctypeIdentifierQuoted(IsPublic: Boolean; Quote: Byte): Boolean;
var
  Value: Byte;
  Target: TTextBuffer;
begin
  case ReadNext(FInput, Value) of
    ReadSuspend:
      Exit(False);
    ReadEndOfFile:
      begin
        EmitQuirkyDoctypeAtEnd(Self);
        Exit(True);
      end;
  end;
  if IsPublic then
    Target := FPublicId
  else
    Target := FSystemId;
  if Value = Quote then
  begin
    if IsPublic then
      FState := TsAfterDoctypePublicIdentifier
    else
      FState := TsAfterDoctypeSystemIdentifier;
  end
  else if Value = 0 then
  begin
    ParseError('unexpected-null-character');
    Target.AppendString(ReplacementCharacterUtf8);
  end
  else if Value = Ord('>') then
  begin
    if IsPublic then
      ParseError('abrupt-doctype-public-identifier')
    else
      ParseError('abrupt-doctype-system-identifier');
    FToken.ForceQuirks := True;
    FState := TsData;
    EmitDoctype;
  end
  else
    Target.AppendChar(Chr(Value));
  Result := True;
end;

function THtmlTokenizer.StepAfterDoctypePublicIdentifier: Boolean;
var
  Value: Byte;
begin
  case ReadNext(FInput, Value) of
    ReadSuspend:
      Exit(False);
    ReadEndOfFile:
      begin
        EmitQuirkyDoctypeAtEnd(Self);
        Exit(True);
      end;
  end;
  if IsTokenizerWhitespace(Value) then
    FState := TsBetweenDoctypePublicAndSystemIdentifiers
  else if Value = Ord('>') then
  begin
    FState := TsData;
    EmitDoctype;
  end
  else if (Value = Ord('"')) or (Value = Ord('''')) then
  begin
    ParseError('missing-whitespace-between-doctype-public-and-system-identifiers');
    StartIdentifier(Self, False, Value);
  end
  else
  begin
    ParseError('missing-quote-before-doctype-system-identifier');
    FToken.ForceQuirks := True;
    FInput.Back;
    FState := TsBogusDoctype;
  end;
  Result := True;
end;

function THtmlTokenizer.StepBetweenDoctypePublicAndSystemIdentifiers: Boolean;
var
  Value: Byte;
begin
  case ReadNext(FInput, Value) of
    ReadSuspend:
      Exit(False);
    ReadEndOfFile:
      begin
        EmitQuirkyDoctypeAtEnd(Self);
        Exit(True);
      end;
  end;
  if IsTokenizerWhitespace(Value) then
    Exit(True);
  if Value = Ord('>') then
  begin
    FState := TsData;
    EmitDoctype;
  end
  else if (Value = Ord('"')) or (Value = Ord('''')) then
    StartIdentifier(Self, False, Value)
  else
  begin
    ParseError('missing-quote-before-doctype-system-identifier');
    FToken.ForceQuirks := True;
    FInput.Back;
    FState := TsBogusDoctype;
  end;
  Result := True;
end;

function THtmlTokenizer.StepAfterDoctypeSystemIdentifier: Boolean;
var
  Value: Byte;
begin
  case ReadNext(FInput, Value) of
    ReadSuspend:
      Exit(False);
    ReadEndOfFile:
      begin
        EmitQuirkyDoctypeAtEnd(Self);
        Exit(True);
      end;
  end;
  if IsTokenizerWhitespace(Value) then
    Exit(True);
  if Value = Ord('>') then
  begin
    FState := TsData;
    EmitDoctype;
  end
  else
  begin
    ParseError('unexpected-character-after-doctype-system-identifier');
    FInput.Back;
    FState := TsBogusDoctype;
  end;
  Result := True;
end;

function THtmlTokenizer.StepBogusDoctype: Boolean;
var
  Value: Byte;
begin
  case ReadNext(FInput, Value) of
    ReadSuspend:
      Exit(False);
    ReadEndOfFile:
      begin
        EmitDoctype;
        EmitEndOfFile;
        Exit(True);
      end;
  end;
  if Value = Ord('>') then
  begin
    FState := TsData;
    EmitDoctype;
  end
  else if Value = 0 then
    ParseError('unexpected-null-character');
  Result := True;
end;
