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
  Text helpers of line layout: UTF-8 stepping, text-transform, and line
  break opportunities.

  Break opportunities are a simplified UAX #14: after spaces and tabs
  and U+200B, after a hyphen or dash between letters, before and after
  ideographs, kana and Hangul syllables (CJK breaks anywhere), and
  never before closing punctuation. word-break: break-all and
  line-break: anywhere break between any two characters, keep-all
  keeps CJK together.
}
unit Web.Text.Breaking;

{$mode objfpc}
{$H+}

interface

uses
  Css.Keywords;

type
  TBreakRules = record
    { white-space allows wrapping at all. }
    Wrap: Boolean;
    BreakAll: Boolean;
    KeepAll: Boolean;
    Anywhere: Boolean;
  end;

{ The code point at Text[Index] (1 based), and its length in bytes. }
function CodePointAt(const Text: string; Index: Integer; out ByteCount: Integer): LongWord;
procedure AppendCodePoint(var Text: string; CodePoint: LongWord);
function IsIdeographic(CodePoint: LongWord): Boolean;
function IsClosingPunctuation(CodePoint: LongWord): Boolean;
{ Whether a line may break between Previous and Next. }
function BreakAllowedBetween(Previous, Next: LongWord; const Rules: TBreakRules): Boolean;
function ToUpperCodePoint(CodePoint: LongWord): LongWord;
function ToLowerCodePoint(CodePoint: LongWord): LongWord;
{ text-transform of a run; AtWordStart carries capitalize across runs. }
function TransformText(const Text: string; Transform: TCssKeyword; var AtWordStart: Boolean): string;

implementation

function CodePointAt(const Text: string; Index: Integer; out ByteCount: Integer): LongWord;
var
  Lead: Byte;
  Remaining, Position: Integer;
begin
  Lead := Ord(Text[Index]);
  if Lead < $80 then
  begin
    ByteCount := 1;
    Exit(Lead);
  end;
  if Lead >= $F0 then
  begin
    Result := Lead and $07;
    Remaining := 3;
  end
  else if Lead >= $E0 then
  begin
    Result := Lead and $0F;
    Remaining := 2;
  end
  else if Lead >= $C0 then
  begin
    Result := Lead and $1F;
    Remaining := 1;
  end
  else
  begin
    ByteCount := 1;
    Exit($FFFD);
  end;
  Position := Index + 1;
  while (Remaining > 0) and (Position <= Length(Text)) and ((Ord(Text[Position]) and $C0) = $80) do
  begin
    Result := (Result shl 6) or (Ord(Text[Position]) and $3F);
    Inc(Position);
    Dec(Remaining);
  end;
  ByteCount := Position - Index;
  if Remaining > 0 then
    Result := $FFFD;
end;

procedure AppendCodePoint(var Text: string; CodePoint: LongWord);
begin
  if CodePoint < $80 then
    Text := Text + Chr(CodePoint)
  else if CodePoint < $800 then
    Text := Text + Chr($C0 or (CodePoint shr 6)) + Chr($80 or (CodePoint and $3F))
  else if CodePoint < $10000 then
    Text := Text + Chr($E0 or (CodePoint shr 12)) + Chr($80 or ((CodePoint shr 6) and $3F)) +
      Chr($80 or (CodePoint and $3F))
  else
    Text := Text + Chr($F0 or (CodePoint shr 18)) + Chr($80 or ((CodePoint shr 12) and $3F)) +
      Chr($80 or ((CodePoint shr 6) and $3F)) + Chr($80 or (CodePoint and $3F));
end;

function IsIdeographic(CodePoint: LongWord): Boolean;
begin
  Result := ((CodePoint >= $2E80) and (CodePoint <= $2FFF)) or ((CodePoint >= $3040) and (CodePoint <= $30FF)) or
    ((CodePoint >= $3400) and (CodePoint <= $4DBF)) or ((CodePoint >= $4E00) and (CodePoint <= $9FFF)) or
    ((CodePoint >= $AC00) and (CodePoint <= $D7AF)) or ((CodePoint >= $F900) and (CodePoint <= $FAFF)) or
    ((CodePoint >= $20000) and (CodePoint <= $3FFFF));
end;

function IsClosingPunctuation(CodePoint: LongWord): Boolean;
begin
  case CodePoint of
    Ord('.'), Ord(','), Ord(';'), Ord(':'), Ord('!'), Ord('?'), Ord(')'), Ord(']'), Ord('}'), $3001, $3002,
    $FF0C, $FF0E, $300D, $300F, $FF09, $201D, $2019, Ord('%'):
      Result := True;
  else
    Result := False;
  end;
end;

function IsLetterLike(CodePoint: LongWord): Boolean;
begin
  Result := ((CodePoint >= Ord('a')) and (CodePoint <= Ord('z'))) or ((CodePoint >= Ord('A')) and
    (CodePoint <= Ord('Z'))) or ((CodePoint >= Ord('0')) and (CodePoint <= Ord('9'))) or
    ((CodePoint >= $C0) and (CodePoint < $2000) and not IsIdeographic(CodePoint));
end;

function BreakAllowedBetween(Previous, Next: LongWord; const Rules: TBreakRules): Boolean;
begin
  if not Rules.Wrap then
    Exit(False);
  if (Next = $A0) or (Previous = $A0) or (Next = $2060) or (Previous = $2060) then
    Exit(False);
  if Rules.Anywhere then
    Exit(True);
  if (Previous = 32) or (Previous = 9) or (Previous = $200B) then
    Exit(not ((Next = 32) or (Next = 9)));
  if (Next = 32) or (Next = 9) then
    Exit(False);
  if IsClosingPunctuation(Next) then
    Exit(False);
  if Rules.BreakAll and IsLetterLike(Previous) and IsLetterLike(Next) then
    Exit(True);
  if ((Previous = Ord('-')) or (Previous = $2010) or (Previous = $2013) or (Previous = $2014)) and
     IsLetterLike(Next) then
    Exit(True);
  if not Rules.KeepAll and (IsIdeographic(Previous) or IsIdeographic(Next)) then
    Exit(True);
  Result := False;
end;

function ToUpperCodePoint(CodePoint: LongWord): LongWord;
begin
  Result := CodePoint;
  if (CodePoint >= Ord('a')) and (CodePoint <= Ord('z')) then
    Result := CodePoint - 32
  else if ((CodePoint >= $E0) and (CodePoint <= $FE) and (CodePoint <> $F7)) then
    Result := CodePoint - 32
  else if (CodePoint = $FF) then
    Result := $178
  else if (CodePoint >= $100) and (CodePoint <= $17F) and Odd(CodePoint) and (CodePoint <> $131) then
    Result := CodePoint - 1
  else if (CodePoint >= $3B1) and (CodePoint <= $3C9) and (CodePoint <> $3C2) then
    Result := CodePoint - 32
  else if (CodePoint >= $430) and (CodePoint <= $44F) then
    Result := CodePoint - 32
  else if (CodePoint >= $450) and (CodePoint <= $45F) then
    Result := CodePoint - 80;
end;

function ToLowerCodePoint(CodePoint: LongWord): LongWord;
begin
  Result := CodePoint;
  if (CodePoint >= Ord('A')) and (CodePoint <= Ord('Z')) then
    Result := CodePoint + 32
  else if ((CodePoint >= $C0) and (CodePoint <= $DE) and (CodePoint <> $D7)) then
    Result := CodePoint + 32
  else if (CodePoint >= $100) and (CodePoint <= $17F) and not Odd(CodePoint) and (CodePoint <> $130) then
    Result := CodePoint + 1
  else if (CodePoint >= $391) and (CodePoint <= $3A9) then
    Result := CodePoint + 32
  else if (CodePoint >= $410) and (CodePoint <= $42F) then
    Result := CodePoint + 32
  else if (CodePoint >= $400) and (CodePoint <= $40F) then
    Result := CodePoint + 80;
end;

function TransformText(const Text: string; Transform: TCssKeyword; var AtWordStart: Boolean): string;
var
  Index, ByteCount: Integer;
  CodePoint: LongWord;
begin
  if not (KeywordIn(Transform, [kwUppercase, kwLowercase, kwCapitalize])) then
    Exit(Text);
  Result := '';
  Index := 1;
  while Index <= Length(Text) do
  begin
    CodePoint := CodePointAt(Text, Index, ByteCount);
    case Transform of
      kwUppercase:
        if CodePoint = $DF then
          Result := Result + 'SS'
        else
          AppendCodePoint(Result, ToUpperCodePoint(CodePoint));
      kwLowercase:
        AppendCodePoint(Result, ToLowerCodePoint(CodePoint));
      kwCapitalize:
        begin
          if AtWordStart and IsLetterLike(CodePoint) then
            AppendCodePoint(Result, ToUpperCodePoint(CodePoint))
          else
            AppendCodePoint(Result, CodePoint);
          AtWordStart := not IsLetterLike(CodePoint) and (CodePoint <> Ord('''')) and (CodePoint <> $2019);
        end;
    end;
    Inc(Index, ByteCount);
  end;
end;

end.
