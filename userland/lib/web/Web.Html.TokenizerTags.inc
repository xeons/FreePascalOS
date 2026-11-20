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
  Web.Html.Tokenizer: tags and their attributes.
}

function THtmlTokenizer.StepTagOpen: Boolean;
var
  Value: Byte;
begin
  case ReadNext(FInput, Value) of
    ReadSuspend:
      Exit(False);
    ReadEndOfFile:
      begin
        ParseError('eof-before-tag-name');
        EmitByte(Ord('<'));
        EmitEndOfFile;
        Exit(True);
      end;
  end;
  if Value = Ord('!') then
    FState := TsMarkupDeclarationOpen
  else if Value = Ord('/') then
    FState := TsEndTagOpen
  else if IsAsciiAlpha(Value) then
  begin
    StartTag(False);
    FInput.Back;
    FState := TsTagName;
  end
  else if Value = Ord('?') then
  begin
    ParseError('unexpected-question-mark-instead-of-tag-name');
    FCommentData.Clear;
    FInput.Back;
    FState := TsBogusComment;
  end
  else
  begin
    ParseError('invalid-first-character-of-tag-name');
    EmitByte(Ord('<'));
    FInput.Back;
    FState := TsData;
  end;
  Result := True;
end;

function THtmlTokenizer.StepEndTagOpen: Boolean;
var
  Value: Byte;
begin
  case ReadNext(FInput, Value) of
    ReadSuspend:
      Exit(False);
    ReadEndOfFile:
      begin
        ParseError('eof-before-tag-name');
        EmitByte(Ord('<'));
        EmitByte(Ord('/'));
        EmitEndOfFile;
        Exit(True);
      end;
  end;
  if IsAsciiAlpha(Value) then
  begin
    StartTag(True);
    FInput.Back;
    FState := TsTagName;
  end
  else if Value = Ord('>') then
  begin
    ParseError('missing-end-tag-name');
    FState := TsData;
  end
  else
  begin
    ParseError('invalid-first-character-of-tag-name');
    FCommentData.Clear;
    FInput.Back;
    FState := TsBogusComment;
  end;
  Result := True;
end;

function THtmlTokenizer.StepTagName: Boolean;
var
  Value: Byte;
begin
  case ReadNext(FInput, Value) of
    ReadSuspend:
      Exit(False);
    ReadEndOfFile:
      begin
        ParseError('eof-in-tag');
        EmitEndOfFile;
        Exit(True);
      end;
  end;
  case Value of
    9, 10, 12, 32:
      FState := TsBeforeAttributeName;
    Ord('/'):
      FState := TsSelfClosingStartTag;
    Ord('>'):
      begin
        FState := TsData;
        EmitTag;
      end;
    Ord('A')..Ord('Z'):
      FTagName.AppendChar(Chr(Value + 32));
    0:
      begin
        ParseError('unexpected-null-character');
        FTagName.AppendString(ReplacementCharacterUtf8);
      end;
  else
    FTagName.AppendChar(Chr(Value));
  end;
  Result := True;
end;

function THtmlTokenizer.StepBeforeAttributeName: Boolean;
var
  Value: Byte;
begin
  case ReadNext(FInput, Value) of
    ReadSuspend:
      Exit(False);
    ReadEndOfFile:
      begin
        FState := TsAfterAttributeName;
        Exit(True);
      end;
  end;
  case Value of
    9, 10, 12, 32:
      ;
    Ord('/'), Ord('>'):
      begin
        FInput.Back;
        FState := TsAfterAttributeName;
      end;
    Ord('='):
      begin
        ParseError('unexpected-equals-sign-before-attribute-name');
        StartAttribute;
        FAttributeName.AppendChar('=');
        FState := TsAttributeName;
      end;
  else
    StartAttribute;
    FInput.Back;
    FState := TsAttributeName;
  end;
  Result := True;
end;

function THtmlTokenizer.StepAttributeName: Boolean;
var
  Value: Byte;
begin
  case ReadNext(FInput, Value) of
    ReadSuspend:
      Exit(False);
    ReadEndOfFile:
      begin
        LeaveAttributeName;
        FState := TsAfterAttributeName;
        Exit(True);
      end;
  end;
  case Value of
    9, 10, 12, 32, Ord('/'), Ord('>'):
      begin
        LeaveAttributeName;
        FInput.Back;
        FState := TsAfterAttributeName;
      end;
    Ord('='):
      begin
        LeaveAttributeName;
        FState := TsBeforeAttributeValue;
      end;
    Ord('A')..Ord('Z'):
      FAttributeName.AppendChar(Chr(Value + 32));
    0:
      begin
        ParseError('unexpected-null-character');
        FAttributeName.AppendString(ReplacementCharacterUtf8);
      end;
    Ord('"'), Ord(''''), Ord('<'):
      begin
        ParseError('unexpected-character-in-attribute-name');
        FAttributeName.AppendChar(Chr(Value));
      end;
  else
    FAttributeName.AppendChar(Chr(Value));
  end;
  Result := True;
end;

function THtmlTokenizer.StepAfterAttributeName: Boolean;
var
  Value: Byte;
begin
  case ReadNext(FInput, Value) of
    ReadSuspend:
      Exit(False);
    ReadEndOfFile:
      begin
        ParseError('eof-in-tag');
        EmitEndOfFile;
        Exit(True);
      end;
  end;
  case Value of
    9, 10, 12, 32:
      ;
    Ord('/'):
      FState := TsSelfClosingStartTag;
    Ord('='):
      FState := TsBeforeAttributeValue;
    Ord('>'):
      begin
        FState := TsData;
        EmitTag;
      end;
  else
    StartAttribute;
    FInput.Back;
    FState := TsAttributeName;
  end;
  Result := True;
end;

function THtmlTokenizer.StepBeforeAttributeValue: Boolean;
var
  Value: Byte;
begin
  case ReadNext(FInput, Value) of
    ReadSuspend:
      Exit(False);
    ReadEndOfFile:
      begin
        FState := TsAttributeValueUnquoted;
        Exit(True);
      end;
  end;
  case Value of
    9, 10, 12, 32:
      ;
    Ord('"'):
      FState := TsAttributeValueDoubleQuoted;
    Ord(''''):
      FState := TsAttributeValueSingleQuoted;
    Ord('>'):
      begin
        ParseError('missing-attribute-value');
        FState := TsData;
        EmitTag;
      end;
  else
    FInput.Back;
    FState := TsAttributeValueUnquoted;
  end;
  Result := True;
end;

function THtmlTokenizer.StepAttributeValueQuoted(Quote: Byte): Boolean;
var
  Value: Byte;
  RunLength: SizeInt;
begin
  if Quote = Ord('"') then
    RunLength := FInput.ScanRun(AttributeDoubleStops)
  else
    RunLength := FInput.ScanRun(AttributeSingleStops);
  if RunLength > 0 then
  begin
    FAttributeValue.Append(FInput.CurrentPointer, RunLength);
    FInput.Skip(RunLength);
  end;
  case ReadNext(FInput, Value) of
    ReadSuspend:
      Exit(False);
    ReadEndOfFile:
      begin
        ParseError('eof-in-tag');
        EmitEndOfFile;
        Exit(True);
      end;
  end;
  if Value = Quote then
    FState := TsAfterAttributeValueQuoted
  else if Value = Ord('&') then
  begin
    FReturnState := FState;
    FState := TsCharacterReference;
  end
  else if Value = 0 then
  begin
    ParseError('unexpected-null-character');
    FAttributeValue.AppendString(ReplacementCharacterUtf8);
  end
  else
    FAttributeValue.AppendChar(Chr(Value));
  Result := True;
end;

function THtmlTokenizer.StepAttributeValueUnquoted: Boolean;
var
  Value: Byte;
begin
  case ReadNext(FInput, Value) of
    ReadSuspend:
      Exit(False);
    ReadEndOfFile:
      begin
        ParseError('eof-in-tag');
        EmitEndOfFile;
        Exit(True);
      end;
  end;
  case Value of
    9, 10, 12, 32:
      FState := TsBeforeAttributeName;
    Ord('&'):
      begin
        FReturnState := TsAttributeValueUnquoted;
        FState := TsCharacterReference;
      end;
    Ord('>'):
      begin
        FState := TsData;
        EmitTag;
      end;
    0:
      begin
        ParseError('unexpected-null-character');
        FAttributeValue.AppendString(ReplacementCharacterUtf8);
      end;
    Ord('"'), Ord(''''), Ord('<'), Ord('='), Ord('`'):
      begin
        ParseError('unexpected-character-in-unquoted-attribute-value');
        FAttributeValue.AppendChar(Chr(Value));
      end;
  else
    FAttributeValue.AppendChar(Chr(Value));
  end;
  Result := True;
end;

function THtmlTokenizer.StepAfterAttributeValueQuoted: Boolean;
var
  Value: Byte;
begin
  case ReadNext(FInput, Value) of
    ReadSuspend:
      Exit(False);
    ReadEndOfFile:
      begin
        ParseError('eof-in-tag');
        EmitEndOfFile;
        Exit(True);
      end;
  end;
  case Value of
    9, 10, 12, 32:
      FState := TsBeforeAttributeName;
    Ord('/'):
      FState := TsSelfClosingStartTag;
    Ord('>'):
      begin
        FState := TsData;
        EmitTag;
      end;
  else
    ParseError('missing-whitespace-between-attributes');
    FInput.Back;
    FState := TsBeforeAttributeName;
  end;
  Result := True;
end;

function THtmlTokenizer.StepSelfClosingStartTag: Boolean;
var
  Value: Byte;
begin
  case ReadNext(FInput, Value) of
    ReadSuspend:
      Exit(False);
    ReadEndOfFile:
      begin
        ParseError('eof-in-tag');
        EmitEndOfFile;
        Exit(True);
      end;
  end;
  if Value = Ord('>') then
  begin
    FToken.SelfClosing := True;
    FState := TsData;
    EmitTag;
  end
  else
  begin
    ParseError('unexpected-solidus-in-tag');
    FInput.Back;
    FState := TsBeforeAttributeName;
  end;
  Result := True;
end;
