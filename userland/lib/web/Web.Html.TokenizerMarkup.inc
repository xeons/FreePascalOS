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
  Web.Html.Tokenizer: markup declarations, comments and CDATA sections.
}

function THtmlTokenizer.StepBogusComment: Boolean;
var
  Value: Byte;
begin
  case ReadNext(FInput, Value) of
    ReadSuspend:
      Exit(False);
    ReadEndOfFile:
      begin
        EmitComment;
        EmitEndOfFile;
        Exit(True);
      end;
  end;
  if Value = Ord('>') then
  begin
    FState := TsData;
    EmitComment;
  end
  else if Value = 0 then
  begin
    ParseError('unexpected-null-character');
    FCommentData.AppendString(ReplacementCharacterUtf8);
  end
  else
    FCommentData.AppendChar(Chr(Value));
  Result := True;
end;

{ Whether the input continues with Text (ASCII case-insensitively when
  IgnoreCase): ReadSuspend when too little has arrived to tell. }
function InputContinuesWith(Input: THtmlInputStream; const Text: string; IgnoreCase: Boolean): TReadResult;
var
  Index: Integer;
  Available: SizeInt;
  Current: PChar;
begin
  Available := Input.Available;
  Current := Input.CurrentPointer;
  for Index := 1 to Length(Text) do
  begin
    if Index > Available then
    begin
      if Input.NoMoreInputComing then
        Exit(ReadEndOfFile);
      Exit(ReadSuspend);
    end;
    if IgnoreCase then
    begin
      if LowerByte(Ord(Current[Index - 1])) <> LowerByte(Ord(Text[Index])) then
        Exit(ReadEndOfFile);
    end
    else if Current[Index - 1] <> Text[Index] then
      Exit(ReadEndOfFile);
  end;
  Result := ReadByteAvailable;
end;

function THtmlTokenizer.StepMarkupDeclarationOpen: Boolean;
begin
  case InputContinuesWith(FInput, '--', False) of
    ReadSuspend:
      Exit(False);
    ReadByteAvailable:
      begin
        FInput.Skip(2);
        FCommentData.Clear;
        FState := TsCommentStart;
        Exit(True);
      end;
  end;
  case InputContinuesWith(FInput, 'DOCTYPE', True) of
    ReadSuspend:
      Exit(False);
    ReadByteAvailable:
      begin
        FInput.Skip(7);
        FState := TsDoctype;
        Exit(True);
      end;
  end;
  case InputContinuesWith(FInput, '[CDATA[', False) of
    ReadSuspend:
      Exit(False);
    ReadByteAvailable:
      begin
        FInput.Skip(7);
        if FSink.AdjustedCurrentNodeIsForeign then
          FState := TsCdataSection
        else
        begin
          ParseError('cdata-in-html-content');
          FCommentData.Clear;
          FCommentData.AppendString('[CDATA[');
          FState := TsBogusComment;
        end;
        Exit(True);
      end;
  end;
  ParseError('incorrectly-opened-comment');
  FCommentData.Clear;
  FState := TsBogusComment;
  Result := True;
end;

function THtmlTokenizer.StepCommentStart: Boolean;
var
  Value: Byte;
begin
  case ReadNext(FInput, Value) of
    ReadSuspend:
      Exit(False);
    ReadByteAvailable:
      begin
        if Value = Ord('-') then
        begin
          FState := TsCommentStartDash;
          Exit(True);
        end;
        if Value = Ord('>') then
        begin
          ParseError('abrupt-closing-of-empty-comment');
          FState := TsData;
          EmitComment;
          Exit(True);
        end;
        FInput.Back;
      end;
  end;
  FState := TsComment;
  Result := True;
end;

function THtmlTokenizer.StepCommentStartDash: Boolean;
var
  Value: Byte;
begin
  case ReadNext(FInput, Value) of
    ReadSuspend:
      Exit(False);
    ReadEndOfFile:
      begin
        ParseError('eof-in-comment');
        EmitComment;
        EmitEndOfFile;
        Exit(True);
      end;
  end;
  if Value = Ord('-') then
    FState := TsCommentEnd
  else if Value = Ord('>') then
  begin
    ParseError('abrupt-closing-of-empty-comment');
    FState := TsData;
    EmitComment;
  end
  else
  begin
    FCommentData.AppendChar('-');
    FInput.Back;
    FState := TsComment;
  end;
  Result := True;
end;

function THtmlTokenizer.StepComment: Boolean;
var
  Value: Byte;
  RunLength: SizeInt;
begin
  RunLength := FInput.ScanRun(CommentStops);
  if RunLength > 0 then
  begin
    FCommentData.Append(FInput.CurrentPointer, RunLength);
    FInput.Skip(RunLength);
  end;
  case ReadNext(FInput, Value) of
    ReadSuspend:
      Exit(False);
    ReadEndOfFile:
      begin
        ParseError('eof-in-comment');
        EmitComment;
        EmitEndOfFile;
        Exit(True);
      end;
  end;
  case Value of
    Ord('<'):
      begin
        FCommentData.AppendChar('<');
        FState := TsCommentLessThanSign;
      end;
    Ord('-'):
      FState := TsCommentEndDash;
    0:
      begin
        ParseError('unexpected-null-character');
        FCommentData.AppendString(ReplacementCharacterUtf8);
      end;
  else
    FCommentData.AppendChar(Chr(Value));
  end;
  Result := True;
end;

function THtmlTokenizer.StepCommentLessThanSign: Boolean;
var
  Value: Byte;
begin
  case ReadNext(FInput, Value) of
    ReadSuspend:
      Exit(False);
    ReadByteAvailable:
      begin
        if Value = Ord('!') then
        begin
          FCommentData.AppendChar('!');
          FState := TsCommentLessThanSignBang;
          Exit(True);
        end;
        if Value = Ord('<') then
        begin
          FCommentData.AppendChar('<');
          Exit(True);
        end;
        FInput.Back;
      end;
  end;
  FState := TsComment;
  Result := True;
end;

function THtmlTokenizer.StepCommentLessThanSignBang: Boolean;
var
  Value: Byte;
begin
  case ReadNext(FInput, Value) of
    ReadSuspend:
      Exit(False);
    ReadByteAvailable:
      if Value = Ord('-') then
      begin
        FState := TsCommentLessThanSignBangDash;
        Exit(True);
      end
      else
        FInput.Back;
  end;
  FState := TsComment;
  Result := True;
end;

function THtmlTokenizer.StepCommentLessThanSignBangDash: Boolean;
var
  Value: Byte;
begin
  case ReadNext(FInput, Value) of
    ReadSuspend:
      Exit(False);
    ReadByteAvailable:
      if Value = Ord('-') then
      begin
        FState := TsCommentLessThanSignBangDashDash;
        Exit(True);
      end
      else
        FInput.Back;
  end;
  FState := TsCommentEndDash;
  Result := True;
end;

function THtmlTokenizer.StepCommentLessThanSignBangDashDash: Boolean;
var
  Value: Byte;
begin
  case ReadNext(FInput, Value) of
    ReadSuspend:
      Exit(False);
    ReadByteAvailable:
      begin
        if Value <> Ord('>') then
          ParseError('nested-comment');
        FInput.Back;
      end;
  end;
  FState := TsCommentEnd;
  Result := True;
end;

function THtmlTokenizer.StepCommentEndDash: Boolean;
var
  Value: Byte;
begin
  case ReadNext(FInput, Value) of
    ReadSuspend:
      Exit(False);
    ReadEndOfFile:
      begin
        ParseError('eof-in-comment');
        EmitComment;
        EmitEndOfFile;
        Exit(True);
      end;
  end;
  if Value = Ord('-') then
    FState := TsCommentEnd
  else
  begin
    FCommentData.AppendChar('-');
    FInput.Back;
    FState := TsComment;
  end;
  Result := True;
end;

function THtmlTokenizer.StepCommentEnd: Boolean;
var
  Value: Byte;
begin
  case ReadNext(FInput, Value) of
    ReadSuspend:
      Exit(False);
    ReadEndOfFile:
      begin
        ParseError('eof-in-comment');
        EmitComment;
        EmitEndOfFile;
        Exit(True);
      end;
  end;
  case Value of
    Ord('>'):
      begin
        FState := TsData;
        EmitComment;
      end;
    Ord('!'):
      FState := TsCommentEndBang;
    Ord('-'):
      FCommentData.AppendChar('-');
  else
    FCommentData.AppendString('--');
    FInput.Back;
    FState := TsComment;
  end;
  Result := True;
end;

function THtmlTokenizer.StepCommentEndBang: Boolean;
var
  Value: Byte;
begin
  case ReadNext(FInput, Value) of
    ReadSuspend:
      Exit(False);
    ReadEndOfFile:
      begin
        ParseError('eof-in-comment');
        EmitComment;
        EmitEndOfFile;
        Exit(True);
      end;
  end;
  case Value of
    Ord('-'):
      begin
        FCommentData.AppendString('--!');
        FState := TsCommentEndDash;
      end;
    Ord('>'):
      begin
        ParseError('incorrectly-closed-comment');
        FState := TsData;
        EmitComment;
      end;
  else
    FCommentData.AppendString('--!');
    FInput.Back;
    FState := TsComment;
  end;
  Result := True;
end;

function THtmlTokenizer.StepCdataSection: Boolean;
var
  Value: Byte;
begin
  case ReadNext(FInput, Value) of
    ReadSuspend:
      Exit(False);
    ReadEndOfFile:
      begin
        ParseError('eof-in-cdata');
        EmitEndOfFile;
        Exit(True);
      end;
  end;
  if Value = Ord(']') then
    FState := TsCdataSectionBracket
  else if Value = 0 then
    EmitNull
  else
    EmitByte(Value);
  Result := True;
end;

function THtmlTokenizer.StepCdataSectionBracket: Boolean;
var
  Value: Byte;
begin
  case ReadNext(FInput, Value) of
    ReadSuspend:
      Exit(False);
    ReadByteAvailable:
      if Value = Ord(']') then
      begin
        FState := TsCdataSectionEnd;
        Exit(True);
      end
      else
        FInput.Back;
  end;
  EmitByte(Ord(']'));
  FState := TsCdataSection;
  Result := True;
end;

function THtmlTokenizer.StepCdataSectionEnd: Boolean;
var
  Value: Byte;
begin
  case ReadNext(FInput, Value) of
    ReadSuspend:
      Exit(False);
    ReadByteAvailable:
      begin
        if Value = Ord(']') then
        begin
          EmitByte(Ord(']'));
          Exit(True);
        end;
        if Value = Ord('>') then
        begin
          FState := TsData;
          Exit(True);
        end;
        FInput.Back;
      end;
  end;
  EmitByte(Ord(']'));
  EmitByte(Ord(']'));
  FState := TsCdataSection;
  Result := True;
end;
