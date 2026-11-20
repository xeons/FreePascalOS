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
  Web.Html.Tokenizer: the text states (data, RCDATA, RAWTEXT, script
  data with its escaped and double escaped states, PLAINTEXT) and their
  less-than sign and end tag states.
}

function THtmlTokenizer.StepData: Boolean;
var
  Value: Byte;
  RunLength: SizeInt;
begin
  RunLength := FInput.ScanRun(DataStops);
  if RunLength > 0 then
  begin
    EmitText(FInput.CurrentPointer, RunLength);
    FInput.Skip(RunLength);
  end;
  case ReadNext(FInput, Value) of
    ReadSuspend:
      Exit(False);
    ReadEndOfFile:
      begin
        EmitEndOfFile;
        Exit(True);
      end;
  end;
  case Value of
    Ord('&'):
      begin
        FReturnState := TsData;
        FState := TsCharacterReference;
      end;
    Ord('<'):
      FState := TsTagOpen;
    0:
      begin
        ParseError('unexpected-null-character');
        EmitNull;
      end;
  end;
  Result := True;
end;

{ RCDATA, RAWTEXT, script data and PLAINTEXT: text up to their stops. }
function StepPlainRun(Tokenizer: THtmlTokenizer; const Stops: TStopTable; out Value: Byte): TReadResult;
var
  RunLength: SizeInt;
begin
  RunLength := Tokenizer.FInput.ScanRun(Stops);
  if RunLength > 0 then
  begin
    Tokenizer.EmitText(Tokenizer.FInput.CurrentPointer, RunLength);
    Tokenizer.FInput.Skip(RunLength);
  end;
  Result := ReadNext(Tokenizer.FInput, Value);
end;

function THtmlTokenizer.StepRcdata: Boolean;
var
  Value: Byte;
begin
  case StepPlainRun(Self, RcdataStops, Value) of
    ReadSuspend:
      Exit(False);
    ReadEndOfFile:
      begin
        EmitEndOfFile;
        Exit(True);
      end;
  end;
  case Value of
    Ord('&'):
      begin
        FReturnState := TsRcdata;
        FState := TsCharacterReference;
      end;
    Ord('<'):
      FState := TsRcdataLessThanSign;
    0:
      begin
        ParseError('unexpected-null-character');
        EmitReplacementCharacter;
      end;
  end;
  Result := True;
end;

function THtmlTokenizer.StepRawText: Boolean;
var
  Value: Byte;
begin
  case StepPlainRun(Self, RawTextStops, Value) of
    ReadSuspend:
      Exit(False);
    ReadEndOfFile:
      begin
        EmitEndOfFile;
        Exit(True);
      end;
  end;
  case Value of
    Ord('<'):
      FState := TsRawTextLessThanSign;
    0:
      begin
        ParseError('unexpected-null-character');
        EmitReplacementCharacter;
      end;
  end;
  Result := True;
end;

function THtmlTokenizer.StepScriptData: Boolean;
var
  Value: Byte;
begin
  case StepPlainRun(Self, RawTextStops, Value) of
    ReadSuspend:
      Exit(False);
    ReadEndOfFile:
      begin
        EmitEndOfFile;
        Exit(True);
      end;
  end;
  case Value of
    Ord('<'):
      FState := TsScriptDataLessThanSign;
    0:
      begin
        ParseError('unexpected-null-character');
        EmitReplacementCharacter;
      end;
  end;
  Result := True;
end;

function THtmlTokenizer.StepPlainText: Boolean;
var
  Value: Byte;
begin
  case StepPlainRun(Self, PlainTextStops, Value) of
    ReadSuspend:
      Exit(False);
    ReadEndOfFile:
      begin
        EmitEndOfFile;
        Exit(True);
      end;
  end;
  ParseError('unexpected-null-character');
  EmitReplacementCharacter;
  Result := True;
end;

{ The RCDATA, RAWTEXT and script data less-than sign states. }
function THtmlTokenizer.StepTextLessThanSign(EndTagOpenState, TextState: TTokenizerState): Boolean;
var
  Value: Byte;
begin
  case ReadNext(FInput, Value) of
    ReadSuspend:
      Exit(False);
    ReadByteAvailable:
      if Value = Ord('/') then
      begin
        FTemporaryBuffer.Clear;
        FState := EndTagOpenState;
        Exit(True);
      end
      else
        FInput.Back;
  end;
  EmitByte(Ord('<'));
  FState := TextState;
  Result := True;
end;

function THtmlTokenizer.StepTextEndTagOpen(EndTagNameState, TextState: TTokenizerState): Boolean;
var
  Value: Byte;
begin
  case ReadNext(FInput, Value) of
    ReadSuspend:
      Exit(False);
    ReadByteAvailable:
      begin
        FInput.Back;
        if IsAsciiAlpha(Value) then
        begin
          StartTag(True);
          FState := EndTagNameState;
          Exit(True);
        end;
      end;
  end;
  EmitByte(Ord('<'));
  EmitByte(Ord('/'));
  FState := TextState;
  Result := True;
end;

function THtmlTokenizer.StepTextEndTagName(TextState: TTokenizerState): Boolean;
var
  Value: Byte;
begin
  case ReadNext(FInput, Value) of
    ReadSuspend:
      Exit(False);
    ReadByteAvailable:
      begin
        if IsTokenizerWhitespace(Value) and IsAppropriateEndTag then
        begin
          FState := TsBeforeAttributeName;
          Exit(True);
        end;
        if (Value = Ord('/')) and IsAppropriateEndTag then
        begin
          FState := TsSelfClosingStartTag;
          Exit(True);
        end;
        if (Value = Ord('>')) and IsAppropriateEndTag then
        begin
          FState := TsData;
          EmitTag;
          Exit(True);
        end;
        if IsAsciiAlpha(Value) then
        begin
          FTagName.AppendChar(LowerByte(Value));
          FTemporaryBuffer.AppendChar(Chr(Value));
          Exit(True);
        end;
        FInput.Back;
      end;
  end;
  EmitByte(Ord('<'));
  EmitByte(Ord('/'));
  EmitText(FTemporaryBuffer.Data, FTemporaryBuffer.Length);
  FState := TextState;
  Result := True;
end;

function THtmlTokenizer.StepScriptDataLessThanSign: Boolean;
var
  Value: Byte;
begin
  case ReadNext(FInput, Value) of
    ReadSuspend:
      Exit(False);
    ReadByteAvailable:
      begin
        if Value = Ord('/') then
        begin
          FTemporaryBuffer.Clear;
          FState := TsScriptDataEndTagOpen;
          Exit(True);
        end;
        if Value = Ord('!') then
        begin
          FState := TsScriptDataEscapeStart;
          EmitByte(Ord('<'));
          EmitByte(Ord('!'));
          Exit(True);
        end;
        FInput.Back;
      end;
  end;
  EmitByte(Ord('<'));
  FState := TsScriptData;
  Result := True;
end;

function THtmlTokenizer.StepScriptDataEscapeStart: Boolean;
var
  Value: Byte;
begin
  case ReadNext(FInput, Value) of
    ReadSuspend:
      Exit(False);
    ReadByteAvailable:
      if Value = Ord('-') then
      begin
        FState := TsScriptDataEscapeStartDash;
        EmitByte(Ord('-'));
        Exit(True);
      end
      else
        FInput.Back;
  end;
  FState := TsScriptData;
  Result := True;
end;

function THtmlTokenizer.StepScriptDataEscapeStartDash: Boolean;
var
  Value: Byte;
begin
  case ReadNext(FInput, Value) of
    ReadSuspend:
      Exit(False);
    ReadByteAvailable:
      if Value = Ord('-') then
      begin
        FState := TsScriptDataEscapedDashDash;
        EmitByte(Ord('-'));
        Exit(True);
      end
      else
        FInput.Back;
  end;
  FState := TsScriptData;
  Result := True;
end;

function THtmlTokenizer.StepScriptDataEscaped: Boolean;
var
  Value: Byte;
begin
  case ReadNext(FInput, Value) of
    ReadSuspend:
      Exit(False);
    ReadEndOfFile:
      begin
        ParseError('eof-in-script-html-comment-like-text');
        EmitEndOfFile;
        Exit(True);
      end;
  end;
  case Value of
    Ord('-'):
      begin
        FState := TsScriptDataEscapedDash;
        EmitByte(Value);
      end;
    Ord('<'):
      FState := TsScriptDataEscapedLessThanSign;
    0:
      begin
        ParseError('unexpected-null-character');
        EmitReplacementCharacter;
      end;
  else
    EmitByte(Value);
  end;
  Result := True;
end;

function THtmlTokenizer.StepScriptDataEscapedDash: Boolean;
var
  Value: Byte;
begin
  case ReadNext(FInput, Value) of
    ReadSuspend:
      Exit(False);
    ReadEndOfFile:
      begin
        ParseError('eof-in-script-html-comment-like-text');
        EmitEndOfFile;
        Exit(True);
      end;
  end;
  case Value of
    Ord('-'):
      begin
        FState := TsScriptDataEscapedDashDash;
        EmitByte(Value);
      end;
    Ord('<'):
      FState := TsScriptDataEscapedLessThanSign;
    0:
      begin
        ParseError('unexpected-null-character');
        FState := TsScriptDataEscaped;
        EmitReplacementCharacter;
      end;
  else
    FState := TsScriptDataEscaped;
    EmitByte(Value);
  end;
  Result := True;
end;

function THtmlTokenizer.StepScriptDataEscapedDashDash: Boolean;
var
  Value: Byte;
begin
  case ReadNext(FInput, Value) of
    ReadSuspend:
      Exit(False);
    ReadEndOfFile:
      begin
        ParseError('eof-in-script-html-comment-like-text');
        EmitEndOfFile;
        Exit(True);
      end;
  end;
  case Value of
    Ord('-'):
      EmitByte(Value);
    Ord('<'):
      FState := TsScriptDataEscapedLessThanSign;
    Ord('>'):
      begin
        FState := TsScriptData;
        EmitByte(Value);
      end;
    0:
      begin
        ParseError('unexpected-null-character');
        FState := TsScriptDataEscaped;
        EmitReplacementCharacter;
      end;
  else
    FState := TsScriptDataEscaped;
    EmitByte(Value);
  end;
  Result := True;
end;

function THtmlTokenizer.StepScriptDataEscapedLessThanSign: Boolean;
var
  Value: Byte;
begin
  case ReadNext(FInput, Value) of
    ReadSuspend:
      Exit(False);
    ReadByteAvailable:
      begin
        if Value = Ord('/') then
        begin
          FTemporaryBuffer.Clear;
          FState := TsScriptDataEscapedEndTagOpen;
          Exit(True);
        end;
        FInput.Back;
        if IsAsciiAlpha(Value) then
        begin
          FTemporaryBuffer.Clear;
          EmitByte(Ord('<'));
          FState := TsScriptDataDoubleEscapeStart;
          Exit(True);
        end;
      end;
  end;
  EmitByte(Ord('<'));
  FState := TsScriptDataEscaped;
  Result := True;
end;

{ The double escape start and end states differ only in where they go. }
function StepDoubleEscapeBoundary(Tokenizer: THtmlTokenizer; WhenScript, OtherState: TTokenizerState): Boolean;
var
  Value: Byte;
begin
  case ReadNext(Tokenizer.FInput, Value) of
    ReadSuspend:
      Exit(False);
    ReadByteAvailable:
      begin
        if IsTokenizerWhitespace(Value) or (Value = Ord('/')) or (Value = Ord('>')) then
        begin
          if Tokenizer.FTemporaryBuffer.Equals('script') then
            Tokenizer.FState := WhenScript
          else
            Tokenizer.FState := OtherState;
          Tokenizer.EmitByte(Value);
          Exit(True);
        end;
        if IsAsciiAlpha(Value) then
        begin
          Tokenizer.FTemporaryBuffer.AppendChar(LowerByte(Value));
          Tokenizer.EmitByte(Value);
          Exit(True);
        end;
        Tokenizer.FInput.Back;
      end;
  end;
  Tokenizer.FState := OtherState;
  Result := True;
end;

function THtmlTokenizer.StepScriptDataDoubleEscapeStart: Boolean;
begin
  Result := StepDoubleEscapeBoundary(Self, TsScriptDataDoubleEscaped, TsScriptDataEscaped);
end;

function THtmlTokenizer.StepScriptDataDoubleEscapeEnd: Boolean;
begin
  Result := StepDoubleEscapeBoundary(Self, TsScriptDataEscaped, TsScriptDataDoubleEscaped);
end;

function THtmlTokenizer.StepScriptDataDoubleEscaped: Boolean;
var
  Value: Byte;
begin
  case ReadNext(FInput, Value) of
    ReadSuspend:
      Exit(False);
    ReadEndOfFile:
      begin
        ParseError('eof-in-script-html-comment-like-text');
        EmitEndOfFile;
        Exit(True);
      end;
  end;
  case Value of
    Ord('-'):
      begin
        FState := TsScriptDataDoubleEscapedDash;
        EmitByte(Value);
      end;
    Ord('<'):
      begin
        FState := TsScriptDataDoubleEscapedLessThanSign;
        EmitByte(Value);
      end;
    0:
      begin
        ParseError('unexpected-null-character');
        EmitReplacementCharacter;
      end;
  else
    EmitByte(Value);
  end;
  Result := True;
end;

function THtmlTokenizer.StepScriptDataDoubleEscapedDash: Boolean;
var
  Value: Byte;
begin
  case ReadNext(FInput, Value) of
    ReadSuspend:
      Exit(False);
    ReadEndOfFile:
      begin
        ParseError('eof-in-script-html-comment-like-text');
        EmitEndOfFile;
        Exit(True);
      end;
  end;
  case Value of
    Ord('-'):
      begin
        FState := TsScriptDataDoubleEscapedDashDash;
        EmitByte(Value);
      end;
    Ord('<'):
      begin
        FState := TsScriptDataDoubleEscapedLessThanSign;
        EmitByte(Value);
      end;
    0:
      begin
        ParseError('unexpected-null-character');
        FState := TsScriptDataDoubleEscaped;
        EmitReplacementCharacter;
      end;
  else
    FState := TsScriptDataDoubleEscaped;
    EmitByte(Value);
  end;
  Result := True;
end;

function THtmlTokenizer.StepScriptDataDoubleEscapedDashDash: Boolean;
var
  Value: Byte;
begin
  case ReadNext(FInput, Value) of
    ReadSuspend:
      Exit(False);
    ReadEndOfFile:
      begin
        ParseError('eof-in-script-html-comment-like-text');
        EmitEndOfFile;
        Exit(True);
      end;
  end;
  case Value of
    Ord('-'):
      EmitByte(Value);
    Ord('<'):
      begin
        FState := TsScriptDataDoubleEscapedLessThanSign;
        EmitByte(Value);
      end;
    Ord('>'):
      begin
        FState := TsScriptData;
        EmitByte(Value);
      end;
    0:
      begin
        ParseError('unexpected-null-character');
        FState := TsScriptDataDoubleEscaped;
        EmitReplacementCharacter;
      end;
  else
    FState := TsScriptDataDoubleEscaped;
    EmitByte(Value);
  end;
  Result := True;
end;

function THtmlTokenizer.StepScriptDataDoubleEscapedLessThanSign: Boolean;
var
  Value: Byte;
begin
  case ReadNext(FInput, Value) of
    ReadSuspend:
      Exit(False);
    ReadByteAvailable:
      if Value = Ord('/') then
      begin
        FTemporaryBuffer.Clear;
        FState := TsScriptDataDoubleEscapeEnd;
        EmitByte(Value);
        Exit(True);
      end
      else
        FInput.Back;
  end;
  FState := TsScriptDataDoubleEscaped;
  Result := True;
end;
